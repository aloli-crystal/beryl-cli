require "base64"
require "uri"
require "ovh-api/ovh_api"
require "ssh"
require "../config/zpool"

module Beryl::Bootstrap
  # Spécification d'un utilisateur à créer sur le FreeBSD installé.
  # Les valeurs sont explicites : aucun défaut ne s'applique silencieusement
  # (règle Aloli « no silent defaults »).
  record UserSpec,
    name : String,
    primary_group : String,
    secondary_groups : Array(String),
    shell : String,
    ssh_keys : Array(String) do
    def to_tsv : String
      # Format attendu par rescue-run-vm.sh : name|g|G,G,G|shell|key1,key2
      [
        name,
        primary_group,
        secondary_groups.join(","),
        shell,
        ssh_keys.join(","),
      ].join("|")
    end

    def validate! : Nil
      raise ArgumentError.new("user name vide") if name.empty?
      raise ArgumentError.new("#{name} : primary_group vide") if primary_group.empty?
      raise ArgumentError.new("#{name} : shell vide") if shell.empty?
      raise ArgumentError.new("#{name} : ssh_keys vide (Aloli interdit les défauts silencieux)") if ssh_keys.empty?
    end
  end

  # Spécification d'un pool ZFS data à créer après bsdinstall (hors
  # chroot, depuis mfsBSD qui a déjà remonté zroot sur /mnt).
  #
  # `disks` contient les chemins host (`/dev/sda`, `/dev/sdb`…) tels
  # que déclarés par l'utilisateur dans `freebsd.zfs.<nom>.disks`. Le
  # mapping vers les vtbd* QEMU est calculé par `QemuInRescue` à partir
  # de l'ordre global des disques (boot en premier, data ensuite).
  #
  # `raid` est la valeur numérique (0, 1, 5, 6, 7, 10) comme partout
  # ailleurs dans beryl. Contrairement au pool boot (où 10 n'est pas
  # câblé côté bsdinstall), tous les niveaux RAID sont supportés ici
  # via un `zpool create` natif.
  record DataPoolSpec,
    name : String,
    raid : Int32,
    disks : Array(String),
    mountpoint : String do
    def validate! : Nil
      raise ArgumentError.new("pool data : name vide") if name.empty?
      raise ArgumentError.new("pool data #{name} : disks vide") if disks.empty?
      raise ArgumentError.new("pool data #{name} : mountpoint vide") if mountpoint.empty?
      # Contraintes RAID (min disques, parité RAID 10…)
      Beryl::Config::Zpool.validate!(raid, disks.size)
    end

    # Rend le fragment `vdev` d'un `zpool create` à partir de la liste
    # de devices (ex: ["vtbd2", "vtbd3"]).
    #   0  → "vtbd2 vtbd3"              (stripe implicite)
    #   1  → "mirror vtbd2 vtbd3"
    #   5  → "raidz vtbd2 vtbd3 vtbd4"
    #   6  → "raidz2 vtbd2 vtbd3 vtbd4 vtbd5"
    #   7  → "raidz3 vtbd2 vtbd3 vtbd4 vtbd5 vtbd6"
    #   10 → "mirror vtbd2 vtbd3 mirror vtbd4 vtbd5" (paires)
    def vdev_spec(devices : Array(String)) : String
      raise ArgumentError.new("vdev_spec : #{devices.size} devices pour #{disks.size} disques") if devices.size != disks.size
      case raid
      when 0
        devices.join(" ")
      when 1
        "mirror #{devices.join(" ")}"
      when 5
        "raidz #{devices.join(" ")}"
      when 6
        "raidz2 #{devices.join(" ")}"
      when 7
        "raidz3 #{devices.join(" ")}"
      when 10
        # Paires consécutives en mirror.
        pairs = [] of String
        i = 0
        while i < devices.size
          pairs << "mirror #{devices[i]} #{devices[i + 1]}"
          i += 2
        end
        pairs.join(" ")
      else
        raise ArgumentError.new("raid #{raid} non supporté pour un pool data")
      end
    end
  end

  # Bootstrap complet FreeBSD via mfsBSD-in-QEMU + post-install no-chroot.
  #
  # Flux validé manuellement sur loulou le 21 avril 2026 :
  #
  # . SSH rescue Linux → apt install qemu-system-x86 ovmf sshpass curl
  # . Download mfsBSD SE (cache)
  # . NOGO si BSD déjà sur le disque cible
  # . Upload `rescue-run-vm.sh` via scp (évite Process.run stdin-pipe)
  # . Exécute le driver shell sur le rescue (UN seul ssh outer, zéro nested
  #   côté Crystal → zéro hang macOS). Le driver :
  # .. systemd-run QEMU UEFI (survit à la fermeture ssh)
  # .. attend SSH mfsBSD
  # .. pré-fetch txz + bsdinstall PRÉAMBULE SEUL (pas de post-install chroot)
  # .. remonte ZFS + post-install HORS chroot ciblant /mnt (contourne Capsicum)
  # .. unmount + poweroff
  # . OVH API `boot_from_disk` + wait SSH FreeBSD (admin user)
  #
  # Voir ADR-013 pour la justification détaillée du pattern no-chroot.
  class QemuInRescue
    # Template URL GitHub releases (source officielle actuelle mfsBSD).
    # L'endpoint `/releases/latest/download/<asset>` redirige toujours
    # vers la release la plus récente — pas besoin de tag à maintenir.
    DEFAULT_MFSBSD_URL_TEMPLATE =
      "https://github.com/mmatuska/mfsbsd/releases/latest/download/mfsbsd-se-__VERSION_MFS__-RELEASE-amd64.iso"

    WORK_DIR     = "/root/beryl-test"
    INSTALLERCFG = "#{WORK_DIR}/installerconfig"
    QEMU_SERIAL  = "#{WORK_DIR}/qemu-serial.log"

    OVMF_CODE_SOURCE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
    OVMF_VARS_SOURCE = "/usr/share/OVMF/OVMF_VARS_4M.fd"
    OVMF_VARS_PATH   = "#{WORK_DIR}/vars.fd"

    VM_INSTALLERCFG  = "/tmp/installerconfig"
    VM_BSDINSTALL_LG = "/tmp/bsdinstall.log"

    VM_SSH_HOST          = "127.0.0.1"
    VM_SSH_PORT          = 2223
    MFSBSD_ROOT_PASSWORD = "mfsroot"

    SSH_WAIT_TIMEOUT    = 30.minutes
    SSH_POLL_INTERVAL   = 15.seconds
    VM_BOOT_TIMEOUT     = 3.minutes
    REBOOT_GRACE_PERIOD = 30.seconds
    QEMU_MAX_RUNTIME    = 45.minutes

    TEMPLATE_INSTALLERCONFIG = {{ read_file("#{__DIR__}/templates/installerconfig.sh") }}
    TEMPLATE_RESCUE_RUN_VM   = {{ read_file("#{__DIR__}/templates/rescue-run-vm.sh") }}

    RESCUE_RUN_VM_PATH = "#{WORK_DIR}/rescue-run-vm.sh"
    # Matche tous les mfsBSD-SE quelle que soit leur version / extension
    # (.iso côté GitHub, .img côté ancien vx.sk).
    QEMU_PATTERN = "qemu-system-x86_64.*mfsbsd-se-"

    getter rescue_conn : SSH::Connection
    getter disks : Array(String)
    getter raid : String
    getter hostname : String
    getter freebsd_version : String
    getter mfsbsd_version : String
    getter timezone : String
    getter mfsbsd_url : String
    getter pool_name : String
    getter swap_gb : Int32
    getter abi : String
    getter qemu_ram_mb : Int32
    getter qemu_cpus : Int32
    getter installed_user : String
    getter installed_port : Int32
    getter ovh_client : OvhApi::Client?
    getter ovh_service_name : String?
    getter dedibox_client : DediboxApi::Client?
    getter dedibox_server_id : Int32?
    getter users : Array(UserSpec)
    getter packages : Array(String)
    getter sudoers : Array(String)
    getter install_type : String
    getter data_pools : Array(DataPoolSpec)
    # Nom à suggérer dans le hint `beryl follow-install <name>`
    # (typiquement FQDN ou `<société>/<host>`). nil → fallback « <host> ».
    getter follow_hint_host_name : String?

    def initialize(
      @rescue_conn : SSH::Connection,
      @disks : Array(String),
      @hostname : String,
      @users : Array(UserSpec),
      @freebsd_version : String,
      @mfsbsd_version : String,
      @abi : String,
      @raid : String = "stripe",
      @timezone : String = "Europe/Paris",
      iso_url : String? = nil,
      @pool_name : String = "zroot",
      @swap_gb : Int32 = 4,
      @qemu_ram_mb : Int32 = 4096,
      @qemu_cpus : Int32 = 4,
      @installed_user : String = "admin",
      @installed_port : Int32 = 22,
      @ovh_client : OvhApi::Client? = nil,
      @ovh_service_name : String? = nil,
      @dedibox_client : DediboxApi::Client? = nil,
      @dedibox_server_id : Int32? = nil,
      @packages : Array(String) = [] of String,
      @sudoers : Array(String) = [] of String,
      @install_type : String = "distribution_sets",
      @data_pools : Array(DataPoolSpec) = [] of DataPoolSpec,
      @follow_hint_host_name : String? = nil,
    )
      raise ArgumentError.new("disks ne peut pas être vide") if @disks.empty?
      raise ArgumentError.new("hostname requis") if @hostname.empty?
      raise ArgumentError.new("freebsd_version requis") if @freebsd_version.empty?
      raise ArgumentError.new("mfsbsd_version requis") if @mfsbsd_version.empty?
      raise ArgumentError.new("qemu_ram_mb doit être >= 1024") if @qemu_ram_mb < 1024
      raise ArgumentError.new("qemu_cpus doit être >= 1") if @qemu_cpus < 1
      raise ArgumentError.new("users ne peut pas être vide (sinon aucun accès SSH après bootstrap)") if @users.empty?
      raise ArgumentError.new("raid invalide : #{@raid} (attendu : stripe, mirror, raidz, raidz2, raidz3)") unless VALID_RAID.includes?(@raid)
      unless VALID_INSTALL_TYPES.includes?(@install_type)
        raise ArgumentError.new("install_type invalide : #{@install_type.inspect} (attendu : #{VALID_INSTALL_TYPES.join(", ")})")
      end

      @data_pools.each(&.validate!)
      # Pas de disque partagé entre pool boot et pools data (ni entre
      # pools data — validate! côté Config::ResolvedHost l'impose mais
      # on re-checke ici au cas où QemuInRescue serait appelé hors
      # bootstrap CLI).
      seen_disks = Set(String).new(@disks)
      @data_pools.each do |pool|
        pool.disks.each do |d|
          raise ArgumentError.new("disque #{d} déclaré plusieurs fois (boot + data)") if seen_disks.includes?(d)
          seen_disks << d
        end
      end
      # pkgbase n'est pas encore câblé côté runtime (driver shell). Le
      # champ est accepté dans le YAML et validé ici pour figer
      # l'interface, mais la route d'install est encore le tarball
      # classique (base.txz + kernel.txz). Voir ADR-013 § « Pkgbase en
      # opt-in » pour le chemin d'implémentation prévu.
      if @install_type == "packages"
        raise PkgbaseNotYetImplemented.new(
          "install_type: packages (pkgbase) n'est pas encore câblé côté runtime. " \
          "Pour l'instant, utilisez install_type: distribution_sets (défaut). " \
          "Voir docs/adr/ADR-013-no-chroot-post-install.adoc § Pkgbase opt-in " \
          "pour le plan d'implémentation."
        )
      end
      @users.each(&.validate!)

      @mfsbsd_url = iso_url || self.class.default_mfsbsd_url(@mfsbsd_version)
    end

    class PkgbaseNotYetImplemented < Exception
    end

    VALID_RAID          = %w[stripe mirror raidz raidz2 raidz3]
    VALID_INSTALL_TYPES = %w[distribution_sets packages]

    def self.default_mfsbsd_url(mfsbsd_version : String) : String
      DEFAULT_MFSBSD_URL_TEMPLATE.gsub("__VERSION_MFS__", mfsbsd_version)
    end

    # Alias rétrocompat — ancien paramètre iso_url.
    def iso_url : String
      @mfsbsd_url
    end

    # Chemin local (côté rescue) où l'image mfsBSD SE est téléchargée.
    # **Inclut la version** pour qu'un changement de version upstream
    # (ex: 14.2 → 15.0) force un nouveau téléchargement au lieu de
    # réutiliser un cache périmé d'une version précédente. L'extension
    # provient de l'URL (.iso GitHub, .img vx.sk).
    def mfsbsd_local_path : String
      ext = File.extname(URI.parse(@mfsbsd_url).path.to_s)
      ext = ".iso" if ext.empty?
      "#{WORK_DIR}/mfsbsd-se-#{@mfsbsd_version}#{ext}"
    end

    def target_disk : String
      @disks.first
    end

    def run : SSH::Connection
      log_step("1/6 — vérifie que le rescue tourne bien sous Linux") { verify_linux_rescue }
      log_step("1b — NOGO si BSD déjà en place sur #{all_qemu_disks.join(", ")}") { check_target_disks_no_bsd }
      log_step("2/6 — installe qemu-system-x86, ovmf, sshpass et curl côté rescue") { install_packages }
      log_step("3/6 — télécharge l'image mfsBSD SE #{@mfsbsd_version} si nécessaire") { download_mfsbsd_if_needed }
      log_step("4/6 — dépose installerconfig + driver shell sur le rescue") do
        prepare_ovmf_vars
        @rescue_conn.write_file(INSTALLERCFG, render_installerconfig, mode: "0644")
        upload_driver_script
      end
      # NB : `beryl follow-install <host>` reste disponible pour
      # suivre bsdinstall en direct depuis un autre terminal. On
      # ne l'affiche plus en encadré parce qu'en flow nominal
      # (~90 s), l'opérateur n'a pas le temps d'ouvrir un second
      # terminal. À garder pour debug nouveau provider ou flow
      # FreeBSD inhabituel.
      log_step("5/6 — QEMU + mfsBSD + bsdinstall + post-install no-chroot (typiquement 1-3 min)") do
        @rescue_conn.exec("bash #{Process.quote(RESCUE_RUN_VM_PATH)}")
      end
      result = log_step("6/6 — reboot bare metal, attente SSH du FreeBSD installé") do
        reboot_bare_metal
        wait_for_installed_ssh
      end
      result
    end

    # Rend l'installerconfig minimaliste (préambule seul, pas de chroot).
    # ZFSBOOT_DISKS : dans la VM QEMU, les disques passthrough sont
    # vtbd1, vtbd2, … (vtbd0 est l'image mfsBSD elle-même). Ordre =
    # ordre d'apparition dans le `-drive` côté QEMU.
    def render_installerconfig : String
      zfsboot_disks = (1..@disks.size).map { |i| "vtbd#{i}" }.join(" ")
      TEMPLATE_INSTALLERCONFIG
        .gsub("__HOSTNAME__", @hostname)
        .gsub("__ZFSBOOT_DISKS__", zfsboot_disks)
        .gsub("__ZFSBOOT_VDEV_TYPE__", @raid)
        .gsub("__POOL_NAME__", @pool_name)
        .gsub("__SWAP_GB__", @swap_gb.to_s)
    end

    # Rend le driver shell. Tous les placeholders de la template sont
    # substitués ici (noms mfsbsd, OVMF, QEMU args, users, packages, sudoers).
    def render_rescue_run_vm : String
      TEMPLATE_RESCUE_RUN_VM
        .gsub("__VM_HOST__", VM_SSH_HOST)
        .gsub("__VM_PORT__", VM_SSH_PORT.to_s)
        .gsub("__VM_PASSWORD__", MFSBSD_ROOT_PASSWORD)
        .gsub("__INSTALLERCFG_PATH__", INSTALLERCFG)
        .gsub("__VM_BOOT_SEC__", VM_BOOT_TIMEOUT.total_seconds.to_i.to_s)
        .gsub("__QEMU_MAX_SEC__", QEMU_MAX_RUNTIME.total_seconds.to_i.to_s)
        .gsub("__QEMU_PATTERN__", QEMU_PATTERN)
        .gsub("__QEMU_SERIAL__", QEMU_SERIAL)
        .gsub("__QEMU_CPUS__", @qemu_cpus.to_s)
        .gsub("__QEMU_RAM_MB__", @qemu_ram_mb.to_s)
        .gsub("__OVMF_CODE_SOURCE__", OVMF_CODE_SOURCE)
        .gsub("__OVMF_VARS_PATH__", OVMF_VARS_PATH)
        .gsub("__MFSBSD_PATH__", mfsbsd_local_path)
        .gsub("__QEMU_TARGET_DISKS__", qemu_target_disks_args)
        .gsub("__DISTSITE__", "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/#{@freebsd_version}-RELEASE")
        .gsub("__FREEBSD_VERSION__", @freebsd_version)
        .gsub("__ABI__", @abi)
        .gsub("__HOSTNAME__", @hostname)
        .gsub("__TIMEZONE__", @timezone)
        .gsub("__USERS_TSV__", @users.map(&.to_tsv).join("\n"))
        .gsub("__PACKAGES__", @packages.join(" "))
        .gsub("__SUDOERS_CONTENT_B64__", sudoers_base64)
        .gsub("__DATA_POOLS_SCRIPT_B64__", data_pools_script_b64)
    end

    # Ordre global des disques passés à QEMU : boot d'abord, puis pools
    # data dans l'ordre de déclaration. Les index QEMU correspondent :
    # vtbd0 = mfsBSD, vtbd1..vtbd(N) = boot, vtbd(N+1).. = data.
    def all_qemu_disks : Array(String)
      @disks + @data_pools.flat_map(&.disks)
    end

    # Args `-drive` pour chaque disque cible passthrough dans QEMU.
    # Inclut boot ET pools data : on veut que la VM voie tout pour
    # créer les pools data post-install dans le même `qemu-system-x86_64`.
    # Chaque disque devient un vtbd* dans la VM (vtbd0=mfsBSD, vtbd1+=cibles).
    def qemu_target_disks_args : String
      all_qemu_disks.map do |disk|
        "-drive file=#{disk},format=raw,if=virtio,cache=none"
      end.join(" ")
    end

    # Script shell (non base64) qui crée les pools data sous /mnt via
    # `zpool create`. Vide si aucun pool data. Pour chaque pool :
    #
    #   zpool create -f -R /mnt -m <mountpoint> <nom> <vdev...>
    #   zpool set cachefile=/mnt/boot/zfs/zpool.cache <nom>
    #
    # `-R /mnt` = altroot : les cache files ZFS écrivent sous /mnt
    # (bon emplacement au reboot bare metal). `-f` car les disques
    # sont neufs, mais `zpool create` chipote parfois sur résidus.
    #
    # Le `zpool set cachefile` est INDISPENSABLE : sans lui,
    # l'export final (`zpool export -a`) retire le pool du cache,
    # et au reboot bare-metal FreeBSD ne retrouve plus que zroot
    # dans `/boot/zfs/zpool.cache`. Le pool data existe sur disque
    # (visible via `zpool import`) mais doit être importé à la main.
    # Constaté terrain quantas.aloli.net 24 avril 2026.
    #
    # Pointer vers `/mnt/boot/zfs/zpool.cache` (le cachefile du
    # système cible, dans zroot altroot /mnt) garantit qu'au reboot,
    # le rc.d/zfs du FreeBSD installé importe les deux pools.
    def data_pools_script : String
      return "" if @data_pools.empty?
      lines = [] of String
      boot_count = @disks.size
      vtbd_index = boot_count + 1 # vtbd(boot_count+1) = premier disque data
      @data_pools.each do |pool|
        devices = (vtbd_index...vtbd_index + pool.disks.size).map { |i| "vtbd#{i}" }
        vdev = pool.vdev_spec(devices)
        lines << "zpool create -f -R /mnt -m #{pool.mountpoint} #{pool.name} #{vdev}"
        lines << "zpool set cachefile=/mnt/boot/zfs/zpool.cache #{pool.name}"
        vtbd_index += pool.disks.size
      end
      lines.join("\n") + "\n"
    end

    # Version base64 du script pour injection dans le template shell
    # (évite les problèmes de quoting). Vide si aucun pool data.
    def data_pools_script_b64 : String
      script = data_pools_script
      return "" if script.empty?
      Base64.strict_encode(script)
    end

    # Contenu base64 du fichier sudoers (chaque ligne == une règle).
    # Vide si aucune règle → le driver shell skip la création du fichier.
    def sudoers_base64 : String
      return "" if @sudoers.empty?
      content = @sudoers.join('\n') + "\n"
      Base64.strict_encode(content)
    end

    private def verify_linux_rescue : Nil
      uname = @rescue_conn.exec("uname -s").stdout.strip
      raise "le rescue ne tourne pas sous Linux (uname -s = #{uname.inspect})" unless uname == "Linux"
    end

    private def check_target_disks_no_bsd : Nil
      all_qemu_disks.each { |disk| check_disk_no_bsd(disk) }
    end

    private def check_disk_no_bsd(disk : String) : Nil
      zpool_out = @rescue_conn.exec(
        "zpool import -d #{Process.quote(disk)} 2>&1 || true",
        raise_on_error: false,
      ).stdout
      if zpool_out =~ /pool:\s+(\S+)/
        raise TargetDiskNotEmpty.new(
          "NOGO : #{disk} porte déjà un pool ZFS importable (#{$1}).\n" \
          "Réinstallez un rescue propre via le panel de l'hébergeur (OVH → Install → Debian),\n" \
          "ou utilisez `beryl wipe #{@follow_hint_host_name || @hostname}`.\n" \
          "beryl ne wipe JAMAIS un disque existant sans confirmation explicite."
        )
      end
      parts_out = @rescue_conn.exec(
        "lsblk -no PARTTYPENAME #{Process.quote(disk)} 2>/dev/null | sort -u",
        raise_on_error: false,
      ).stdout
      if parts_out =~ /freebsd/i
        found = parts_out.lines.map(&.strip).reject(&.empty?).join(", ")
        raise TargetDiskNotEmpty.new(
          "NOGO : #{disk} contient des partitions BSD (#{found}).\n" \
          "Réinstallez un rescue propre via le panel de l'hébergeur (OVH → Install → Debian),\n" \
          "ou utilisez `beryl wipe #{@follow_hint_host_name || @hostname}`.\n" \
          "beryl ne wipe JAMAIS un disque existant sans confirmation explicite."
        )
      end
    end

    class TargetDiskNotEmpty < Exception
    end

    private def install_packages : Nil
      @rescue_conn.exec(
        "mkdir -p #{Process.quote(WORK_DIR)} && " \
        "DEBIAN_FRONTEND=noninteractive apt-get update -qq && " \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 ovmf sshpass curl"
      )
    end

    private def download_mfsbsd_if_needed : Nil
      quoted = Process.quote(mfsbsd_local_path)
      quoted_url = Process.quote(@mfsbsd_url)
      @rescue_conn.exec(
        "test -s #{quoted} || curl -fLo #{quoted} #{quoted_url}"
      )
    end

    private def prepare_ovmf_vars : Nil
      @rescue_conn.exec(
        "cp -f #{Process.quote(OVMF_VARS_SOURCE)} #{Process.quote(OVMF_VARS_PATH)}"
      )
    end

    private def upload_driver_script : Nil
      File.tempfile(prefix: "beryl-rescue-run-", suffix: ".sh") do |tmp|
        tmp.print(render_rescue_run_vm)
        tmp.close
        @rescue_conn.upload(tmp.path, RESCUE_RUN_VM_PATH)
      end
      @rescue_conn.exec("chmod 755 #{Process.quote(RESCUE_RUN_VM_PATH)}")
    end

    private def hint_follow_bsdinstall : Nil
      border = "# " + "=" * 77
      STDERR.puts border
      STDERR.puts "# Pour suivre bsdinstall en direct depuis un autre terminal :"
      if name = @follow_hint_host_name
        STDERR.puts "#   beryl follow-install #{name}"
      else
        STDERR.puts "#   beryl follow-install <host>"
      end
      STDERR.puts border
    end

    private def reboot_bare_metal : Nil
      # OVH : API boot_from_disk → reboot hardware OVH sur disque.
      if client = @ovh_client
        if svc = @ovh_service_name
          client.dedicated_servers.boot_from_disk(svc)
          sleep REBOOT_GRACE_PERIOD
          return
        end
      end
      # Dedibox : helper reboot_to_disk du shard dedibox-api 0.1.3
      # qui encapsule boot_normal + reboot(reason). La sémantique
      # « sans boot_normal, le reboot laisse le serveur en rescue »
      # vit côté shard, pas ici.
      if ddx = @dedibox_client
        if sid = @dedibox_server_id
          ddx.servers.reboot_to_disk(sid, reason: "beryl post-bootstrap")
          sleep REBOOT_GRACE_PERIOD
          return
        end
      end
      # Sans API hébergeur : reboot depuis le rescue Linux. Peut
      # marcher (selon comment l'hébergeur gère son boot_mode) ou
      # pas — Dedibox p.ex. reviendrait en rescue sans l'API call
      # au-dessus.
      @rescue_conn.exec(
        "sync && (reboot -f 2>/dev/null || echo b > /proc/sysrq-trigger)",
        raise_on_error: false,
      )
      sleep REBOOT_GRACE_PERIOD
    end

    # Attend que le FreeBSD fraîchement installé réponde en SSH. Pas
    # de log en propre ici : l'appelant enveloppe déjà cet appel dans
    # un `log_step("6/6 — reboot bare metal … attente SSH")` qui porte
    # le compteur vivant `[NNNs]`. Double affichage = ligne mélangée,
    # observé sur loulou le 23 avril 2026.
    private def wait_for_installed_ssh : SSH::Connection
      # Réutilise l'identity_file du rescue : c'est la clé OPS locale,
      # qui DOIT aussi avoir été injectée dans `~admin/.ssh/authorized_keys`
      # pendant le post-install (via `user.ssh_keys` du YAML). Sans ça,
      # `BatchMode=yes` forcé par le shard ssh fait échouer silencieusement
      # l'auth publickey et le polling tourne dans le vide.
      conn = SSH::Connection.new(
        host: @rescue_conn.host,
        user: @installed_user,
        port: @installed_port,
        identity_file: @rescue_conn.identity_file,
      )
      deadline = Time.instant + SSH_WAIT_TIMEOUT
      last_error = nil
      while Time.instant < deadline
        begin
          result = conn.exec("uname -s", raise_on_error: false)
          if result.success? && result.stdout.strip == "FreeBSD"
            return conn
          end
        rescue ex
          last_error = ex
        end
        sleep SSH_POLL_INTERVAL
      end
      raise "timeout : le FreeBSD installé n'a pas répondu en SSH au bout de #{SSH_WAIT_TIMEOUT.total_minutes.to_i} min (dernière erreur : #{last_error.try(&.message)})"
    end

    def self.timestamp : String
      Beryl.format_timestamp(Time.local)
    end

    # Wrapper vers `Beryl.log_step` avec le préfixe figé pour ce module.
    # Garde les call sites compacts (pas de prefix à répéter) tout en
    # partageant la mécanique de compteur `[NNNs]` avec rescue/boot-hd.
    private def log_step(label : String, & : -> T) : T forall T
      Beryl.log_step("beryl bootstrap mfsbsd", label) { yield }
    end

    private def log(message : String) : Nil
      STDERR.puts "[#{self.class.timestamp}] [beryl bootstrap mfsbsd] #{message}"
    end
  end
end
