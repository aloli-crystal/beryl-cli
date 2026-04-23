require "option_parser"
require "../config"
require "../bootstrap"
require "./account_utils"
require "./credentials"
require "./precheck"

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
    account_hint : String? = nil
    domain_hint : String? = nil
    provider_override : String? = nil
    iso_url_override : String? = nil
    freebsd_version = "15.0"
    dry_run = false
    force = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl bootstrap <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: ovh, scaleway)") { |v| provider_override = v }
      p.on("-n", "--dry-run", "Affiche le plan d'install sans lancer QEMU/bsdinstall") { dry_run = true }
      p.on("-f", "--force", "Bypass le précheck (disques déclarés != physiques)") { force = true }
      p.on("-i URL", "--iso-url=URL", "URL mfsBSD (override)") { |v| iso_url_override = v }
      p.on("-v VER", "--freebsd-version=VER", "Version FreeBSD (défaut : 15.0)") { |v| freebsd_version = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl bootstrap <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    # Bootstrap est FreeBSD-only dans ce build. L'architecture prévoit
    # les autres OS (ADR-014) mais seul le chemin mfsBSD-in-QEMU +
    # bsdinstall est implémenté aujourd'hui.
    unless host.os == "freebsd"
      STDERR.puts "beryl : bootstrap n'est implémenté que pour os: freebsd (host : #{host.os})."
      STDERR.puts "        Les OS Debian/Ubuntu/Alpine sont sur la roadmap (ADR-014)."
      return EXIT_USAGE
    end

    # Construction de la connexion SSH rescue (utilisée par le
    # précheck ET le bootstrap).
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

    # Précheck : validation config ZFS + comparaison disques déclarés
    # vs disques physiques côté rescue.
    precheck = Beryl::CLI::Precheck.run(host, rescue_conn)
    Beryl::CLI::Precheck.report(host, precheck)
    unless precheck.ok
      if force
        STDERR.puts "[beryl bootstrap] --force : précheck ignoré. PROCÉDEZ AVEC PRUDENCE."
      else
        STDERR.puts
        STDERR.puts "beryl : précheck échoué. Corrigez la config ou utilisez --force."
        return EXIT_USAGE
      end
    end

    # Infos dérivées du pool boot (installé par bsdinstall).
    boot_pool = host.boot_zpool
    disks = boot_pool.disks
    raid_level = boot_pool.raid
    raid = boot_pool.zfs_mode
    if raid == "mirror_stripe"
      STDERR.puts "beryl : RAID 10 pas encore câblé côté bsdinstall (pool boot)."
      STDERR.puts "        Utilisez RAID 0, 1, 5, 6 ou 7 pour le pool boot."
      return EXIT_USAGE
    end
    pool_name = boot_pool.name

    # Pools data : créés post-install via `zpool create` dans la VM
    # mfsBSD qui tourne encore. Chaque pool data se voit attribué un
    # segment contigu de vtbd* QEMU après les disques du pool boot.
    data_pools = host.data_zpools.map do |pool|
      mp = pool.mountpoint
      if mp.nil? || mp.empty?
        STDERR.puts "beryl : pool data `#{pool.name}` sans mountpoint (ajoutez `mountpoint: /xxx`)."
        return EXIT_USAGE
      end
      Beryl::Bootstrap::DataPoolSpec.new(
        name: pool.name,
        raid: pool.raid,
        disks: pool.disks,
        mountpoint: mp,
      )
    end
    timezone = host.freebsd_string("timezone") || "Europe/Paris"
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

    all_disks = disks + data_pools.flat_map(&.disks)
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] cible : #{Beryl.format_ssh_target(host)} disques : #{all_disks.join(", ")}"
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] FreeBSD #{freebsd_version} — users : #{users.map(&.name).join(", ")} — pools data : #{data_pools.size}"

    if dry_run
      STDERR.puts
      STDERR.puts "DRY-RUN : plan d'install FreeBSD"
      STDERR.puts "─" * 60
      STDERR.puts "  hôte        : #{Beryl.format_ssh_target(host)}"
      STDERR.puts "  FreeBSD     : #{freebsd_version}"
      STDERR.puts "  timezone    : #{timezone}"
      STDERR.puts "  pool boot   : #{pool_name} en #{raid} (RAID #{raid_level}) sur #{disks.join(", ")}"
      if data_pools.empty?
        STDERR.puts "  pools data  : (aucun)"
      else
        STDERR.puts "  pools data  :"
        data_pools.each do |dp|
          mode = Beryl::Config::Zpool.zfs_mode(dp.raid)
          STDERR.puts "    - #{dp.name} (RAID #{dp.raid}/#{mode}) → #{dp.mountpoint} sur #{dp.disks.join(", ")}"
        end
      end
      STDERR.puts "  swap        : #{swap_gb} Go"
      STDERR.puts "  install     : #{install_type}"
      STDERR.puts "  users       :"
      users.each do |u|
        STDERR.puts "    - #{u.name} (#{u.primary_group}#{u.secondary_groups.empty? ? "" : " + " + u.secondary_groups.join(",")}) " \
                    "#{u.shell}, #{u.ssh_keys.size} clé(s) SSH"
      end
      STDERR.puts "  packages    : #{packages.join(", ")}"
      STDERR.puts "  sudoers     :"
      sudoers.each { |s| STDERR.puts "    - #{s}" }
      STDERR.puts "─" * 60
      STDERR.puts "DRY-RUN : aucune action exécutée."
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("bootstrap", args)}"
      return EXIT_OK
    end

    Beryl.clean_known_hosts_for(host)

    # Résolution du provider : --provider CLI gagne, sinon celui du merge.
    effective_provider = provider_override || host.provider
    ovh_client = nil
    if effective_provider == "ovh" && host.ovh_service_name
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
      data_pools: data_pools,
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
