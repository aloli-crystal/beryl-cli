require "base64"
require "../ssh"

module Beryl::Bootstrap
  # Bootstrap complet FreeBSD 15 via la technique « QEMU-in-rescue ».
  #
  # Remplace les classes MfsBSD + Installer (dépréciées, cf. ADR-010)
  # pour les serveurs UEFI-only. Voir ADR-011 (« Bootstrap via
  # QEMU-in-rescue ») dans ARCHITECTURE.adoc.
  #
  # Flux :
  #
  # . SSH sur le rescue Linux Debian-like fourni par l'hébergeur.
  # . `apt install qemu-system-x86 ovmf xorriso`.
  # . Téléchargement de l'ISO officielle FreeBSD `disc1.iso` (hybride
  #   ISO 9660 + ESP UEFI + Legacy).
  # . Remasterisation de l'ISO via `xorriso` : ajout d'un fichier
  #   `/etc/installerconfig` généré par beryl qui scripte `bsdinstall`.
  # . Copie du template OVMF_VARS_4M.fd.
  # . Lancement QEMU avec `-machine q35 -enable-kvm`, OVMF UEFI,
  #   passthrough du disque réel en virtio, `-no-reboot` pour que QEMU
  #   quitte proprement au `poweroff` final du script.
  # . `bsdinstall` installe FreeBSD sur le disque réel (vtbd1 dans la
  #   VM). Au final, `poweroff` → QEMU se termine (grâce à `-no-reboot`).
  # . `reboot -f` du bare metal rescue → l'UEFI trouve la FreeBSD posée.
  # . Attente SSH sur l'hôte, avec clé d'hôte nouvelle.
  class QemuInRescue
    # ISO officielle FreeBSD (hybride : boot Legacy + UEFI) —
    # `__VERSION__` est remplacé par `@freebsd_version` au runtime.
    DEFAULT_ISO_URL_TEMPLATE =
      "https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/__VERSION__/FreeBSD-__VERSION__-RELEASE-amd64-disc1.iso"

    # Chemins utilisés côté rescue. Tout est groupé sous /root/beryl-test/
    # pour pouvoir reprendre sans retélécharger.
    WORK_DIR         = "/root/beryl-test"
    ISO_PATH         = "#{WORK_DIR}/disc1.iso"
    ISO_REMASTERED   = "#{WORK_DIR}/disc1-beryl.iso"
    OVMF_VARS_PATH   = "#{WORK_DIR}/vars.fd"
    OVMF_CODE_SOURCE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
    OVMF_VARS_SOURCE = "/usr/share/OVMF/OVMF_VARS_4M.fd"
    INSTALLERCFG     = "#{WORK_DIR}/installerconfig"
    QEMU_SERIAL_LOG  = "#{WORK_DIR}/qemu-serial.log"

    SSH_WAIT_TIMEOUT    = 30.minutes
    SSH_POLL_INTERVAL   = 15.seconds
    REBOOT_GRACE_PERIOD = 30.seconds
    QEMU_MAX_RUNTIME    = 45.minutes

    TEMPLATE_INSTALLERCONFIG = {{ read_file("#{__DIR__}/templates/installerconfig.sh") }}

    getter rescue_conn : SSH::Connection
    getter target_disk : String
    getter hostname : String
    getter authorized_keys : Array(String)
    getter freebsd_version : String
    getter timezone : String
    getter iso_url : String
    getter pool_name : String
    getter swap_gb : Int32
    getter abi : String
    getter qemu_ram_mb : Int32
    getter qemu_cpus : Int32
    getter installed_user : String
    getter installed_port : Int32

    def initialize(
      @rescue_conn : SSH::Connection,
      @target_disk : String,
      @hostname : String,
      @authorized_keys : Array(String),
      @freebsd_version : String = "15.0",
      @timezone : String = "Europe/Paris",
      iso_url : String? = nil,
      @pool_name : String = "zroot",
      @swap_gb : Int32 = 4,
      @abi : String = "FreeBSD:15:amd64",
      @qemu_ram_mb : Int32 = 4096,
      @qemu_cpus : Int32 = 4,
      @installed_user : String = "admin",
      @installed_port : Int32 = 22,
    )
      raise ArgumentError.new("authorized_keys ne peut pas être vide (sinon admin/deploy/root seraient injoignables)") if @authorized_keys.empty?
      raise ArgumentError.new("hostname requis") if @hostname.empty?
      raise ArgumentError.new("target_disk requis") if @target_disk.empty?
      raise ArgumentError.new("freebsd_version requis") if @freebsd_version.empty?
      raise ArgumentError.new("qemu_ram_mb doit être >= 1024") if @qemu_ram_mb < 1024
      raise ArgumentError.new("qemu_cpus doit être >= 1") if @qemu_cpus < 1

      @iso_url = iso_url || self.class.default_iso_url(@freebsd_version)
    end

    # URL par défaut de l'ISO disc1, paramétrée par la version FreeBSD.
    def self.default_iso_url(freebsd_version : String) : String
      DEFAULT_ISO_URL_TEMPLATE.gsub("__VERSION__", freebsd_version)
    end

    # Exécute le bootstrap complet et renvoie une `SSH::Connection`
    # prête vers le FreeBSD fraîchement installé (utilisateur `admin`
    # par défaut — `PermitRootLogin no` est appliqué par FreeBSD 15).
    def run : SSH::Connection
      log "1/8 — vérifie que le rescue tourne bien sous Linux"
      verify_linux_rescue

      log "2/8 — installe qemu-system-x86, ovmf et xorriso côté rescue"
      install_qemu_if_needed

      log "3/8 — télécharge l'ISO FreeBSD #{@freebsd_version} si nécessaire"
      download_iso_if_needed

      log "4/8 — remasterise l'ISO pour embarquer l'installerconfig"
      remaster_iso

      log "5/8 — prépare une copie privée de OVMF_VARS"
      prepare_ovmf_vars

      log "6/8 — lance QEMU (UEFI, KVM, disque #{@target_disk} passthrough)"
      launch_qemu_and_wait

      log "7/8 — redémarre le bare metal (la connexion SSH va se fermer)"
      reboot_bare_metal

      log "8/8 — attend le retour SSH sur le FreeBSD installé"
      wait_for_installed_ssh
    end

    # Rend le fichier `installerconfig` à embarquer dans l'ISO.
    # Exposé pour les tests.
    def render_installerconfig : String
      TEMPLATE_INSTALLERCONFIG
        .gsub("__HOSTNAME__", shell_escape(@hostname))
        .gsub("__TIMEZONE__", shell_escape(@timezone))
        .gsub("__ABI__", shell_escape(@abi))
        .gsub("__POOL_NAME__", shell_escape(@pool_name))
        .gsub("__SWAP_GB__", @swap_gb.to_s)
        .gsub("__AUTHORIZED_KEYS_B64__", authorized_keys_base64)
    end

    # Concatène les clés autorisées et encode en base64 pour transport
    # sûr à travers le shell (et pour que `b64decode -r` les récupère
    # côté FreeBSD).
    def authorized_keys_base64 : String
      plain = @authorized_keys.join('\n') + "\n"
      Base64.strict_encode(plain)
    end

    # Renvoie la ligne de commande QEMU finale (exposée pour les tests).
    def qemu_command : String
      args = [
        "qemu-system-x86_64",
        "-enable-kvm",
        "-machine", "q35",
        "-cpu", "host",
        "-smp", @qemu_cpus.to_s,
        "-m", "#{@qemu_ram_mb}M",
        "-drive", "if=pflash,format=raw,readonly=on,file=#{OVMF_CODE_SOURCE}",
        "-drive", "if=pflash,format=raw,file=#{OVMF_VARS_PATH}",
        "-drive", "file=#{ISO_REMASTERED},format=raw,if=virtio,media=cdrom",
        "-drive", "file=#{@target_disk},format=raw,if=virtio,cache=none",
        "-netdev", "user,id=net0,hostfwd=tcp::2223-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-nographic",
        "-serial", "file:#{QEMU_SERIAL_LOG}",
        "-no-reboot",
      ]
      args.map { |a| Process.quote(a) }.join(' ')
    end

    private def verify_linux_rescue : Nil
      uname = @rescue_conn.exec("uname -s").stdout.strip
      raise "le rescue ne tourne pas sous Linux (uname -s = #{uname.inspect})" unless uname == "Linux"
    end

    private def install_qemu_if_needed : Nil
      # `apt-get install` en mode non interactif — idempotent si les
      # paquets sont déjà posés. `xorriso` est utilisé pour l'ajout
      # de `installerconfig` dans l'ISO.
      @rescue_conn.exec(
        "mkdir -p #{Process.quote(WORK_DIR)} && " \
        "DEBIAN_FRONTEND=noninteractive apt-get update -qq && " \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 ovmf xorriso curl"
      )
    end

    private def download_iso_if_needed : Nil
      # `curl -fLo` ne retélécharge pas si l'ISO existe et est lisible,
      # tant qu'on teste sa présence avant. On évite `-C -` qui peut
      # échouer sur un serveur sans Range. Simple : si l'ISO existe, on
      # ne retouche à rien.
      quoted_iso = Process.quote(ISO_PATH)
      quoted_url = Process.quote(@iso_url)
      @rescue_conn.exec(
        "test -s #{quoted_iso} || curl -fLo #{quoted_iso} #{quoted_url}"
      )
    end

    private def remaster_iso : Nil
      # Télé-upload de l'installerconfig dans le rescue puis injection
      # dans l'ISO via `xorriso -indev ... -outdev ...` en copiant
      # le fichier à l'emplacement `/etc/installerconfig` lu par
      # `bsdinstall` au boot.
      @rescue_conn.write_file(INSTALLERCFG, render_installerconfig, mode: "0755")

      script = <<-SH
      set -eu
      rm -f #{Process.quote(ISO_REMASTERED)}
      xorriso -indev #{Process.quote(ISO_PATH)} \\
              -outdev #{Process.quote(ISO_REMASTERED)} \\
              -boot_image any replay \\
              -pathspecs on \\
              -update #{Process.quote(INSTALLERCFG)} /etc/installerconfig
      SH
      @rescue_conn.exec(script)
    end

    private def prepare_ovmf_vars : Nil
      @rescue_conn.exec(
        "cp -f #{Process.quote(OVMF_VARS_SOURCE)} #{Process.quote(OVMF_VARS_PATH)}"
      )
    end

    private def launch_qemu_and_wait : Nil
      # QEMU quitte de lui-même au `poweroff` final du script
      # installerconfig (grâce à `-no-reboot`). On se contente de
      # l'invoquer synchronement : tant qu'il tourne, notre `ssh exec`
      # attend. La sortie série est capturée côté rescue dans un log.
      cmd = "timeout #{QEMU_MAX_RUNTIME.total_seconds.to_i} #{qemu_command} " \
            "|| ec=$?; echo \"[beryl] qemu exit = ${ec:-0}\"; test \"${ec:-0}\" = 0"
      @rescue_conn.exec(cmd)
    end

    private def reboot_bare_metal : Nil
      # Rescue Linux : `reboot -f` court-circuite systemd (équivalent de
      # l'approche MfsBSD). `sync` d'abord pour rien oublier.
      @rescue_conn.exec(
        "sync && (reboot -f 2>/dev/null || echo b > /proc/sysrq-trigger)",
        raise_on_error: false,
      )
      sleep REBOOT_GRACE_PERIOD
    end

    private def wait_for_installed_ssh : SSH::Connection
      conn = SSH::Connection.insecure_bootstrap(
        host: @rescue_conn.host,
        user: @installed_user,
        port: @installed_port,
      )

      deadline = Time.instant + SSH_WAIT_TIMEOUT
      last_error = nil
      while Time.instant < deadline
        begin
          result = conn.exec("uname -s", raise_on_error: false)
          if result.success? && result.stdout.strip == "FreeBSD"
            log "FreeBSD installé et joignable (uname -s = FreeBSD, user = #{@installed_user})"
            return conn
          end
        rescue ex
          last_error = ex
        end
        sleep SSH_POLL_INTERVAL
      end

      raise "timeout : le FreeBSD installé n'a pas répondu en SSH au bout de #{SSH_WAIT_TIMEOUT.total_minutes.to_i} min (dernière erreur : #{last_error.try(&.message)})"
    end

    # Échappement pour insertion dans une chaîne shell double-guillemets.
    private def shell_escape(value : String) : String
      value.gsub(/["$`\\]/) { |c| "\\#{c}" }
    end

    private def log(message : String) : Nil
      STDERR.puts "[beryl bootstrap qemu-in-rescue] #{message}"
    end
  end
end
