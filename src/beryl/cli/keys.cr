require "option_parser"
require "./option_errors"
require "./account_utils"
require "./scope"
require "./config_git"
require "./info"
require "./key_store"
require "../config"
require "../zfs_keys"
require "../zfs_keys/paper"

# `beryl keys` — clés de chiffrement ZFS des serveurs, hors des commandes
# qui les créent (bootstrap, zpool-create) ou les utilisent (unlock,
# tang-enroll). Cf. `Beryl::ZfsKeys`.
#
#   import <portée>  copie la clé `.key` du poste de chaque serveur dans le
#                    coffre `[tang]` de sa société (serveurs installés avant
#                    le coffre) ; jamais d'écrasement d'une autre valeur.
#   paper <portée>   séquestre papier : un PDF imprimable par serveur.
#
# Essai à blanc par défaut, `--apply` pour écrire. Jamais journalisé
# (`SessionLog::SKIP`).
module Beryl::CLI::Keys
  extend self

  EXIT_OK       =  0
  EXIT_FAILED   =  1
  EXIT_USAGE    = 64
  EXIT_CONFLICT =  4

  USAGE = <<-USAGE
    USAGE : beryl keys <SOUS-COMMANDE> <portée> [options]

    Clés de chiffrement ZFS des serveurs (64 hex) : fichier du poste
    (~/.config/beryl/<société>/<domaine>/<host>.key) et coffre de la société,
    section [tang], variable = nom court en majuscules (web-1 → WEB_1).

    SOUS-COMMANDES :
      import <portée>            Copie les clés .key du poste dans le coffre [tang]
                                 (migration des serveurs existants ; refus si le coffre
                                 porte une AUTRE clé)
      paper <portée> --out DIR   Séquestre papier : un PDF par serveur (clé, empreinte,
                                 procédure sans beryl, QR code de déverrouillage)

    Portée : serveur, groupe, domaine, société ou liste `a,b,c`.
    Essai à blanc par défaut ; --apply pour écrire. `beryl keys <sous-commande> --help`.
    USAGE

  def run(config_root : String, argv : Array(String)) : Int32
    if argv.empty? || {"-h", "--help", "help"}.includes?(argv.first)
      STDOUT.puts USAGE
      return EXIT_OK
    end
    sub, rest = argv.first, argv[1..]
    case sub
    when "import" then cmd_import(config_root, rest)
    when "paper"  then cmd_paper(config_root, rest)
    else
      STDERR.puts "beryl keys : sous-commande inconnue : #{sub}"
      STDERR.puts USAGE
      EXIT_USAGE
    end
  end

  # ─────────────────────────────────────────────────────────────
  # import
  # ─────────────────────────────────────────────────────────────

  private def cmd_import(config_root : String, argv : Array(String)) : Int32
    dry_run = true
    no_commit = false
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl keys import <portée> [--apply] [--no-commit]\n\n" \
                 "Copie la clé ZFS du poste (<host>.key) de chaque serveur dans le coffre [tang] de sa société.\n" \
                 "Déjà rangée → rien ; AUTRE clé dans le coffre → refus (rien n'est écrasé).\n"
      p.on("--apply", "Écrit réellement dans le coffre (sinon : essai à blanc)") { dry_run = false }
      p.on("--no-commit", "Ne commite pas le coffre chiffré dans le dépôt de config") { no_commit = true }
      p.on("-h", "--help", "Affiche cette aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(argv)
    hosts = scoped(config_root, positional, "import") || return EXIT_USAGE

    counts = Hash(String, Int32).new(0)
    failed = false
    hosts.each do |host|
      outcome = import_one(config_root, host, dry_run, no_commit)
      counts[outcome] += 1
      failed = true if outcome.in?("conflit", "échec")
    end
    STDOUT.puts
    STDOUT.puts "[import] #{counts.map { |k, v| "#{v} #{k}" }.join(", ")}#{dry_run ? " — essai à blanc, --apply pour écrire" : ""}"
    failed ? EXIT_CONFLICT : EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl keys : #{ex.message}"
    EXIT_USAGE
  end

  # Un serveur ; renvoie l'issue (clé du bilan).
  private def import_one(config_root : String, host : Beryl::Config::ResolvedHost, dry_run : Bool, no_commit : Bool) : String
    ref = Beryl::CLI::AccountUtils.host_ref(host)
    var = Beryl::CLI::KeyStore.var(host)
    path = Beryl::CLI::KeyStore.file_path(config_root, host)
    in_vault = host.env_file.for_account_provider(host.account_name, Beryl::ZfsKeys::SECTION)[var]?
    unless Beryl::Encryption.exists?(path)
      STDOUT.puts "[#{ref}] #{in_vault ? "clé dans le coffre seulement (pas de #{File.basename(path)} sur ce poste)" : "aucune clé"}"
      return in_vault ? "déjà rangée(s)" : "sans clé"
    end
    found = Beryl::CLI::KeyStore.resolve(config_root, host).not_nil!
    fp = Beryl::ZfsKeys.fingerprint(found.hex)
    if in_vault
      STDOUT.puts "[#{ref}] déjà rangée dans le coffre [#{Beryl::ZfsKeys::SECTION}] #{var} (empreinte #{fp}, identique au fichier)"
      return "déjà rangée(s)"
    end
    if dry_run
      STDOUT.puts "[#{ref}] DRY-RUN : #{File.basename(path)} (empreinte #{fp}) → coffre #{host.account_name} [#{Beryl::ZfsKeys::SECTION}] #{var}"
      return "à ranger"
    end
    stored = Beryl::CLI::KeyStore.ensure_in_vault(host, found.hex, no_commit) { |m| STDOUT.puts "[#{ref}] #{m}" }
    stored ? "rangée(s)" : "échec"
  rescue ex : Beryl::ZfsKeys::Conflict
    STDERR.puts "[#{Beryl::CLI::AccountUtils.host_ref(host)}] REFUS : #{ex.message}"
    "conflit"
  rescue ex : Beryl::Encryption::Error
    STDERR.puts "[#{Beryl::CLI::AccountUtils.host_ref(host)}] #{ex.message}"
    "échec"
  end

  # ─────────────────────────────────────────────────────────────
  # paper
  # ─────────────────────────────────────────────────────────────

  private def cmd_paper(config_root : String, argv : Array(String)) : Int32
    dry_run = true
    out_dir : String? = nil
    converter_flag : String? = nil
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl keys paper <portée> --out DIR [--apply] [--converter PATH]\n\n" \
                 "Séquestre papier : un PDF imprimable par serveur chiffré (société, FQDN, pools, date,\n" \
                 "empreinte, clé en clair par groupes de 4, procédure manuelle sans beryl, commande beryl,\n" \
                 "QR code de la commande de déverrouillage avec la clé, lien vers beryl).\n" \
                 "Le PDF est un SECRET : écrit en 0600, jamais dans un dépôt git ni sous la config beryl.\n" \
                 "Imprimez-le, rangez le papier sous séquestre, puis SUPPRIMEZ le fichier.\n\n" \
                 "Réglages (_defaults.yml) : keys_paper.docs_url (lien beryl imprimé), keys_paper.converter.\n"
      p.on("-o DIR", "--out=DIR", "Dossier de sortie (obligatoire ; hors dépôt git)") { |v| out_dir = v }
      p.on("--converter=PATH", "Convertisseur AsciiDoc → PDF (défaut : #{Beryl::ZfsKeys::Paper::DEFAULT_CONVERTER} du PATH)") { |v| converter_flag = v }
      p.on("--apply", "Écrit réellement les PDF (sinon : essai à blanc)") { dry_run = false }
      p.on("-h", "--help", "Affiche cette aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(argv)
    unless od = out_dir
      STDERR.puts "beryl keys paper : --out DIR obligatoire (dossier choisi par vous, hors dépôt git)."
      return EXIT_USAGE
    end
    dir = File.expand_path(od, home: true)
    if reason = out_dir_refusal(dir, config_root)
      STDERR.puts "beryl keys paper : #{reason}"
      return EXIT_USAGE
    end
    hosts = scoped(config_root, positional, "paper") || return EXIT_USAGE

    failures = 0
    written = 0
    hosts.each do |host|
      case paper_one(config_root, host, dir, converter_flag, dry_run)
      when :written then written += 1
      when :failed  then failures += 1
      end
    end
    unless dry_run || written == 0
      STDOUT.puts
      STDOUT.puts "[paper] #{written} PDF dans #{dir} : imprimez-les, rangez le papier sous séquestre, puis SUPPRIMEZ les fichiers."
    end
    failures > 0 ? EXIT_FAILED : EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl keys : #{ex.message}"
    EXIT_USAGE
  end

  # Raison de refuser le dossier de sortie (absent, dans un dépôt git, sous
  # la config beryl), nil s'il convient.
  def out_dir_refusal(dir : String, config_root : String) : String?
    return "#{dir} n'est pas un dossier existant" unless File.directory?(dir)
    if repo = Beryl::CLI::ConfigGit.repo_root_for(dir)
      return "#{dir} est dans le dépôt git #{repo} — un PDF de clé n'y a pas sa place (secret en clair)"
    end
    cfg = File.expand_path(config_root)
    return "#{dir} est sous la configuration beryl (#{cfg}) — choisissez un dossier à part" if dir == cfg || dir.starts_with?(cfg + "/")
    nil
  end

  # Unités chiffrées d'un serveur, dans l'ordre du déverrouillage : pools
  # data (à importer) puis encryptionroot du zroot (profil standard).
  def units(host : Beryl::Config::ResolvedHost) : Array(Beryl::ZfsKeys::Paper::Unit)
    list = host.data_zpools.select(&.encrypted?).map do |p|
      Beryl::ZfsKeys::Paper::Unit.new(p.name, true, [p.mountpoint || "-"])
    end
    if (boot = host.zpools.find(&.boot)) && (er = boot.encryption_root)
      mps = boot.system_datasets.select(&.encrypted).map(&.mountpoint)
      list << Beryl::ZfsKeys::Paper::Unit.new(er, false, mps)
    end
    list
  end

  # Réglage `keys_paper.<clé>` de la config mergée (défauts racine, société,
  # domaine, groupe, serveur).
  def paper_setting(host : Beryl::Config::ResolvedHost, key : String) : String?
    section = host.merged[YAML::Any.new("keys_paper")]?.try(&.as_h?)
    v = section.try(&.[YAML::Any.new(key)]?).try(&.as_s?)
    v && !v.strip.empty? ? v.strip : nil
  end

  private def paper_one(config_root : String, host : Beryl::Config::ResolvedHost, dir : String,
                        converter_flag : String?, dry_run : Bool) : Symbol
    ref = Beryl::CLI::AccountUtils.host_ref(host)
    us = units(host)
    if us.empty?
      STDOUT.puts "[#{ref}] aucun pool ni dataset chiffré déclaré — sauté"
      return :skipped
    end
    found = Beryl::CLI::KeyStore.resolve(config_root, host)
    unless found
      STDERR.puts "[#{ref}] clé absente (ni coffre [#{Beryl::ZfsKeys::SECTION}] #{Beryl::CLI::KeyStore.var(host)}, " \
                  "ni #{Beryl::CLI::KeyStore.file_path(config_root, host)})"
      return :failed
    end
    sheet = Beryl::ZfsKeys::Paper::Sheet.new(
      account: host.account_name, fqdn: host.fqdn, host_ref: ref,
      var: Beryl::CLI::KeyStore.var(host), units: us, hex: found.hex,
      edited_at: Time.local, docs_url: paper_setting(host, "docs_url"),
    )
    converter = converter_flag || paper_setting(host, "converter") || Beryl::ZfsKeys::Paper::DEFAULT_CONVERTER
    out_path = File.join(dir, Beryl::ZfsKeys::Paper.pdf_name(host.fqdn))
    fp = Beryl::ZfsKeys.fingerprint(found.hex)
    if dry_run
      STDOUT.puts "[#{ref}] DRY-RUN : #{out_path} (0600) — clé du #{found.origin}, empreinte #{fp}, " \
                  "#{us.map(&.name).join(" + ")}, convertisseur #{Process.find_executable(converter) || "#{converter} INTROUVABLE"}" \
                  "#{File.exists?(out_path) ? " — EXISTE DÉJÀ, sera refusé" : ""}"
      return :planned
    end
    Beryl::ZfsKeys::Paper.write_pdf(sheet, out_path, converter)
    STDOUT.puts "[#{ref}] #{out_path} écrit (0600, empreinte #{fp})"
    :written
  rescue ex : Beryl::Encryption::Error
    STDERR.puts "[#{Beryl::CLI::AccountUtils.host_ref(host)}] #{ex.message}"
    :failed
  end

  # Serveurs de la portée (premier positionnel), nil après un message
  # d'erreur si elle est absente ou vide.
  private def scoped(config_root : String, positional : Array(String), sub : String) : Array(Beryl::Config::ResolvedHost)?
    joined = Beryl::CLI::Scope.join_list(positional)
    unless scope = joined.first?
      STDERR.puts "beryl keys #{sub} : portée manquante (serveur, groupe, domaine, société ou liste)."
      return
    end
    hosts = Beryl::CLI::Info.scoped_hosts(Beryl::Config::Root.load(config_root), scope)
    if hosts.empty?
      STDERR.puts "beryl keys #{sub} : aucun serveur pour la portée #{scope}."
      return
    end
    hosts
  end
end
