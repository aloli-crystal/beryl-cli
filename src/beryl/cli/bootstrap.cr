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
    # freebsd_version : si nil après parse, on appelle
    # `MfsBSDRelease.latest` pour détecter la dernière disponible sur
    # GitHub (aucun défaut en dur — règle « pas de version figée »).
    freebsd_version_flag : String? = nil
    dry_run = false
    force = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl bootstrap <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: dedibox, ovh, scaleway)") { |v| provider_override = v }
      p.on("-n", "--dry-run", "Affiche le plan d'install sans lancer QEMU/bsdinstall") { dry_run = true }
      p.on("-f", "--force", "Bypass le précheck (disques déclarés != physiques)") { force = true }
      p.on("-i URL", "--iso-url=URL", "URL mfsBSD (override)") { |v| iso_url_override = v }
      p.on("-v VER", "--freebsd-version=VER", "Version FreeBSD à installer (défaut : dernière mfsBSD SE détectée sur GitHub)") { |v| freebsd_version_flag = v }
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

    # Résolution de la version FreeBSD + URL mfsBSD. Règle « pas de
    # version en dur » : par défaut on interroge les releases GitHub
    # mfsBSD pour prendre la dernière disponible. Le flag
    # `--freebsd-version=X.Y` force une version précise (utilise
    # l'URL `/releases/latest/download/` qui pointe toujours vers la
    # dernière release tagguée contenant cette version).
    freebsd_version : String
    mfsbsd_version : String
    abi : String
    resolved_iso_url = iso_url_override
    if forced = freebsd_version_flag
      freebsd_version = forced
      mfsbsd_version = forced
      abi = "FreeBSD:#{forced.split('.').first}:amd64"
    else
      begin
        info = Beryl::Bootstrap::MfsBSDRelease.latest
        freebsd_version = info.version
        mfsbsd_version = info.version
        abi = info.abi
        resolved_iso_url ||= info.image_url
        STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] 7.0 mfsBSD SE détectée : #{info.version} (#{info.image_url})"
      rescue ex : Beryl::Bootstrap::MfsBSDRelease::DetectionFailed
        STDERR.puts "beryl : impossible de détecter la dernière version mfsBSD SE — #{ex.message}"
        STDERR.puts "        Passez --freebsd-version=X.Y pour forcer une version."
        return EXIT_USAGE
      end
    end

    # Bootstrap est FreeBSD-only dans ce build. L'architecture prévoit
    # les autres OS (ADR-014) mais seul le chemin mfsBSD-in-QEMU +
    # bsdinstall est implémenté aujourd'hui.
    unless host.os == "freebsd"
      STDERR.puts "beryl : bootstrap n'est implémenté que pour os: freebsd (host : #{host.os})."
      STDERR.puts "        Les OS Debian/Ubuntu/Alpine sont sur la roadmap (ADR-014)."
      return EXIT_USAGE
    end

    # Construction de la connexion SSH rescue (utilisée par le précheck
    # ET le bootstrap). Le rescue est TOUJOURS joignable en root après
    # `beryl rescue` (OVH nativement ; Dedibox promu root ; cf. rescue.cr
    # qui attend root). On force donc `root` ici, INDÉPENDAMMENT de
    # `host.user` : ce dernier désigne l'utilisateur du serveur INSTALLÉ
    # (ex. `admin`, pour `beryl apply` une fois root SSH coupé), pas le
    # rescue Linux. Sans ça, `user: admin` cassait le précheck
    # (admin@rescue → uname -s vide, le rescue n'ayant que root).
    rescue_conn = SSH::Connection.new(
      host: host.ssh_host,
      user: "root",
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
        STDERR.puts "[beryl bootstrap] 7 --force : précheck ignoré. PROCÉDEZ AVEC PRUDENCE."
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

    # Taille de bloc PHYSIQUE de chaque disque, détectée côté rescue Linux
    # (qui voit le vrai matériel ; la VM QEMU ne voit que du 512 via virtio).
    # On en déduit l'ashift NATIF par pool (log2) → zpool create -o ashift=N
    # de SES disques (HDD 4K → 12, NVMe 512 → 9), jamais une valeur en dur.
    # Cf. warning ZFS « non-native block size » constaté sur qrbx.
    all_pool_disks = disks + host.data_zpools.flat_map(&.disks)
    ashift_by_disk = detect_ashifts(rescue_conn, all_pool_disks)
    boot_ashift = disks.map { |d| ashift_by_disk[d]? || 12 }.max
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] 7 ashift natif (blockdev) : " +
                ashift_by_disk.map { |d, a| "#{d}→#{a}" }.join(", ")

    # Pools data : créés post-install via `zpool create` dans la VM
    # mfsBSD qui tourne encore. Chaque pool data se voit attribué un
    # segment contigu de vtbd* QEMU après les disques du pool boot.
    #
    # Si un pool data déclare `encryption: true`, on génère une clé
    # 256 bits localement (côté opérateur, dans `~/.config/beryl/<société>/
    # <domaine>/<host>.key`) AVANT de lancer le bootstrap. Si une clé
    # existe déjà à ce chemin, on la réutilise (cas d'un re-bootstrap
    # explicite après wipe — mais ATTENTION, les datasets de l'ancien
    # pool deviennent illisibles si la clé a été régénérée entre-temps).
    data_pools = host.data_zpools.map do |pool|
      mp = pool.mountpoint
      if mp.nil? || mp.empty?
        STDERR.puts "beryl : pool data `#{pool.name}` sans mountpoint (ajoutez `mountpoint: /xxx`)."
        return EXIT_USAGE
      end
      key_hex : String? = nil
      if (enc = pool.encryption)
        # Au bootstrap, on génère TOUJOURS une clé locale, même si le
        # mode final est `tang`. Raison : le `zpool create -O encryption=on`
        # se fait depuis la VM mfsBSD-in-QEMU pendant le bootstrap, où
        # Tang peut ne pas être joignable (ou pas encore configuré).
        # On crée donc le pool en mode `ssh_unlock` au bootstrap, et
        # l'opérateur basculera vers `tang` plus tard via `beryl
        # tang-enroll <host>` (T2, à venir) qui appelle
        # `crystal-clevis-zfs bind --use-existing-key` côté serveur.
        key_path = Beryl::Encryption.key_path(
          config_root, host.account_name, host.domain_name, host.short_name
        )
        if Beryl::Encryption.exists?(key_path)
          key_hex = Beryl::Encryption.read(key_path)
          STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] " \
                      "7 clé existante réutilisée : #{key_path}"
        else
          key_hex = Beryl::Encryption.write_new(key_path)
          STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] " \
                      "7 clé générée et stockée : #{key_path} (chmod 0400, 256 bits hex)"
          STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] " \
                      "7 ⚠ pensez à sauvegarder ce fichier (Time Machine + iCloud) — " \
                      "perdre la clé = perdre les données du pool #{pool.name}"
        end
        if enc.tang?
          STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] " \
                      "7 mode tang demandé pour #{pool.name} : pool créé en ssh_unlock pour le bootstrap. " \
                      "Lancez `beryl tang-enroll #{host.account_name}/#{host.fqdn}` " \
                      "après le 1er reboot pour basculer vers Tang."
        end
      end
      Beryl::Bootstrap::DataPoolSpec.new(
        name: pool.name,
        raid: pool.raid,
        disks: pool.disks,
        mountpoint: mp,
        encryption_key_hex: key_hex,
        ashift: pool.disks.map { |d| ashift_by_disk[d]? || 12 }.max,
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
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] 7 cible : #{Beryl.format_ssh_target(host)} disques : #{all_disks.join(", ")}"
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] 7 FreeBSD #{freebsd_version} — users : #{users.map(&.name).join(", ")} — pools data : #{data_pools.size}"

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
          # Note : le tag est posé selon DataPoolSpec#encrypted? qui
          # ne connaît que la présence d'une clé hex au bootstrap.
          # Le mode final (ssh_unlock vs tang) vit côté Pool, déjà
          # affiché par les logs précédents.
          enc_tag = dp.encrypted? ? " [chiffré]" : ""
          STDERR.puts "    - #{dp.name} (RAID #{dp.raid}/#{mode})#{enc_tag} → #{dp.mountpoint} sur #{dp.disks.join(", ")}"
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
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("bootstrap", args, replace_host: {raw, "#{host.account_name}/#{host.fqdn}"})}"
      return EXIT_OK
    end

    # Résolution du provider : --provider CLI gagne, sinon celui du merge.
    effective_provider = provider_override || host.provider

    # GARDE-FOU boot-sur-disque : pour rebasculer le serveur sur le disque
    # APRÈS l'install, beryl appelle l'API hébergeur (boot_from_disk OVH,
    # reboot_to_disk Dedibox, reboot Normal Scaleway). Sans l'identifiant
    # nécessaire, `reboot_bare_metal` retombe sur `reboot -f` côté rescue →
    # le netboot reste sur RESCUE → le serveur REVIENT EN RESCUE au lieu du
    # FreeBSD installé, et le polling 7.6 tourne dans le vide. On ÉCHOUE TÔT.
    id_field = case effective_provider
               when "ovh"      then host.ovh_service_name ? nil : "ovh.service_name"
               when "dedibox"  then host.dedibox_server_id ? nil : "dedibox.server_id"
               when "scaleway" then host.scaleway_server_id ? nil : "scaleway.server_id"
               else                 nil
               end
    if missing = id_field
      STDERR.puts "beryl : provider=#{effective_provider} mais `#{missing}` absent du host.yml de #{host.fqdn}."
      STDERR.puts "  → beryl ne pourrait PAS rebasculer le boot sur le disque après l'install :"
      STDERR.puts "    le serveur reviendrait dans le RESCUE (le polling SSH tournerait à vide)."
      STDERR.puts "  Ajoutez l'identifiant au host.yml, ex. :"
      STDERR.puts "      #{effective_provider}:"
      STDERR.puts "        #{missing.split('.').last}: <id hébergeur>"
      STDERR.puts "  (ou re-scannez par l'identifiant hébergeur plutôt que par le FQDN)."
      return EXIT_USAGE
    end

    ovh_client = nil
    if effective_provider == "ovh" && host.ovh_service_name
      ovh_client = Beryl::CLI::Credentials.ovh_client
    end
    dedibox_client = nil
    dedibox_sid : Int32? = nil
    if effective_provider == "dedibox" && (sid_str = host.dedibox_server_id)
      if sid_int = sid_str.to_i?
        dedibox_client = Beryl::CLI::Credentials.dedibox_client
        dedibox_sid = sid_int
      end
    end
    # Scaleway : nécessaire pour `reboot_bare_metal` post-bootstrap.
    # Sans le client + server_id + zone, le reboot tombe dans le
    # fallback `reboot -f` côté rescue Linux qui ne change pas le
    # boot_type API → le serveur revient en rescue Ubuntu au lieu
    # de booter sur le FreeBSD installé. Constaté terrain chouquette
    # 25 avril 2026.
    scaleway_client = nil
    scaleway_sid : String? = nil
    scaleway_zone : String? = nil
    if effective_provider == "scaleway" && (sid_str = host.scaleway_server_id)
      scaleway_client = Beryl::CLI::Credentials.scaleway_client
      scaleway_sid = sid_str
      scaleway_zone = host.scaleway_zone
    end

    bootstrap = Beryl::Bootstrap::QemuInRescue.new(
      rescue_conn: rescue_conn,
      disks: disks,
      raid: raid,
      hostname: hostname,
      fqdn: host.fqdn,
      users: users,
      packages: packages,
      sudoers: sudoers,
      freebsd_version: freebsd_version,
      mfsbsd_version: mfsbsd_version,
      abi: abi,
      timezone: timezone,
      iso_url: resolved_iso_url,
      pool_name: pool_name,
      swap_gb: swap_gb,
      installed_user: installed_user,
      installed_port: host.port,
      ovh_client: ovh_client,
      ovh_service_name: host.ovh_service_name,
      dedibox_client: dedibox_client,
      dedibox_server_id: dedibox_sid,
      scaleway_client: scaleway_client,
      scaleway_server_id: scaleway_sid,
      scaleway_zone: scaleway_zone,
      install_type: install_type,
      data_pools: data_pools,
      boot_ashift: boot_ashift,
      follow_hint_host_name: "#{host.account_name}/#{host.fqdn}",
    )
    bootstrap.run

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl bootstrap] 7 terminé pour #{host.fqdn}"
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
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex : Beryl::Bootstrap::QemuInRescue::TargetDiskNotEmpty
    STDERR.puts "beryl : #{ex.message}"
    EXIT_NOGO
  rescue ex : Beryl::Bootstrap::QemuInRescue::PkgbaseScopeUnsupported
    STDERR.puts "beryl : #{ex.message}"
    EXIT_PKGBASE_NYI
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
    Beryl::Config::Users.list(list).map do |e|
      f = e.fields
      # Paire de rotation `[a, b]` → on ne bootstrappe que l'active (1ère).
      ssh_keys = Beryl::Config.deployed_key_names(f[YAML::Any.new("ssh_keys")]?.try(&.as_a?) || [] of YAML::Any)
      Beryl::Bootstrap::UserSpec.new(
        name: e.name,
        primary_group: f[YAML::Any.new("primary_group")]?.try(&.as_s?) || "www",
        # `secondary_groups` (canonique) + alias `groups` (comme user-sync).
        secondary_groups: ((f[YAML::Any.new("secondary_groups")]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String) +
                           (f[YAML::Any.new("groups")]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String)).uniq,
        # `shell` À LA CRÉATION : seulement un /chemin de login. Une RECETTE
        # (ex. `oh-my-zsh`) n'EST PAS un shell de login → on garde le défaut ;
        # la recette posera le vrai shell (/usr/local/bin/zsh) au 1ᵉʳ `beryl apply`.
        shell: e.shell_path || "/bin/csh",
        ssh_keys: ssh_keys,
      )
    end
  end

  # Interroge le rescue (Linux) pour la taille de bloc PHYSIQUE de chaque
  # disque et la convertit en ashift ZFS (log2). Lecture seule. Repli sur
  # 12 (4 K, sûr) si `blockdev` échoue/manque sur un disque. La détection
  # DOIT se faire ici (rescue) et pas dans la VM : le virtio QEMU ne
  # propage pas la taille physique → la VM voit tout en 512.
  private def self.detect_ashifts(conn : SSH::Connection, disks : Array(String)) : Hash(String, Int32)
    result = {} of String => Int32
    return result if disks.empty?
    # Une ligne par disque (alignement garanti par le `|| echo 4096`).
    cmd = disks.map { |d| "blockdev --getpbsz #{Process.quote(d)} 2>/dev/null || echo 4096" }.join("\n")
    out = conn.exec(cmd, raise_on_error: false).stdout
    lines = out.each_line.map(&.strip).reject(&.empty?).to_a
    disks.each_with_index do |d, i|
      pbsz = lines[i]?.try(&.to_i?) || 4096
      result[d] = ashift_for(pbsz)
    end
    result
  end

  # ashift = log2(block_size). block_size est une puissance de 2 (512,
  # 4096, 8192…). 512→9, 4096→12, 8192→13.
  private def self.ashift_for(block_size : Int32) : Int32
    a = 9
    bs = block_size < 512 ? 512 : block_size
    while bs > 512
      bs //= 2
      a += 1
    end
    a
  end
end
