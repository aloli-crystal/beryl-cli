require "option_parser"
require "../beryl"
require "./cli/prep_rescue"

# Point d'entrée CLI de beryl.
#
# Syntaxe générale :
#   beryl [-i INVENTAIRE] <sous-commande> [arguments]
#
# Sous-commandes disponibles au MVP :
#   list-hosts             Affiche les hôtes de l'inventaire.
#   show <host>            Détaille un hôte.
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
    when "prep-rescue" then Beryl::CLI::PrepRescue.run(sub_args)
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
      bootstrap <host>      Installe FreeBSD 15 sur un rescue Linux distant
      prep-rescue           Serveur HTTP local (clé SSH + script) pour
                            préparer un rescue Debian/Ubuntu sans
                            copier-coller
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

  private def self.cmd_bootstrap(inventory_path : String, args : Array(String)) : Int32
    target_disk = nil
    image_url_override : String? = nil
    authorized_keys_file = File.expand_path("~/.ssh/authorized_keys", home: true)
    hostname_override = nil
    pool_name = "zroot"
    swap_gb = 4
    timezone = "Europe/Paris"

    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl bootstrap <host> --disk PATH [options]"
      p.on("--disk=PATH", "Disque cible sur l'hôte (REQUIS, ex. /dev/sda, /dev/nvme0n1)") { |v| target_disk = v }
      p.on("--image=URL", "URL de l'image mfsBSD (priorité : --image > inventaire > défaut)") { |v| image_url_override = v }
      p.on("--authorized-keys=FILE", "Fichier local contenant les clés SSH (défaut : ~/.ssh/authorized_keys)") { |v| authorized_keys_file = v }
      p.on("--hostname=NAME", "Hostname à configurer (défaut : nom dans l'inventaire)") { |v| hostname_override = v }
      p.on("--pool=NAME", "Nom du pool ZFS (défaut : zroot)") { |v| pool_name = v }
      p.on("--swap=GB", "Taille du swap en Go (défaut : 4)") { |v| swap_gb = v.to_i }
      p.on("--timezone=TZ", "Fuseau horaire (défaut : Europe/Paris)") { |v| timezone = v }
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
      STDERR.puts "beryl : hôte non précisé. beryl bootstrap <host> --disk PATH"
      return 1
    end
    disk = target_disk
    unless disk
      STDERR.puts "beryl : --disk est requis (ex. --disk=/dev/sda)"
      return 1
    end

    unless File.exists?(authorized_keys_file)
      STDERR.puts "beryl : fichier de clés SSH introuvable : #{authorized_keys_file}"
      return 1
    end
    keys = File.read_lines(authorized_keys_file).map(&.strip).reject(&.empty?)
    if keys.empty?
      STDERR.puts "beryl : aucune clé SSH trouvée dans #{authorized_keys_file}"
      return 1
    end

    inv = Beryl::Inventory.load(inventory_path)
    host = inv.find(host_name)

    override_snapshot = hostname_override
    hostname = override_snapshot.nil? ? host.name : override_snapshot

    # Priorité de l'URL de l'image mfsBSD :
    #   1. --image passé au CLI
    #   2. defaults.bootstrap.mfsbsd_image_url dans inventory.yml
    #   3. constante de dernier recours MfsBSD::DEFAULT_IMAGE_URL (dépannage hors connexion).
    image_url = image_url_override ||
                inv.bootstrap_defaults.mfsbsd_image_url ||
                Beryl::Bootstrap::MfsBSD::DEFAULT_IMAGE_URL

    STDERR.puts "[beryl] bootstrap de #{host_name} (hostname cible : #{hostname}, disque : #{disk})"
    STDERR.puts "[beryl] #{keys.size} clé(s) SSH chargée(s) depuis #{authorized_keys_file}"
    STDERR.puts "[beryl] image mfsBSD : #{image_url}"

    # Connexion SSH au rescue : la clé d'hôte n'est probablement pas encore
    # connue (machine fraîche ou reprovisionnée) et va de toute façon changer
    # après la bascule mfsBSD. On accepte la première clé puis on la retient
    # (accept-new protège contre le MITM après la première connexion).
    rescue_conn = Beryl::SSH::Connection.new(
      host: host.name,
      user: host.user,
      port: host.port,
      identity_file: host.identity_file,
      options: {"StrictHostKeyChecking" => "accept-new"},
    )

    mfsbsd = Beryl::Bootstrap::MfsBSD.new(
      rescue_conn: rescue_conn,
      target_disk: disk,
      image_url: image_url,
    )
    mfsbsd_conn = mfsbsd.run

    installer = Beryl::Bootstrap::Installer.new(
      mfsbsd_conn: mfsbsd_conn,
      target_disk: disk,
      hostname: hostname,
      authorized_keys: keys,
      pool_name: pool_name,
      swap_gb: swap_gb,
      timezone: timezone,
    )
    installer.run

    STDERR.puts "[beryl] bootstrap terminé pour #{host_name}"
    0
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    1
  rescue ex : Beryl::SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    2
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    3
  end
end

exit Beryl::CLI.run
