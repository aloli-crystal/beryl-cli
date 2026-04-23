require "option_parser"
require "../beryl"
require "./cli/prep_rescue"
require "./cli/bake_seed"
require "./cli/rescue"
require "./cli/boot_hd"
require "./cli/wipe"
require "./cli/apply"
require "./cli/scan"
require "./cli/init"
require "./cli/add_provider"
require "./cli/add_domain"
require "./cli/bootstrap"

# Point d'entrée CLI de beryl.
#
# Tous les chemins de configuration partent de `~/.beryl/` (sauf
# `-c PATH` qui override explicitement, typiquement pour des tests).
# Structure figée (voir `docs/adr/ADR-014-beryl-config-tree.adoc`) :
#
#   ~/.beryl/
#     _default.yml          # socle FreeBSD (sans clés SSH)
#     .env.yml              # credentials providers par domaine
#     <domaine>.yml         # identité d'un domaine (clés SSH, ovh.ssh_key_name)
#     <domaine>/            # contenu du domaine (hosts directs, groupes)
#       <host>.yml          # → <host>.<domaine>
#       <groupe>.yml + <groupe>/<host>.yml
module Beryl::CLI
  DEFAULT_CONFIG_ROOT = File.expand_path("~/.beryl", home: true)

  # Options globales qui consomment l'argument suivant (forme « -c VALEUR »).
  GLOBAL_FLAGS_WITH_VALUE = {"-c", "--config"}

  def self.run(argv : Array(String) = ARGV) : Int32
    config_root = DEFAULT_CONFIG_ROOT

    # Sépare les options globales (avant la sous-commande) du reste.
    split_at = 0
    while split_at < argv.size
      arg = argv[split_at]
      break unless arg.starts_with?("-")
      if GLOBAL_FLAGS_WITH_VALUE.includes?(arg)
        split_at += 2
      else
        split_at += 1
      end
    end
    global_args = argv[0...split_at]
    rest = argv[split_at..]

    global_parser = OptionParser.new do |p|
      p.banner = usage_banner
      p.on("-c PATH", "--config=PATH", "Racine de configuration (défaut : ~/.beryl)") { |v| config_root = File.expand_path(v, home: true) }
      p.on("-h", "--help", "Affiche cette aide") do
        puts p
        exit(0)
      end
      p.on("--version", "Affiche la version de beryl") do
        puts "beryl #{Beryl::VERSION}"
        exit(0)
      end
    end
    global_parser.parse(global_args)

    subcommand = rest.first?
    sub_args = rest[1..]? || [] of String

    case subcommand
    when nil            then show_usage(global_parser); 1
    when "help"         then cmd_help(global_parser, config_root, sub_args)
    when "init"         then Beryl::CLI::Init.run(config_root, sub_args)
    when "add-provider" then Beryl::CLI::AddProvider.run(config_root, sub_args)
    when "add-domain"   then Beryl::CLI::AddDomain.run(config_root, sub_args)
    when "list-hosts"   then cmd_list_hosts(config_root)
    when "show"         then cmd_show(config_root, sub_args)
    when "rescue"       then Beryl::CLI::Rescue.run(config_root, sub_args)
    when "boot-hd"      then Beryl::CLI::BootHd.run(config_root, sub_args)
    when "wipe"         then Beryl::CLI::Wipe.run(config_root, sub_args)
    when "bootstrap"    then Beryl::CLI::Bootstrap.run(config_root, sub_args)
    when "scan"         then Beryl::CLI::Scan.run(config_root, sub_args)
    when "apply"        then Beryl::CLI::Apply.run(config_root, sub_args)
    when "prep-rescue"  then Beryl::CLI::PrepRescue.run(sub_args)
    when "bake-seed"    then Beryl::CLI::BakeSeed.run(sub_args)
    when "version"      then puts "beryl #{Beryl::VERSION}"; 0
    else
      STDERR.puts "beryl : sous-commande inconnue : #{subcommand}"
      show_usage(global_parser)
      1
    end
  end

  # Affiche l'aide globale (sans topic) ou l'aide d'une sous-commande
  # nommée. `beryl help init` équivaut à `beryl init --help` mais plus
  # naturel à taper et cohérent avec git/systemctl/etc.
  private def self.cmd_help(global_parser : OptionParser, config_root : String, args : Array(String)) : Int32
    topic = args.first?
    unless topic
      show_usage(global_parser)
      return 0
    end
    # Dispatche vers la sous-commande avec --help. Les sous-commandes
    # réagissent au flag en imprimant leur aide puis `exit 0`.
    case topic
    when "help"         then show_usage(global_parser); 0
    when "init"         then Beryl::CLI::Init.run(config_root, ["--help"])
    when "add-provider" then Beryl::CLI::AddProvider.run(config_root, ["--help"])
    when "add-domain"   then Beryl::CLI::AddDomain.run(config_root, ["--help"])
    when "list-hosts"
      puts "USAGE : beryl list-hosts"
      puts
      puts "Liste tous les hosts de tous les domaines configurés dans #{config_root}."
      puts "Affiche FQDN, provider, groupe d'usage (ou -), et identifiant hébergeur"
      puts "(service_name OVH ou server_id Scaleway)."
      0
    when "show"
      puts "USAGE : beryl show <host> [--domain=NAME]"
      puts
      puts "Affiche la config effective d'un host (résultat du merge _default +"
      puts "domaine + groupe éventuel + host) et la liste des fichiers YAML qui"
      puts "contribuent à cette config."
      0
    when "rescue"      then Beryl::CLI::Rescue.run(config_root, ["--help"])
    when "boot-hd"     then Beryl::CLI::BootHd.run(config_root, ["--help"])
    when "wipe"        then Beryl::CLI::Wipe.run(config_root, ["--help"])
    when "bootstrap"   then Beryl::CLI::Bootstrap.run(config_root, ["--help"])
    when "scan"        then Beryl::CLI::Scan.run(config_root, ["--help"])
    when "apply"       then Beryl::CLI::Apply.run(config_root, ["--help"])
    when "prep-rescue" then Beryl::CLI::PrepRescue.run(["--help"])
    when "bake-seed"   then Beryl::CLI::BakeSeed.run(["--help"])
    when "version"
      puts "USAGE : beryl version"
      puts
      puts "Affiche la version courante de beryl."
      0
    else
      STDERR.puts "beryl : aucune aide pour « #{topic} »."
      STDERR.puts "        Sous-commandes connues : init, add-provider, add-domain,"
      STDERR.puts "        list-hosts, show, rescue, boot-hd, wipe, bootstrap,"
      STDERR.puts "        scan, apply, prep-rescue, bake-seed, version."
      1
    end
  end

  private def self.usage_banner : String
    <<-BANNER
    beryl #{Beryl::VERSION} — gestion de configuration FreeBSD (agentless SSH)

    USAGE : beryl [options globales] <sous-commande> [arguments]

    Sous-commandes :
      help [<cmd>]          Aide globale ou d'une sous-commande précise
      init [<société>]      Initialise ~/.beryl/<société>/ + propose providers/domaines
      add-provider          Ajoute un fournisseur à une société (credentials)
      add-domain            Ajoute un domaine à une société (zone DNS)
      list-hosts            Liste les hôtes de toutes les sociétés
      show <host>           Détails d'un hôte (config mergée complète)
      rescue <host>         Bascule un hôte en rescue via l'API hébergeur
      boot-hd <host>        Bascule sur le disque via l'API (inverse rescue)
      wipe <host> --disk    Efface un disque sur un hôte en rescue
      bootstrap <host>      Installe FreeBSD 15 (mfsBSD-in-QEMU)
      scan <host>           Détecte les disques et propose un YAML host
      apply <host>          Synchronise packages/users/clés SSH
      prep-rescue           HTTP local pour préparer un rescue Debian
      bake-seed             cloud-init seed.img pour Ubuntu Server live
      version               Affiche la version

    Host : FQDN (ex: rails01.aloli.net), nom court, ou identifiant hébergeur
           (service_name OVH, UUID Scaleway). Ajoutez `--domain=<nom>` si le
           domaine ne peut pas être déduit du nom.

    Options globales :
    BANNER
  end

  private def self.show_usage(parser : OptionParser) : Nil
    puts parser
  end

  # ---------- list-hosts ----------

  private def self.cmd_list_hosts(config_root : String) : Int32
    root = Beryl::Config::Root.load(config_root)
    all = root.all_hosts_by_fqdn
    if all.empty?
      puts "(aucun host dans #{config_root})"
      return 0
    end

    # Colonnes : FQDN, provider, groupe, service_name/id.
    rows = all.keys.sort.map do |fqdn|
      info = all[fqdn]
      rh = root.resolve(fqdn)
      [
        fqdn,
        rh.provider || "-",
        rh.group_name || "-",
        rh.ovh_service_name || rh.scaleway_server_id || "-",
      ]
    end
    widths = (0...rows.first.size).map { |i| rows.map(&.[i].size).max }
    rows.each do |r|
      puts r.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.to_a.join("  ")
    end
    0
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    1
  end

  # ---------- show ----------

  private def self.cmd_show(config_root : String, args : Array(String)) : Int32
    name = args.first?
    unless name
      STDERR.puts "USAGE : beryl show <host>"
      return 1
    end
    root = Beryl::Config::Root.load(config_root)
    rh = root.resolve(name, domain_hint: extract_domain_flag(args))

    puts "name:           #{rh.fqdn}"
    puts "domain:         #{rh.domain_name}"
    puts "group:          #{rh.group_name || "-"}"
    puts "provider:       #{rh.provider || "-"}"
    puts "ssh_host:       #{rh.ssh_host}"
    puts "port:           #{rh.port}"
    puts "user:           #{rh.user}"
    puts "virtual:        #{rh.virtual}"
    puts "fichiers mergés depuis :"
    puts "  _default.yml"
    puts "  #{rh.domain.source_path}"
    if g = rh.group
      puts "  #{g.source_path}" if g.source_path
    end
    puts "  #{rh.node.source_path}" unless rh.virtual
    0
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    1
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    1
  rescue ex : Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    1
  end

  # Extrait `--domain=X` d'un tableau d'arguments sans le consommer
  # (helper pour les sous-commandes qui veulent y accéder avant le
  # parser OptionParser complet). Version très simple, limitée à
  # `--domain=X` pour l'instant.
  def self.extract_domain_flag(args : Array(String)) : String?
    args.each do |a|
      if a.starts_with?("--domain=")
        return a[9..]
      end
    end
    nil
  end
end

exit Beryl::CLI.run
