require "option_parser"
require "../config"
require "../bootstrap"
require "./credentials"

# Sous-commande `beryl bootstrap <host>` : installe FreeBSD 15 sur un
# hôte actuellement en rescue Linux (voie mfsBSD-in-QEMU, ADR-012/013).
#
# Toute la config vient de l'inventaire mergé (`_default.yml` +
# `<domaine>.yml` + éventuel `<groupe>.yml` + `<host>.yml`). Les seuls
# flags CLI sont des overrides ponctuels.
module Beryl::CLI::Bootstrap
  EXIT_OK          =  0
  EXIT_USAGE       =  1
  EXIT_SSH_FAILED  =  2
  EXIT_UNEXPECTED  =  3
  EXIT_NOGO        = 10
  EXIT_PKGBASE_NYI = 11

  def self.run(config_root : String, args : Array(String)) : Int32
    domain_hint : String? = nil
    iso_url_override : String? = nil
    freebsd_version = "15.0"
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl bootstrap <host> [options]"
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-i URL", "--iso-url=URL", "URL mfsBSD (override)") { |v| iso_url_override = v }
      p.on("-v VER", "--freebsd-version=VER", "Version FreeBSD (défaut : 15.0)") { |v| freebsd_version = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl bootstrap <host>"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, domain_hint: domain_hint)
    root.env_file.apply_to_env(host.domain_name)

    # Lecture des valeurs depuis la config mergée
    disks = host.freebsd_string_array("disks")
    if disks.empty?
      STDERR.puts "beryl : aucun disque dans freebsd.disks pour #{host.fqdn}"
      STDERR.puts "        (déclarez `freebsd.disks: [/dev/sda]` dans le fichier host)"
      return EXIT_USAGE
    end

    raid = host.freebsd_string("raid") || "stripe"
    timezone = host.freebsd_string("timezone") || "Europe/Paris"
    pool_name = host.freebsd_string("pool_name") || "zroot"
    swap_gb = host.freebsd_int("swap_gb") || 4
    install_type = host.freebsd_string("install_type") || "distribution_sets"
    hostname = host.freebsd_string("hostname") || host.short_name
    packages = host.freebsd_string_array("packages")
    sudoers = host.freebsd_string_array("sudoers")
    sudoers = ["%wheel ALL=(ALL) NOPASSWD:ALL"] if sudoers.empty?

    users = extract_users(host)
    if users.empty?
      STDERR.puts "beryl : aucun user dans freebsd.users pour #{host.fqdn}"
      STDERR.puts "        (déclarez au moins un user dans _default.yml ou le domaine)"
      return EXIT_USAGE
    end
    installed_user = users.first.name

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] cible : #{Beryl.format_ssh_target(host)} disques : #{disks.join(", ")}"
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] FreeBSD #{freebsd_version} — users : #{users.map(&.name).join(", ")}"

    Beryl.clean_known_hosts_for(host)

    rescue_conn = Beryl::SSH::Connection.new(
      host: host.ssh_host,
      user: host.user,
      port: host.port,
      identity_file: host.identity_file,
      options: {
        "StrictHostKeyChecking" => "no",
        "UserKnownHostsFile"    => "/dev/null",
        "LogLevel"              => "ERROR",
      },
    )

    ovh_client = nil
    if host.provider == "ovh" && host.ovh_service_name
      ovh_client = Beryl::CLI::Credentials.ovh_client
    end

    bootstrap = Beryl::Bootstrap::QemuInRescue.new(
      rescue_conn: rescue_conn,
      disks: disks,
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
      ovh_client: ovh_client,
      ovh_service_name: host.ovh_service_name,
      install_type: install_type,
    )
    bootstrap.run

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] terminé pour #{host.fqdn}"
    EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex : Beryl::Bootstrap::QemuInRescue::TargetDiskNotEmpty
    STDERR.puts "beryl : #{ex.message}"
    EXIT_NOGO
  rescue ex : Beryl::Bootstrap::QemuInRescue::PkgbaseNotYetImplemented
    STDERR.puts "beryl : #{ex.message}"
    EXIT_PKGBASE_NYI
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Convertit les users du merge YAML en `Beryl::Bootstrap::UserSpec`
  # consommés par QemuInRescue. La clé domaine est déjà injectée par
  # le Merger, donc `user.ssh_keys` contient la liste finale.
  private def self.extract_users(host : Beryl::Config::ResolvedHost) : Array(Beryl::Bootstrap::UserSpec)
    users_any = host.freebsd_hash[YAML::Any.new("users")]?
    return [] of Beryl::Bootstrap::UserSpec unless users_any
    list = users_any.as_a? || [] of YAML::Any
    list.compact_map do |u|
      h = u.as_h?
      next nil unless h
      name = h[YAML::Any.new("name")]?.try(&.as_s?)
      next nil unless name
      ssh_keys = h[YAML::Any.new("ssh_keys")]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      Beryl::Bootstrap::UserSpec.new(
        name: name,
        primary_group: h[YAML::Any.new("primary_group")]?.try(&.as_s?) || "www",
        secondary_groups: (h[YAML::Any.new("secondary_groups")]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String),
        shell: h[YAML::Any.new("shell")]?.try(&.as_s?) || "/bin/csh",
        ssh_keys: ssh_keys,
      )
    end
  end
end
