require "option_parser"
require "./scope"
require "./option_errors"
require "../apply"
require "./account_utils"
require "./ssh_probe"

# `beryl pg-upgrade <host> [--to NN] [--apply]` — migre le serveur PostgreSQL
# d'un hôte FreeBSD d'une version MAJEURE à une autre (ex. 18 → 19). Générique :
# aucune application en dur, les services clients à arrêter sont donnés par
# `--stop-services`.
#
# Procédure = celle du fichier UPDATING des ports FreeBSD (entrée « The
# default version of PostgreSQL has been switched from 17 to 18 ») :
# `pkg create` des anciens paquets, extraction des anciens binaires dans
# /tmp/pg-upgrade, `pkg delete -f` des anciens, `pkg install` des nouveaux,
# `initdb` du nouveau cluster, `pg_upgrade -b <anciens binaires> …`, start.
# beryl y ajoute les gardes qu'une procédure manuelle oublie :
#
#   * dépendants (paquets construits contre l'ancien client : extensions,
#     pilotes Ruby/Python…) : refus si le dépôt ne les propose pas déjà
#     reconstruits pour la nouvelle majeure (sinon `pkg` les casserait) ;
#   * sauvegarde `pg_dumpall` AVANT tout, espace disque vérifié ;
#   * `initdb` aux options de l'ANCIEN cluster (encodage, locale, data
#     checksums, taille des segments WAL) — pg_upgrade exige qu'elles
#     correspondent ;
#   * `pg_upgrade --check` d'abord, retour arrière automatique en cas
#     d'échec AVANT le démarrage du nouveau serveur.
#
# DRY-RUN par défaut (lectures seules : détection + plan). `--apply` exécute.
# L'ancien data dir est CONSERVÉ ; `--cleanup` (dry-run puis `--apply`) le
# supprime une fois la nouvelle version en service.
module Beryl::CLI::PgUpgrade
  EXIT_OK      = 0
  EXIT_USAGE   = 1
  EXIT_FAILED  = 2
  EXIT_REFUSED = 3

  # Préfixe des ports : `databases/postgresql<NN>-{server,client,contrib…}`.
  BASE = "postgresql"
  # Binaires installés par les paquets (PREFIX par défaut des ports).
  BINDIR = "/usr/local/bin"
  # Répertoire d'extraction des anciens binaires (chemin de UPDATING).
  WORK_DIR = "/tmp/pg-upgrade"
  # Défaut de `--dump-dir` : HOME de l'utilisateur `postgres` créé par le port
  # (UID 770, home /var/db/postgres). Persistant au reboot (≠ /tmp), même
  # système de fichiers que les data dirs par défaut (un seul contrôle
  # d'espace), et déjà réservé aux données PostgreSQL (droits restreints).
  DEFAULT_DUMP_DIR = "/var/db/postgres"
  # Fichier d'état écrit dans `--dump-dir` après une migration réussie : lu
  # par `--cleanup` pour savoir quoi supprimer (clé=valeur, une par ligne).
  STATE_FILE = "pg-upgrade.state"

  # Noms de services / paquets / utilisateurs / chemins acceptés : rien qui
  # puisse s'échapper d'une ligne de commande (tout passe par `sh -c`).
  SAFE_NAME = /\A[A-Za-z0-9_.+-]+\z/
  SAFE_PATH = /\A\/[A-Za-z0-9_.\/-]+\z/

  record Options,
    to : String? = nil,
    apply : Bool = false,
    link : Bool = false,
    dump : Bool = true,
    dump_dir : String = DEFAULT_DUMP_DIR,
    stop_services : Array(String) = [] of String,
    new_data : String? = nil,
    cleanup : Bool = false

  def self.run(config_root : String, args : Array(String)) : Int32
    to : String? = nil
    apply = false
    link = false
    dump = true
    dump_dir = DEFAULT_DUMP_DIR
    services = [] of String
    new_data : String? = nil
    cleanup = false
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl pg-upgrade <host> [--to NN] [--stop-services a,b] [--link] [--apply]\n" \
                 "        beryl pg-upgrade <host> --cleanup [--apply]\n" \
                 "        Migre PostgreSQL d'une version majeure à une autre (pg_upgrade). DRY-RUN par défaut."
      p.on("--to=NN", "Majeure cible (ex. 19 ; défaut : la plus récente du dépôt)") { |v| to = v }
      p.on("--apply", "Exécute (sinon : détection + plan, rien n'est modifié)") { apply = true }
      p.on("--link", "pg_upgrade --link (rapide, peu d'espace) : PAS de retour arrière une fois le nouveau serveur démarré") { link = true }
      p.on("--stop-services=LISTE", "Services clients à arrêter avant / relancer après (séparés par des virgules)") do |v|
        services = v.split(',').map(&.strip).reject(&.empty?)
      end
      p.on("--dump-dir=DIR", "Répertoire de la sauvegarde pg_dumpall et des paquets de secours (défaut : #{DEFAULT_DUMP_DIR})") { |v| dump_dir = v.rchop('/') }
      p.on("--no-dump", "Pas de sauvegarde pg_dumpall préalable (déconseillé)") { dump = false }
      p.on("--new-data=DIR", "Data dir du nouveau cluster (seulement si postgresql_data est personnalisé)") { |v| new_data = v.rchop('/') }
      p.on("--cleanup", "Supprime l'ancien data dir, les paquets de secours et #{WORK_DIR} (nouvelle version en service)") { cleanup = true }
      p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    # Copie AVANT l'analyse : `parse` retire les options reconnues de `args`
    # (`--apply`…), que le rejeu par serveur doit garder.
    all_args = args.dup
    Beryl::CLI.handle_option_errors(parser).parse(args)
    # Plusieurs serveurs (liste, groupe, domaine, société) : rejouée pour chacun.
    if code = Beryl::CLI::Scope.fan_out("pg-upgrade", config_root, all_args, positional) { |a| run(config_root, a) }
      return code
    end

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl pg-upgrade <host> [--to NN] [--apply]"
      return EXIT_USAGE
    end
    opts = Options.new(to: to, apply: apply, link: link, dump: dump, dump_dir: dump_dir,
      stop_services: services, new_data: new_data, cleanup: cleanup)
    if err = validate(opts)
      STDERR.puts "beryl : #{err}"
      return EXIT_USAGE
    end

    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(parsed[:host], account_hint: parsed[:account] || account_hint,
      domain_hint: parsed[:domain] || domain_hint)
    unless host.os == "freebsd"
      STDERR.puts "beryl : pg-upgrade = FreeBSD uniquement (host : #{host.os})."
      return EXIT_USAGE
    end
    if apply && host.protected?
      STDERR.puts "beryl : #{host.fqdn} est protégé (protected: true) → --apply REFUSÉ (dry-run uniquement)."
      return EXIT_REFUSED
    end

    # Même cascade d'utilisateurs de connexion que os-upgrade, puis escalade
    # sudo : SudoShell passe CHAQUE commande par `sudo sh -c '…'`, donc les
    # commandes composées ne dépendent pas du shell de connexion (csh).
    user, probe = Beryl::CLI::SshProbe.reachable(host, "uname -s")
    unless user
      STDERR.puts "beryl : #{host.fqdn} injoignable en SSH (users tentés : #{host.connect_users.join(", ")}) — " \
                  "#{Beryl::CLI::SshProbe.compact_error(probe.stderr, probe.exit_code)}."
      return EXIT_FAILED
    end
    shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection(user)))
    Migration.new(shell, opts, host.fqdn).run
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain | ArgumentError
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_FAILED
  end

  # Contrôle des options AVANT toute connexion. nil si tout va bien.
  def self.validate(opts : Options) : String?
    if t = opts.to
      return "--to attend un numéro de majeure (ex. 19), reçu #{t.inspect}" unless t.matches?(/\A\d+\z/)
    end
    return "--dump-dir doit être un chemin absolu simple (reçu #{opts.dump_dir.inspect})" unless safe_dir?(opts.dump_dir)
    if nd = opts.new_data
      return "--new-data doit être un chemin absolu simple (reçu #{nd.inspect})" unless safe_dir?(nd)
    end
    bad = opts.stop_services.reject(&.matches?(SAFE_NAME))
    return "--stop-services : nom(s) de service invalide(s) : #{bad.join(", ")}" unless bad.empty?
    nil
  end

  # Chemin absolu, caractères sûrs, et au moins deux niveaux (jamais `/` ni
  # `/var` : ces chemins finissent dans des `rm -rf`).
  def self.safe_dir?(path : String) : Bool
    path.matches?(SAFE_PATH) && !path.includes?("..") && path.split('/').count { |s| !s.empty? } >= 2
  end

  # Clé de tri d'un numéro de majeure FreeBSD : `96` = 9.6 (avant la
  # numérotation à un chiffre de PostgreSQL 10), sinon le numéro lui-même.
  def self.major_key(code : String) : Float64
    n = code.to_i
    n >= 90 ? n / 10.0 : n.to_f
  end

  # « Data page checksum version: 1 » (sortie de pg_controldata) → true ;
  # 0 → false ; ligne absente → nil (état inconnu = refus).
  def self.parse_checksums(controldata : String) : Bool?
    m = controldata.match(/^Data page checksum version:\s+(\d+)/m)
    m ? m[1].to_i != 0 : nil
  end

  # « Bytes per WAL segment: 16777216 » → 16777216. nil si absent.
  def self.parse_wal_segment(controldata : String) : Int64?
    controldata.match(/^Bytes per WAL segment:\s+(\d+)/m).try(&.[1].to_i64)
  end

  # Ligne de `df -kP <dir> | tail -1` → {système de fichiers, Ko disponibles}.
  def self.parse_df(line : String) : {String, Int64}?
    f = line.split
    return unless f.size >= 6 && f[3].matches?(/\A\d+\z/)
    {f[0], f[3].to_i64}
  end

  # Réglages régionaux d'un cluster, lus sur la base `template1`.
  record Locale, encoding : String, collate : String, ctype : String,
    provider : String = "c", locale : String = ""

  # Options d'`initdb` reproduisant l'ancien cluster. `--no-data-checksums`
  # n'existe que depuis PostgreSQL 18 (qui active les checksums par défaut) :
  # pour une cible plus ancienne, l'absence de flag suffit.
  def self.initdb_flags(locale : Locale, checksums : Bool, new_major : String, wal_segment : Int64?) : Array(String)
    flags = ["--encoding=#{locale.encoding}", "--lc-collate=#{locale.collate}", "--lc-ctype=#{locale.ctype}"]
    case locale.provider
    when "i" then flags.concat(["--locale-provider=icu", "--icu-locale=#{locale.locale}"])
    when "b" then flags.concat(["--locale-provider=builtin", "--builtin-locale=#{locale.locale}"])
    end
    if checksums
      flags << "--data-checksums"
    elsif major_key(new_major) >= 18
      flags << "--no-data-checksums"
    end
    if (w = wal_segment) && w != 16_i64 * 1024 * 1024
      flags << "--wal-segsize=#{w // (1024 * 1024)}"
    end
    flags
  end

  # Taille lisible (Ko → Mo/Go).
  def self.human_kb(kb : Int64) : String
    kb >= 1024_i64 * 1024 ? "#{(kb / (1024.0 * 1024)).round(1)} Go" : "#{(kb / 1024.0).round(1)} Mo"
  end

  # Refus d'une précondition (message destiné à l'utilisateur, code 3).
  class Refused < Exception
  end

  # Étape mutante en échec pendant la migration (déclenche le retour arrière).
  class StepFailed < Exception
  end

  # Tout ce que la détection a établi, puis consommé par l'exécution.
  class Plan
    property old_major = ""
    property new_major = ""
    property pg_user = "postgres"
    property home = ""
    property old_data = ""
    property new_data = ""
    # postgresql_data posé dans rc.conf → à repointer vers le nouveau data dir.
    property rc_data_set = false
    # Paquets `postgresql<old>-*` installés, et leurs équivalents à installer.
    property family = [] of String
    property new_family = [] of String
    # Paquets installés (hors famille) qui dépendent de la famille.
    property dependents = [] of String
    property initdb_flags = [] of String
    property checksums = false
    property data_kb = 0_i64
    property pkg_dir = ""
    property dump_file = ""
  end

  # Migration d'UN hôte, sur un `Shell` déjà escaladé (root). Séparée de la
  # résolution d'hôte pour être testée avec un FakeShell.
  class Migration
    getter plan = Plan.new

    def initialize(@shell : Beryl::Apply::Shell, @opts : Options, @label : String,
                   @out : IO = STDOUT, @err : IO = STDERR, @now : Time = Time.local)
      # Étapes déjà franchies : pilotent le retour arrière.
      @stopped_services = [] of String
      @old_stopped = false
      @old_removed = false
      @deps_touched = false
      @new_data_created = false
      @upgrade_started = false
    end

    def run : Int32
      return cleanup if @opts.cleanup
      prepare
      print_plan
      return EXIT_OK unless @opts.apply
      execute
    rescue ex : Refused
      @err.puts "beryl : #{@label} — #{ex.message}"
      EXIT_REFUSED
    rescue ex : NothingToDo
      log ex.message.to_s
      EXIT_OK
    end

    # Cible déjà atteinte sans `--to` explicite : rien à faire (code 0).
    class NothingToDo < Exception
    end

    # ── Détection (lectures seules, exécutée aussi en dry-run) ──────────────
    def prepare : Nil
      p = @plan
      profiles = read("sysrc -n postgresql_profiles 2>/dev/null")
      refuse("postgresql_profiles est posé (#{profiles}) : plusieurs clusters par profil ne sont pas gérés.") unless profiles.empty?
      user = read("sysrc -n postgresql_user 2>/dev/null")
      p.pg_user = user.empty? ? "postgres" : user
      refuse("postgresql_user invalide : #{p.pg_user.inspect}") unless p.pg_user.matches?(SAFE_NAME)

      installed = installed_names
      server = installed.compact_map(&.match(/^#{BASE}(\d+)-server$/)).first?
      refuse("aucun serveur PostgreSQL installé (paquet #{BASE}NN-server absent).") unless server
      p.old_major = server[1]

      # Catalogue rafraîchi : `rquery -U` n'interroge que les catalogues déjà
      # téléchargés (cf. primitive pkg-versioned).
      @shell.exec("pkg update -q", raise_on_error: false)
      if t = @opts.to
        p.new_major = t
        if PgUpgrade.major_key(t) <= PgUpgrade.major_key(p.old_major)
          refuse("cible #{t} <= version installée #{p.old_major} : rien à migrer (jamais de descente de version).")
        end
      else
        latest = latest_in_repo
        refuse("aucun paquet #{BASE}NN-server dans le dépôt (réseau ? pkg update ?).") unless latest
        if PgUpgrade.major_key(latest) <= PgUpgrade.major_key(p.old_major)
          raise NothingToDo.new("#{@label} : PostgreSQL #{p.old_major} = version la plus récente du dépôt — rien à faire.")
        end
        p.new_major = latest
      end
      log "#{@label} : PostgreSQL #{p.old_major} → #{p.new_major}"

      # Famille installée (`postgresql17-server`, `-client`, `-contrib`,
      # `-plperl`…) et équivalents de la nouvelle majeure : tous au dépôt.
      p.family = installed.select(&.matches?(/^#{BASE}#{p.old_major}-/))
      p.new_family = p.family.map(&.sub(/^#{BASE}#{p.old_major}-/, "#{BASE}#{p.new_major}-"))
      missing = p.new_family.reject { |n| in_repo?(n) }
      unless missing.empty?
        refuse("absent(s) du dépôt : #{missing.join(", ")}. Le dépôt de paquets ne propose pas PostgreSQL #{p.new_major} " \
               "(ou pas tous ses composants).")
      end
      check_dependents

      # Data dirs. Défaut du script rc : ~postgres/data<NN> ; un
      # postgresql_data posé dans rc.conf prime et devra être repointé.
      p.home = read("echo ~#{p.pg_user}")
      refuse("répertoire personnel de #{p.pg_user} introuvable (#{p.home.inspect}).") unless PgUpgrade.safe_dir?(p.home)
      custom = read("sysrc -n postgresql_data 2>/dev/null").rchop('/')
      p.rc_data_set = !custom.empty?
      p.old_data = custom.empty? ? "#{p.home}/data#{p.old_major}" : custom
      refuse("postgresql_data invalide : #{p.old_data.inspect}") unless PgUpgrade.safe_dir?(p.old_data)
      p.new_data =
        if nd = @opts.new_data
          nd
        elsif !custom.empty?
          unless custom.ends_with?("data#{p.old_major}")
            refuse("postgresql_data personnalisé (#{custom}) : précisez le data dir du nouveau cluster avec --new-data=DIR.")
          end
          custom.sub(/data#{p.old_major}\z/, "data#{p.new_major}")
        else
          "#{p.home}/data#{p.new_major}"
        end
      refuse("le nouveau data dir est l'ancien (#{p.new_data}).") if p.new_data == p.old_data
      pg_version = read("cat #{p.old_data}/PG_VERSION 2>/dev/null")
      unless pg_version.delete('.') == p.old_major
        refuse("#{p.old_data}/PG_VERSION = #{pg_version.inspect}, attendu #{p.old_major} : ce n'est pas le cluster en service.")
      end
      if ok?("test -e #{p.new_data}")
        refuse("#{p.new_data} existe déjà (reste d'un essai ?). Vérifiez-le et supprimez-le avant de relancer.")
      end
      refuse("#{@opts.dump_dir} n'existe pas (--dump-dir).") unless ok?("test -d #{@opts.dump_dir}")
      p.pkg_dir = "#{@opts.dump_dir}/pg-upgrade-#{BASE}#{p.old_major}-pkg"
      p.dump_file = "#{@opts.dump_dir}/pg_dumpall-#{p.old_major}-#{@now.to_s("%Y%m%d-%H%M%S")}.sql"

      @opts.stop_services.each do |svc|
        unless ok?("test -x /etc/rc.d/#{svc} -o -x /usr/local/etc/rc.d/#{svc}")
          refuse("service #{svc} inconnu (aucun script /etc/rc.d/#{svc} ni /usr/local/etc/rc.d/#{svc}).")
        end
      end

      # L'ancien serveur doit tourner : réglages régionaux lus par psql, et
      # sauvegarde pg_dumpall.
      unless ok?("service postgresql status")
        refuse("le serveur PostgreSQL #{p.old_major} ne tourne pas : démarrez-le (`service postgresql start`) puis relancez.")
      end
      read_cluster_settings
      check_space
    end

    # Garde « dépendants » : un paquet installé qui dépend de la famille
    # (pilote Ruby/Python, extension type PostGIS…) serait SUPPRIMÉ par pkg
    # (ou laissé cassé) si le dépôt ne le propose pas reconstruit contre la
    # nouvelle majeure. On le vérifie sur la version DISTANTE du paquet.
    private def check_dependents : Nil
      p = @plan
      deps = p.family.flat_map { |f| lines("pkg query '%rn' #{f}") }.uniq.sort - p.family
      p.dependents = deps
      return if deps.empty?
      log "#{@label} : paquets dépendant de PostgreSQL #{p.old_major} : #{deps.join(", ")}"
      not_rebuilt = [] of String
      deps.each do |d|
        remote = lines("pkg rquery -U '%dn' #{d}")
        if remote.empty? && !in_repo?(d)
          not_rebuilt << "#{d} (absent du dépôt)"
        elsif remote.any?(&.matches?(/^#{BASE}#{p.old_major}-/))
          not_rebuilt << "#{d} (construit contre #{BASE}#{p.old_major})"
        end
      end
      return if not_rebuilt.empty?
      refuse("le dépôt ne propose pas ces paquets reconstruits pour PostgreSQL #{p.new_major} : #{not_rebuilt.join(", ")}. " \
             "pkg les supprimerait. Reconstruisez d'abord le dépôt de paquets avec `DEFAULT_VERSIONS+= pgsql=#{p.new_major}` " \
             "(make.conf de poudriere), publiez-le, puis relancez.")
    end

    # Options d'initdb de l'ancien cluster : checksums + segments WAL via
    # pg_controldata, encodage/locale via psql (serveur en marche).
    private def read_cluster_settings : Nil
      p = @plan
      cd = @shell.exec(as_pg("#{BINDIR}/pg_controldata -D #{p.old_data}"), raise_on_error: false)
      checksums = PgUpgrade.parse_checksums(cd.stdout)
      refuse("pg_controldata illisible sur #{p.old_data} (état des data checksums inconnu).") if checksums.nil?
      p.checksums = checksums
      p.initdb_flags = PgUpgrade.initdb_flags(read_locale, checksums, p.new_major, PgUpgrade.parse_wal_segment(cd.stdout))
    end

    # Encodage / locale de template1. Colonnes selon la version source :
    # `datlocale` (17+), `daticulocale` (15-16), aucun fournisseur (≤ 14).
    private def read_locale : Locale
      base = "select pg_encoding_to_char(encoding), datcollate, datctype"
      where = "from pg_database where datname = current_database()"
      ["#{base}, datlocprovider, datlocale #{where}",
       "#{base}, datlocprovider, daticulocale #{where}",
       "#{base} #{where}"].each do |sql|
        res = @shell.exec(as_pg("#{BINDIR}/psql -XAt -d template1 -c #{Process.quote(sql)}"), raise_on_error: false)
        next unless res.success?
        f = res.stdout.strip.split('|')
        next if f.size < 3 || f[0].empty?
        bad = f.reject(&.empty?).reject(&.matches?(SAFE_NAME))
        refuse("réglages régionaux inattendus : #{f.join(" | ")}") unless bad.empty?
        return Locale.new(f[0], f[1], f[2], f[3]? || "c", f[4]? || "")
      end
      refuse("encodage / locale de l'ancien cluster illisibles (psql sur template1 en échec).")
    end

    # Espace libre : nouveau cluster (copie = taille de l'ancien) + dump
    # (≤ taille de l'ancien) ; additionnés s'ils partagent un système de
    # fichiers. En --link, le nouveau cluster ne copie pas les données.
    private def check_space : Nil
      p = @plan
      p.data_kb = read("du -sk #{p.old_data}").split.first?.try(&.to_i64?) || 0_i64
      refuse("taille de #{p.old_data} illisible (du).") if p.data_kb <= 0
      need = Hash(String, Int64).new(0_i64)
      avail = {} of String => Int64
      wanted = [] of {String, Int64}
      wanted << {File.dirname(p.new_data), p.data_kb} unless @opts.link
      wanted << {@opts.dump_dir, p.data_kb} if @opts.dump
      wanted.each do |dir, kb|
        df = PgUpgrade.parse_df(read("df -kP #{dir} | tail -1"))
        refuse("espace libre illisible sur #{dir} (df).") unless df
        need[df[0]] += kb
        avail[df[0]] = df[1]
      end
      need.each do |fs, kb|
        if avail[fs] < kb
          refuse("espace insuffisant sur #{fs} : #{PgUpgrade.human_kb(avail[fs])} libres, #{PgUpgrade.human_kb(kb)} nécessaires " \
                 "(data dir #{PgUpgrade.human_kb(p.data_kb)}#{@opts.link ? "" : " copié"}#{@opts.dump ? " + dump" : ""}). " \
                 "Libérez de la place, ou --link, ou --dump-dir ailleurs.")
        end
      end
    end

    # ── Plan affiché (dry-run comme --apply) ────────────────────────────────
    private def print_plan : Nil
      p = @plan
      o = @out
      o.puts ""
      o.puts "Migration PostgreSQL #{p.old_major} → #{p.new_major} sur #{@label}#{@opts.apply ? "" : " (dry-run)"} :"
      o.puts "  ancien cluster : #{p.old_data} (#{PgUpgrade.human_kb(p.data_kb)}, data checksums #{p.checksums ? "ACTIVÉS" : "désactivés"})"
      o.puts "  nouveau        : #{p.new_data}#{p.rc_data_set ? " (rc.conf postgresql_data repointé)" : ""}"
      o.puts "  paquets        : #{p.family.join(" ")} → #{p.new_family.join(" ")}"
      o.puts "  dépendants     : #{p.dependents.empty? ? "aucun" : "#{p.dependents.join(" ")} (réinstallés depuis le dépôt)"}"
      o.puts "  initdb         : #{p.initdb_flags.join(" ")}"
      o.puts "  mode           : #{@opts.link ? "--link (PAS de retour arrière après démarrage du nouveau serveur)" : "copie (l'ancien cluster reste intact)"}"
      o.puts ""
      steps.each_with_index { |s, i| o.puts "  #{(i + 1).to_s.rjust(2)}. #{s}" }
      o.puts ""
      return if @opts.apply
      o.puts "→ ajoutez `--apply` pour exécuter. Échec avant l'étape « service postgresql start » = retour arrière automatique."
    end

    private def steps : Array(String)
      p = @plan
      s = [] of String
      s << "pg_dumpall > #{p.dump_file}" if @opts.dump
      @opts.stop_services.each { |svc| s << "service #{svc} stop" }
      s << "service postgresql stop"
      s << "pkg create -o #{p.pkg_dir} #{(p.family + p.dependents).join(" ")}"
      s << "extraction des anciens binaires dans #{WORK_DIR}"
      s << "pkg delete -f -y #{p.family.join(" ")}"
      s << "pkg install -y #{p.new_family.join(" ")}"
      s << "pkg install -f -y #{p.dependents.join(" ")}" unless p.dependents.empty?
      s << "initdb #{p.initdb_flags.join(" ")} -D #{p.new_data}"
      s << "reprise de postgresql.conf / pg_hba.conf / pg_ident.conf (+ certificats) de l'ancien cluster"
      s << "pg_upgrade --check#{@opts.link ? " --link" : ""}"
      s << "pg_upgrade#{@opts.link ? " --link" : ""}"
      s << "sysrc postgresql_data=#{p.new_data}" if p.rc_data_set
      s << "service postgresql start"
      s << "vacuumdb --all --analyze-in-stages#{missing_stats? ? " --missing-stats-only" : ""}"
      @opts.stop_services.each { |svc| s << "service #{svc} start" }
      s
    end

    # pg_upgrade ≥ 18 transfère les statistiques : vacuumdb ne recalcule que
    # celles qui manquent (option apparue en 18).
    private def missing_stats? : Bool
      PgUpgrade.major_key(@plan.new_major) >= 18
    end

    # ── Exécution (--apply) ──────────────────────────────────────────────────
    private def execute : Int32
      p = @plan
      if @opts.dump
        log "#{@label} : sauvegarde pg_dumpall → #{p.dump_file}"
        step("umask 077 && #{as_pg("#{BINDIR}/pg_dumpall")} > #{p.dump_file}", "pg_dumpall", rollback: false)
        step("test -s #{p.dump_file}", "sauvegarde vide (#{p.dump_file})", rollback: false)
      end

      begin
        @opts.stop_services.each do |svc|
          log "#{@label} : arrêt de #{svc}"
          step("service #{svc} stop", "arrêt de #{svc}")
          @stopped_services << svc
        end
        log "#{@label} : arrêt de PostgreSQL #{p.old_major}"
        step("service postgresql stop", "arrêt de PostgreSQL #{p.old_major}")
        @old_stopped = true

        log "#{@label} : paquets de secours → #{p.pkg_dir}"
        step("mkdir -p #{p.pkg_dir} && pkg create -o #{p.pkg_dir} #{(p.family + p.dependents).join(" ")}", "pkg create")
        client = "#{BASE}#{p.old_major}-client"
        extract = p.family.reject(&.==(client)).map { |n| "tar xf #{pkg_glob(n)} -C #{WORK_DIR}" }
        step("rm -rf #{WORK_DIR} && mkdir -p #{WORK_DIR} && #{extract.join(" && ")}", "extraction des anciens paquets")
        step("test -x #{WORK_DIR}#{BINDIR}/postgres", "anciens binaires absents de #{WORK_DIR}#{BINDIR}")

        log "#{@label} : remplacement des paquets #{p.old_major} → #{p.new_major}"
        @old_removed = true
        step("pkg delete -f -y #{p.family.join(" ")}", "pkg delete")
        step(install_cmd(p.new_family), "pkg install #{p.new_family.join(" ")}")
        unless p.dependents.empty?
          @deps_touched = true
          step(reinstall_cmd(p.dependents), "réinstallation des dépendants")
        end

        log "#{@label} : initdb #{p.new_data}"
        @new_data_created = true
        step(as_pg("#{BINDIR}/initdb #{p.initdb_flags.join(" ")} -D #{p.new_data} -U #{p.pg_user}"), "initdb")
        carry_config

        upgrade = "#{BINDIR}/pg_upgrade -b #{WORK_DIR}#{BINDIR} -d #{p.old_data} -B #{BINDIR} -D #{p.new_data} -U #{p.pg_user}"
        upgrade += " --link" if @opts.link
        log "#{@label} : pg_upgrade --check"
        step(as_pg("#{upgrade} --check"), "pg_upgrade --check")
        log "#{@label} : pg_upgrade#{@opts.link ? " --link" : ""}"
        @upgrade_started = true
        step(as_pg(upgrade), "pg_upgrade")
        step("sysrc postgresql_data=#{p.new_data}", "sysrc postgresql_data") if p.rc_data_set
      rescue ex : StepFailed
        @err.puts "beryl : #{@label} — échec : #{ex.message}"
        return rollback
      end

      # Point de non-retour : au-delà, le nouveau cluster a pu tourner.
      log "#{@label} : démarrage de PostgreSQL #{p.new_major}"
      unless ok?("service postgresql start")
        @err.puts "beryl : #{@label} — PostgreSQL #{p.new_major} ne démarre pas. PAS de retour arrière automatique à ce stade."
        @err.puts "        Journal : `tail /var/log/messages` ; ancien cluster : #{p.old_data} ; paquets #{p.old_major} : #{p.pkg_dir} ; dump : #{@opts.dump ? p.dump_file : "aucun"}."
        return EXIT_FAILED
      end
      write_state

      log "#{@label} : vacuumdb --all --analyze-in-stages (statistiques)"
      vac = "#{BINDIR}/vacuumdb --all --analyze-in-stages#{missing_stats? ? " --missing-stats-only" : ""}"
      log "#{@label} : ⚠ vacuumdb a échoué — relancez-le : #{vac}" unless ok?(as_pg(vac))
      restart_services
      summary
      EXIT_OK
    end

    # pg_upgrade ne reprend PAS la configuration : on recopie celle de
    # l'ancien cluster (les versions initdb gardées en `.initdb`), puis on la
    # fait valider par le NOUVEAU serveur (`postgres -C`). Refusée (paramètre
    # supprimé…) → retour aux confs d'initdb pour postgresql*.conf + alerte.
    private def carry_config : Nil
      p = @plan
      files = "postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf"
      step("cd #{p.new_data} && for f in #{files}; do [ -f #{p.old_data}/$f ] || continue; " \
           "[ -f $f ] && cp -p $f $f.initdb; cp -p #{p.old_data}/$f $f; done; " \
           "for f in #{p.old_data}/*.crt #{p.old_data}/*.key #{p.old_data}/*.pem; do [ -f $f ] && cp -p $f #{p.new_data}/; done; true",
        "reprise de la configuration")
      return if ok?(as_pg("#{BINDIR}/postgres -D #{p.new_data} -C data_directory"))
      log "#{@label} : ⚠ postgresql.conf de l'ancien cluster refusé par PostgreSQL #{p.new_major} → conf d'initdb gardée ; " \
          "reportez vos réglages à la main (ancienne conf : #{p.old_data}/postgresql.conf)."
      step("cd #{p.new_data} && for f in postgresql.conf postgresql.auto.conf; do [ -f $f.initdb ] && mv $f.initdb $f; done; true",
        "restauration des confs d'initdb")
    end

    # Retour arrière (échec AVANT le démarrage du nouveau serveur) : nouveaux
    # paquets retirés, anciens réinstallés depuis les .pkg de `pkg create`,
    # nouveau data dir supprimé, ancien cluster relancé, services relancés.
    private def rollback : Int32
      p = @plan
      log "#{@label} : RETOUR ARRIÈRE vers PostgreSQL #{p.old_major}"
      problems = [] of String
      if @upgrade_started && @opts.link
        # pg_upgrade --link renomme global/pg_control en pg_control.old dès
        # qu'il commence à lier : le remettre rend l'ancien cluster démarrable.
        ctl = "#{p.old_data}/global/pg_control"
        problems << "pg_control.old" unless ok?("if [ -f #{ctl}.old ] && [ ! -f #{ctl} ]; then mv #{ctl}.old #{ctl}; fi")
      end
      if @old_removed
        new_pkgs = installed_names.select(&.matches?(/^#{BASE}#{p.new_major}-/))
        remove = new_pkgs + (@deps_touched ? p.dependents : [] of String)
        problems << "pkg delete #{remove.join(" ")}" unless remove.empty? || ok?("pkg delete -f -y #{remove.join(" ")}")
        # Client d'abord : les autres composants en dépendent. Seuls les
        # paquets réellement absents (un `pkg delete` a pu échouer en route).
        client = "#{BASE}#{p.old_major}-client"
        ordered = p.family.select(&.==(client)) + p.family.reject(&.==(client))
        ordered += p.dependents if @deps_touched
        present = installed_names
        to_add = ordered.reject { |n| present.includes?(n) }
        unless to_add.empty? || ok?("pkg add #{to_add.map { |n| pkg_glob(n) }.join(" ")}")
          problems << "pkg add #{to_add.join(" ")}"
        end
      end
      if @new_data_created
        problems << "rm #{p.new_data}" unless ok?("rm -rf #{p.new_data}")
      end
      if @old_stopped
        problems << "service postgresql start" unless ok?("service postgresql start")
      end
      restart_services
      if problems.empty?
        @err.puts "beryl : #{@label} — retour arrière effectué : PostgreSQL #{p.old_major} relancé sur #{p.old_data}, intact."
      else
        @err.puts "beryl : #{@label} — RETOUR ARRIÈRE INCOMPLET (#{problems.join(" ; ")}). À reprendre à la main :"
        @err.puts "        paquets #{p.old_major} : `pkg add #{p.pkg_dir}/*.pkg` ; ancien cluster : #{p.old_data} ; " \
                  "dump : #{@opts.dump ? p.dump_file : "aucun"}."
      end
      EXIT_FAILED
    end

    private def restart_services : Nil
      @stopped_services.each do |svc|
        log "#{@label} : relance de #{svc}"
        log "#{@label} : ⚠ `service #{svc} start` a échoué" unless ok?("service #{svc} start")
      end
      @stopped_services.clear
    end

    # Mémorise la migration pour `--cleanup` (lu par `cleanup`).
    private def write_state : Nil
      p = @plan
      content = {"old_major" => p.old_major, "new_major" => p.new_major, "old_data" => p.old_data,
                 "new_data" => p.new_data, "pkg_dir" => p.pkg_dir, "home" => p.home, "pg_user" => p.pg_user}
        .map { |k, v| "#{k}=#{v}" }.join("\n") + "\n"
      @shell.write_file("#{@opts.dump_dir}/#{STATE_FILE}", content, "0600")
    end

    private def summary : Nil
      p = @plan
      o = @out
      o.puts ""
      o.puts "PostgreSQL #{p.new_major} en service sur #{@label} (#{p.new_data})."
      o.puts "Reste à faire :"
      o.puts "  * vérifier les applications (connexions, requêtes) ;"
      if ok?("test -f #{p.home}/update_extensions.sql")
        o.puts "  * mettre à jour les extensions : su -l #{p.pg_user} -c '#{BINDIR}/psql -f #{p.home}/update_extensions.sql'"
      end
      o.puts "  * comparer la conf : #{p.new_data}/*.initdb = défauts de PostgreSQL #{p.new_major} ;"
      o.puts "  * sauvegarde : #{p.dump_file} (à garder jusqu'à validation)." if @opts.dump
      o.puts "  * ancien cluster CONSERVÉ : #{p.old_data} ; paquets #{p.old_major} : #{p.pkg_dir}."
      o.puts "  * une fois validé : beryl pg-upgrade #{@label} --cleanup#{dump_dir_flag} [--apply]"
      o.puts "    (#{@opts.link ? "--link : l'ancien cluster n'est déjà plus utilisable" : "jusque-là, retour arrière manuel possible"})."
    end

    private def dump_dir_flag : String
      @opts.dump_dir == DEFAULT_DUMP_DIR ? "" : " --dump-dir=#{@opts.dump_dir}"
    end

    # ── --cleanup ───────────────────────────────────────────────────────────
    # Supprime l'ancien data dir, les paquets de secours, WORK_DIR et le
    # script delete_old_cluster.sh de pg_upgrade — seulement si la nouvelle
    # version tourne bien sur le nouveau data dir. Le dump est gardé.
    private def cleanup : Int32
      state_path = "#{@opts.dump_dir}/#{STATE_FILE}"
      st = read("cat #{state_path} 2>/dev/null").lines.compact_map do |l|
        k, _, v = l.partition('=')
        {k.strip, v.strip} unless k.strip.empty?
      end.to_h
      %w[old_major new_major old_data new_data pkg_dir home pg_user].each do |k|
        refuse("aucune migration enregistrée (#{state_path} absent ou incomplet).") unless st[k]?.try { |v| !v.empty? }
      end
      %w[old_data new_data pkg_dir home].each do |k|
        refuse("#{state_path} : chemin #{k} invalide (#{st[k].inspect}).") unless PgUpgrade.safe_dir?(st[k])
      end
      refuse("#{state_path} : utilisateur invalide.") unless st["pg_user"].matches?(SAFE_NAME)
      refuse("#{state_path} : ancien et nouveau data dir identiques.") if st["old_data"] == st["new_data"]

      server = installed_names.compact_map(&.match(/^#{BASE}(\d+)-server$/)).first?.try(&.[1])
      refuse("PostgreSQL installé = #{server || "aucun"}, attendu #{st["new_major"]} : nettoyage refusé.") unless server == st["new_major"]
      refuse("PostgreSQL #{st["new_major"]} ne tourne pas : nettoyage refusé.") unless ok?("service postgresql status")
      running = read(as_pg_user(st["pg_user"], "#{BINDIR}/psql -XAt -d template1 -c #{Process.quote("show data_directory")}")).rchop('/')
      unless running == st["new_data"]
        refuse("le serveur en service utilise #{running.inspect}, pas #{st["new_data"]} : nettoyage refusé.")
      end

      targets = [st["old_data"], st["pkg_dir"], WORK_DIR, "#{st["home"]}/delete_old_cluster.sh", state_path]
      @out.puts ""
      @out.puts "Nettoyage après migration #{st["old_major"]} → #{st["new_major"]} sur #{@label}#{@opts.apply ? "" : " (dry-run)"} :"
      targets.each { |t| @out.puts "  rm -rf #{t}" }
      @out.puts "  (la sauvegarde pg_dumpall de #{@opts.dump_dir} est conservée)"
      unless @opts.apply
        @out.puts "→ ajoutez `--apply` pour supprimer."
        return EXIT_OK
      end
      unless ok?("rm -rf #{targets.join(" ")}")
        @err.puts "beryl : #{@label} — suppression incomplète (rm -rf)."
        return EXIT_FAILED
      end
      log "#{@label} : ancien cluster #{st["old_major"]} et fichiers de migration supprimés."
      EXIT_OK
    rescue ex : Refused
      @err.puts "beryl : #{@label} — #{ex.message}"
      EXIT_REFUSED
    end

    # ── Utilitaires ─────────────────────────────────────────────────────────
    private def installed_names : Array(String)
      lines("pkg query '%n'")
    end

    private def in_repo?(name : String) : Bool
      read("pkg rquery -U '%n' #{name}").lines.map(&.strip).includes?(name)
    end

    # Majeure la plus récente du dépôt, sur la VRAIE version (%v) : le nom
    # trompe un tri (`96` > `17`). Même méthode que pkg-versioned.
    private def latest_in_repo : String?
      line = read("pkg rquery -U '%v %n' | awk '$2 ~ /^#{BASE}[0-9]+-server$/' | sort -V | tail -1")
      line.split(' ').last?.try(&.match(/^#{BASE}(\d+)-server$/)).try(&.[1])
    end

    # Fichier .pkg créé par `pkg create` pour un paquet (nom-version.pkg) ;
    # le chiffre après le tiret écarte `py311-psycopg-pool` pour `py311-psycopg`.
    private def pkg_glob(name : String) : String
      "#{@plan.pkg_dir}/#{name}-[0-9]*.pkg"
    end

    # Commande exécutée sous l'utilisateur PostgreSQL (shell de login, comme
    # dans UPDATING). Une seule ligne : jamais de saut de ligne entre
    # apostrophes (csh : « Unmatched ' »).
    private def as_pg(cmd : String) : String
      as_pg_user(@plan.pg_user, cmd)
    end

    private def as_pg_user(user : String, cmd : String) : String
      "su -l #{user} -c #{Process.quote(cmd)}"
    end

    # Étape mutante : un échec lève StepFailed (→ retour arrière).
    private def step(cmd : String, what : String, rollback : Bool = true) : Nil
      res = @shell.exec(cmd, raise_on_error: false)
      return if res.success?
      detail = (res.stderr.strip.empty? ? res.stdout : res.stderr).strip.lines.last(3).join(" | ")
      msg = "#{what} (code #{res.exit_code})#{detail.empty? ? "" : " : #{detail}"}"
      raise StepFailed.new(msg) if rollback
      raise Refused.new("#{msg} — rien n'a été modifié.")
    end

    # `pkg install -y` des nouveaux paquets, un `-r <dépôt>` par dépôt choisi
    # par pkg dans son plan (`pkg install -n`) : sans `-r`, un paquet offert
    # par deux dépôts (gmp, mpfr… copies de FreeBSD-ports republiées dans le
    # dépôt maison) est installé sans que rien ne le réclame (shingouz, 27
    # oct. 2026 ; cf. `Primitive.pkg_install`).
    private def install_cmd(names : Array(String)) : String
      plan = @shell.exec("pkg install -n #{names.join(" ")}", raise_on_error: false).stdout
      repo_cmds(names, Beryl::Apply::Primitive.planned_repos(plan), "pkg install")
    end

    # `pkg install -f -y` des dépendants (réinstallés contre la nouvelle
    # libpq), chacun depuis son dépôt d'origine (`%R`).
    private def reinstall_cmd(names : Array(String)) : String
      out = @shell.exec("pkg query '%n %R' #{names.join(" ")}", raise_on_error: false).stdout
      origin = out.lines.compact_map { |l| a = l.split; {a[0], a[1]} if a.size >= 2 }.to_h
      repo_cmds(names, origin, "pkg install -f")
    end

    private def repo_cmds(names : Array(String), repo_of : Hash(String, String), pkg : String) : String
      Beryl::Apply::Primitive.repo_groups(names, repo_of).map do |repo, group|
        "#{pkg} #{repo ? "-r #{Process.quote(repo)} " : ""}-y #{group.join(" ")}"
      end.join(" && ")
    end

    private def ok?(cmd : String) : Bool
      @shell.exec(cmd, raise_on_error: false).success?
    end

    private def read(cmd : String) : String
      @shell.exec(cmd, raise_on_error: false).stdout.strip
    end

    private def lines(cmd : String) : Array(String)
      read(cmd).lines.map(&.strip).reject(&.empty?)
    end

    private def refuse(msg : String) : NoReturn
      raise Refused.new(msg)
    end

    private def log(msg : String) : Nil
      @err.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl pg-upgrade] #{msg}"
    end
  end
end
