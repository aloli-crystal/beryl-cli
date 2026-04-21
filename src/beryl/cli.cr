require "option_parser"
require "load-env"
require "../beryl"
require "./cli/prep_rescue"
require "./cli/bake_seed"
require "./cli/rescue"
require "./cli/boot_hd"
require "./cli/wipe"

# Point d'entrée CLI de beryl.
#
# Syntaxe générale :
#   beryl [-i INVENTAIRE] <sous-commande> [arguments]
#
# Sous-commandes disponibles au MVP :
#   list-hosts             Affiche les hôtes de l'inventaire.
#   show <host>            Détaille un hôte.
#   rescue <host>          Bascule un hôte en mode rescue via l'API hébergeur.
#   bootstrap <host> …     Installe FreeBSD sur un rescue Linux distant.
#   prep-rescue            Sert la clé SSH et un script de provisioning sur
#                          HTTP local pour préparer un rescue Debian/Ubuntu.
#   version                Affiche la version.
module Beryl::CLI
  DEFAULT_INVENTORY = "inventory.yml"

  # Options globales qui consomment l'argument suivant (forme « -i VALEUR »).
  # Les formes « --flag=valeur » sont auto-suffisantes.
  GLOBAL_FLAGS_WITH_VALUE = {"-i", "--inventory"}

  def self.run(argv : Array(String) = ARGV) : Int32
    # Charge `.env` du cwd en priorité basse (les variables déjà exportées
    # dans le shell l'emportent). Évite à l'utilisateur le rituel
    # `set -a && source .env && set +a` avant chaque commande.
    LoadEnv.load

    inventory_path = DEFAULT_INVENTORY

    # Sépare les options globales (avant la sous-commande) du reste.
    # On arrête à la première chaîne qui ne ressemble pas à une option,
    # en sautant la valeur des flags connus pour en consommer une.
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
      p.on("-i PATH", "--inventory=PATH", "Fichier d'inventaire (défaut : #{DEFAULT_INVENTORY})") { |v| inventory_path = v }
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
    when nil           then show_usage(global_parser); 1
    when "list-hosts"  then cmd_list_hosts(inventory_path)
    when "show"        then cmd_show(inventory_path, sub_args)
    when "bootstrap"   then cmd_bootstrap(inventory_path, sub_args)
    when "rescue"      then Beryl::CLI::Rescue.run(inventory_path, sub_args)
    when "boot-hd"     then Beryl::CLI::BootHd.run(inventory_path, sub_args)
    when "wipe"        then Beryl::CLI::Wipe.run(inventory_path, sub_args)
    when "prep-rescue" then Beryl::CLI::PrepRescue.run(sub_args)
    when "bake-seed"   then Beryl::CLI::BakeSeed.run(sub_args)
    when "version"     then puts "beryl #{Beryl::VERSION}"; 0
    else
      STDERR.puts "beryl : sous-commande inconnue : #{subcommand}"
      show_usage(global_parser)
      1
    end
  end

  private def self.usage_banner : String
    <<-BANNER
    beryl #{Beryl::VERSION} — gestion de configuration FreeBSD (agentless SSH)

    USAGE : beryl [options globales] <sous-commande> [arguments]

    Sous-commandes :
      list-hosts            Liste les hôtes de l'inventaire
      show <host>           Affiche les détails d'un hôte
      rescue <host>         Bascule un hôte en rescue via l'API
                            de l'hébergeur (OVH, Scaleway) puis
                            attend le retour SSH
      boot-hd <host>        Bascule un hôte OVH sur le boot disque
                            via l'API (inverse de rescue) puis
                            attend le retour SSH de l'OS installé
      wipe <host> --disk    Efface un disque sur un hôte en rescue
                            Linux (confirmation OUI/YES requise)
      bootstrap <host>      Installe FreeBSD 15 (voie QEMU-in-rescue, ADR-011)
      prep-rescue           Serveur HTTP local (clé SSH + script) pour
                            préparer un rescue Debian/Ubuntu sans
                            copier-coller
      bake-seed             Génère un seed.img cloud-init avec votre clé
                            SSH, à attacher à une VM Ubuntu Server live
      version               Affiche la version

    Options globales :
    BANNER
  end

  private def self.show_usage(parser : OptionParser) : Nil
    puts parser
  end

  # ---------- list-hosts ----------

  private def self.cmd_list_hosts(inventory_path : String) : Int32
    inv = Beryl::Inventory.load(inventory_path)
    if inv.size == 0
      puts "(inventaire vide)"
      return 0
    end

    max_name = inv.names.map(&.size).max
    max_prov = inv.hosts.values.map { |h| (h.provider || "-").size }.max

    inv.names.sort.each do |name|
      host = inv.find(name)
      provider = host.provider || "-"
      puts "#{name.ljust(max_name)}  #{provider.ljust(max_prov)}  #{host.recipes.join(", ")}"
    end
    0
  rescue ex : File::NotFoundError
    STDERR.puts "beryl : inventaire introuvable : #{inventory_path}"
    1
  end

  # ---------- show ----------

  private def self.cmd_show(inventory_path : String, args : Array(String)) : Int32
    name = args.first?
    unless name
      STDERR.puts "USAGE : beryl show <host>"
      return 1
    end

    inv = Beryl::Inventory.load(inventory_path)
    host = inv.find(name)
    puts "name:           #{host.name}"
    puts "provider:       #{host.provider || "-"}"
    puts "user:           #{host.user}"
    puts "port:           #{host.port}"
    puts "identity_file:  #{host.identity_file || "-"}"
    puts "recipes:        #{host.recipes.empty? ? "-" : host.recipes.join(", ")}"
    unless host.variables.empty?
      puts "variables:"
      host.variables.each do |k, v|
        puts "  #{k}: #{v}"
      end
    end
    0
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    1
  rescue ex : File::NotFoundError
    STDERR.puts "beryl : inventaire introuvable : #{inventory_path}"
    1
  end

  # ---------- bootstrap ----------

  # Priorité des sources de configuration (règle « no silent defaults ») :
  #
  # 1. Flag CLI (`--disk`, `--raid`, `--authorized-keys`, …)
  # 2. Bloc `freebsd:` de l'inventaire YAML
  # 3. Défauts codés en dur (zroot, 4 Go swap, Europe/Paris, stripe, admin)
  #
  # Un flag CLI absent n'est PAS un défaut silencieux : on retombe sur la
  # valeur YAML (quand elle existe) ou sur le défaut historique du MVP.
  # Les champs qui n'ont PAS de défaut (disques, clés SSH) lèvent une
  # erreur explicite si aucune source ne les fournit.
  private def self.cmd_bootstrap(inventory_path : String, args : Array(String)) : Int32
    cli_disks = [] of String
    iso_url_override : String? = nil
    authorized_keys_file : String? = nil
    hostname_override : String? = nil
    pool_name_override : String? = nil
    swap_gb_override : Int32? = nil
    timezone_override : String? = nil
    freebsd_version = "15.0"
    installed_user_override : String? = nil
    raid_override : String? = nil

    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl bootstrap <host> [--disk PATH ...] [--authorized-keys FILE] [options]\n" \
                 "         Les valeurs absentes sont lues depuis le bloc `freebsd:` de l'inventaire."
      p.on("--disk=PATH", "Disque cible (répétable pour RAID multi-disques). Override du YAML.") { |v| cli_disks << v }
      p.on("--raid=MODE", "Mode ZFS pool : stripe (RAID0, défaut), mirror, raidz, raidz2, raidz3") { |v| raid_override = v }
      p.on("--iso-url=URL", "URL mfsBSD (override)") { |v| iso_url_override = v }
      p.on("--freebsd-version=VER", "Version FreeBSD à installer (défaut : 15.0)") { |v| freebsd_version = v }
      p.on("--authorized-keys=FILE", "Fichier local des clés SSH publiques à injecter (prime sur YAML `ssh_keys`)") { |v| authorized_keys_file = File.expand_path(v, home: true) }
      p.on("--hostname=NAME", "Hostname à configurer (défaut : nom dans l'inventaire)") { |v| hostname_override = v }
      p.on("--pool=NAME", "Nom du pool ZFS (défaut : zroot)") { |v| pool_name_override = v }
      p.on("--swap=GB", "Taille du swap en Go (défaut : 4)") { |v| swap_gb_override = v.to_i }
      p.on("--timezone=TZ", "Fuseau horaire (défaut : Europe/Paris)") { |v| timezone_override = v }
      p.on("--installed-user=USER", "User pour le SSH post-install (défaut : admin)") { |v| installed_user_override = v }
      p.on("-h", "--help", "Aide") do
        puts p
        exit(0)
      end
      p.unknown_args do |rest, _|
        positional = rest
      end
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl bootstrap <host> [--disk PATH] [--authorized-keys FILE]"
      return 1
    end

    inv = Beryl::Inventory.load(inventory_path)
    host = inv.find(host_name)
    fcfg = host.freebsd_config

    # Disques : CLI > YAML > erreur explicite (pas de défaut silencieux).
    target_disks = if !cli_disks.empty?
                     cli_disks
                   elsif fcfg && !fcfg.disks.empty?
                     fcfg.disks
                   else
                     [] of String
                   end
    if target_disks.empty?
      STDERR.puts "beryl : aucun disque cible (ni --disk ni freebsd.disks dans l'inventaire)."
      STDERR.puts "       Exemple CLI : --disk=/dev/sda"
      STDERR.puts "       Exemple YAML : freebsd:\\n    disks: [/dev/sda]"
      return 1
    end

    # Clés SSH : CLI prime sur YAML (règle no_silent_defaults). Si les
    # deux sont absentes → erreur explicite.
    users = build_users_or_nil(fcfg, authorized_keys_file, installed_user_override)
    unless users
      STDERR.puts "beryl : aucune clé SSH (ni --authorized-keys ni freebsd.users[].ssh_keys dans l'inventaire)."
      STDERR.puts "       Exemple CLI : --authorized-keys=~/.ssh/philippe.aloli.fr.pub"
      return 1
    end

    hostname = hostname_override || fcfg.try(&.hostname) || host.name
    pool_name = pool_name_override || fcfg.try(&.pool_name) || "zroot"
    swap_gb = swap_gb_override || fcfg.try(&.swap_gb) || 4
    timezone = timezone_override || fcfg.try(&.timezone) || "Europe/Paris"
    raid = raid_override || fcfg.try(&.raid) || "stripe"
    iu_override = installed_user_override
    installed_user = iu_override ? iu_override : users.first.name

    # Packages : YAML si présent, sinon défaut minimal [sudo] (pour que
    # `%wheel NOPASSWD` marche une fois admin connecté). Pareil sudoers.
    packages = fcfg.try(&.packages).try { |p| p.empty? ? ["sudo"] : p } || ["sudo"]
    sudoers_raw = fcfg.try(&.sudoers) || [] of String
    sudoers = sudoers_raw.empty? ? ["%wheel ALL=(ALL) NOPASSWD:ALL"] : sudoers_raw

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl] #{Beryl::I18n.t(:bootstrap_header, host: host_name, hostname: hostname, disk: target_disks.join(", "))}"
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl] #{Beryl::I18n.t(:bootstrap_path, version: freebsd_version)}"
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl] #{Beryl::I18n.t(:bootstrap_users_loaded, count: users.size, names: users.map(&.name).join(", "))}"

    Beryl.clean_known_hosts(host.name, host.port)

    rescue_conn = Beryl::SSH::Connection.new(
      host: host.name,
      user: host.user,
      port: host.port,
      identity_file: host.identity_file,
      options: {
        "StrictHostKeyChecking" => "no",
        "UserKnownHostsFile"    => "/dev/null",
        "LogLevel"              => "ERROR",
      },
    )

    ovh_client_for_bootstrap = nil
    ovh_service = host.ovh_service_name
    if host.provider == "ovh" && ovh_service
      ovh_client_for_bootstrap = Beryl::CLI::Credentials.ovh_client
    end

    bootstrap = Beryl::Bootstrap::QemuInRescue.new(
      rescue_conn: rescue_conn,
      disks: target_disks,
      raid: raid,
      hostname: hostname,
      users: users,
      packages: packages,
      sudoers: sudoers,
      freebsd_version: freebsd_version,
      timezone: timezone,
      iso_url: iso_url_override,
      pool_name: pool_name,
      swap_gb: swap_gb,
      installed_user: installed_user,
      installed_port: host.port,
      ovh_client: ovh_client_for_bootstrap,
      ovh_service_name: ovh_service,
    )
    bootstrap.run

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl] #{Beryl::I18n.t(:bootstrap_done, host: host_name)}"
    0
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    1
  rescue ex : Beryl::SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    2
  rescue ex : Beryl::Bootstrap::QemuInRescue::TargetDiskNotEmpty
    # Garde-fou NOGO : le disque porte déjà une install BSD. Message
    # explicite pour l'opérateur, exit code dédié.
    STDERR.puts "beryl : #{ex.message}"
    10
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    3
  end

  # Construit la liste des users FreeBSD à créer, en appliquant la
  # priorité : CLI `--authorized-keys` > YAML `freebsd.users`. Retourne
  # `nil` quand aucune source ne fournit de clé SSH, pour que l'appelant
  # lève une erreur explicite au lieu d'un défaut silencieux.
  #
  # Règle Aloli `feedback_no_silent_defaults` :
  # - Si `--authorized-keys` est fourni, il prime sur ssh_keys YAML et est
  #   appliqué à TOUS les users du YAML (ou à un admin minimal si YAML
  #   vide). Le risque « clé GMAIL oubliée qui plante en silence » est
  #   supprimé : l'opérateur voit les clés qu'il injecte.
  # - Si pas de `--authorized-keys` et YAML présent, on utilise les
  #   ssh_keys déclarées dans chaque user YAML (l'appel
  #   `UserSpec#validate!` côté Bootstrap lèvera si un user n'en a pas).
  # - Si ni l'un ni l'autre → `nil`.
  private def self.build_users_or_nil(
    fcfg : Beryl::FreebsdConfig?,
    authorized_keys_file : String?,
    installed_user_override : String?,
  ) : Array(Beryl::Bootstrap::UserSpec)?
    cli_keys = load_ssh_keys_or_nil(authorized_keys_file)

    # Aucune source → nil, l'appelant fait un message d'erreur propre.
    yaml_users = fcfg.try(&.users) || [] of Beryl::UserSpecYaml
    if yaml_users.empty? && cli_keys.nil?
      return nil
    end

    # Pas de YAML mais CLI présent → on synthétise un admin minimal.
    if yaml_users.empty?
      name = installed_user_override || "admin"
      return [
        Beryl::Bootstrap::UserSpec.new(
          name: name,
          primary_group: "www",
          secondary_groups: ["wheel"],
          shell: "/bin/csh",
          ssh_keys: cli_keys.not_nil!,
        ),
      ]
    end

    # YAML présent : on convertit chaque UserSpecYaml en UserSpec, en
    # appliquant les clés CLI si fournies (override explicite).
    yaml_users.map do |u|
      keys = cli_keys || u.ssh_keys
      Beryl::Bootstrap::UserSpec.new(
        name: u.name,
        primary_group: u.primary_group || "www",
        secondary_groups: u.secondary_groups.empty? ? ["wheel"] : u.secondary_groups,
        shell: u.shell || "/bin/csh",
        ssh_keys: keys,
      )
    end
  end

  # Charge les clés SSH depuis un fichier (une par ligne, lignes vides et
  # commentaires ignorés). Retourne `nil` si aucun fichier fourni, lève
  # si le fichier est introuvable ou vide (pas de défaut silencieux).
  private def self.load_ssh_keys_or_nil(path : String?) : Array(String)?
    return nil unless path
    unless File.exists?(path)
      raise "fichier de clés SSH introuvable : #{path}"
    end
    keys = File.read_lines(path).map(&.strip).reject { |l| l.empty? || l.starts_with?('#') }
    raise "aucune clé SSH trouvée dans #{path}" if keys.empty?
    keys
  end
end

exit Beryl::CLI.run
