require "base64"
require "../ssh"

module Beryl::Bootstrap
  # Bootstrap complet FreeBSD via mfsBSD-dans-QEMU-dans-rescue (ADR-012).
  #
  # Remplace l'ancienne voie `disc1.iso + xorriso remaster` (ADR-011) qui
  # cassait la chaîne UEFI hybride FreeBSD à chaque remaster. La voie
  # actuelle est celle que la communauté utilise (depenguin.me) : mfsBSD
  # est une miniroot FreeBSD pré-construite conçue pour être scriptée, on
  # la boote intacte dans QEMU et on injecte l'installerconfig via SSH
  # une fois la VM démarrée.
  #
  # Flux :
  #
  # . SSH sur le rescue Linux Debian-like fourni par l'hébergeur.
  # . `apt install qemu-system-x86 sshpass curl` (pas d'OVMF, pas de xorriso).
  # . Téléchargement (une fois) de l'image mfsBSD SE depuis mfsbsd.vx.sk.
  # . Lancement QEMU avec l'image mfsBSD + passthrough du disque réel en
  #   virtio-blk. mfsBSD boote en BIOS (pas d'UEFI donc pas d'OVMF_VARS).
  # . Attente SSH sur le port QEMU forwardé (127.0.0.1:2223, root/mfsroot
  #   en keyboard-interactive côté mfsBSD SE).
  # . Upload de l'installerconfig via `scp` + lancement `bsdinstall script`.
  # . bsdinstall installe FreeBSD sur `/dev/vtbd1` (le disque réel
  #   passthrough). Au poweroff final du script, QEMU quitte via `-no-reboot`.
  # . `reboot -f` du bare metal rescue → l'UEFI trouve la FreeBSD posée.
  # . Attente SSH sur l'hôte, avec clé d'hôte nouvelle.
  class QemuInRescue
    # URL par défaut de l'image mfsBSD SE (Special Edition, password root
    # prédéfini à `mfsroot`). `__VERSION_MFS__` est remplacé par
    # `@mfsbsd_version`. Le numéro de version mfsBSD est découplé de la
    # FreeBSD cible : mfsBSD 14.2 peut installer FreeBSD 15.0 via
    # `BSDINSTALL_DISTSITE`.
    DEFAULT_MFSBSD_URL_TEMPLATE =
      "https://mfsbsd.vx.sk/files/images/__VERSION_MAJOR__/amd64/mfsbsd-se-__VERSION_MFS__-RELEASE-amd64.img"

    # Chemins utilisés côté rescue. Tout est groupé sous /root/beryl-test/
    # pour pouvoir reprendre sans retélécharger.
    WORK_DIR      = "/root/beryl-test"
    MFSBSD_PATH   = "#{WORK_DIR}/mfsbsd-se.img"
    INSTALLERCFG  = "#{WORK_DIR}/installerconfig"
    QEMU_SERIAL   = "#{WORK_DIR}/qemu-serial.log"
    BSDINSTALL_LG = "#{WORK_DIR}/bsdinstall.log"

    # Port local sur le rescue, forwardé vers le 22 de la VM par QEMU.
    VM_SSH_HOST = "127.0.0.1"
    VM_SSH_PORT = 2223

    # Password root de mfsBSD-SE (documenté upstream, image éditée par
    # mmatuska pour être immédiatement scriptable via sshpass).
    MFSBSD_ROOT_PASSWORD = "mfsroot"

    # Timings. Les reboots OVH et le boot de mfsBSD sont rapides (<2 min) ;
    # l'install FreeBSD + fetch des txz prend 10-25 min selon la bande
    # passante du rescue.
    SSH_WAIT_TIMEOUT    = 30.minutes
    SSH_POLL_INTERVAL   = 15.seconds
    VM_BOOT_TIMEOUT     = 3.minutes
    VM_POLL_INTERVAL    = 5.seconds
    REBOOT_GRACE_PERIOD = 30.seconds
    QEMU_MAX_RUNTIME    = 45.minutes

    TEMPLATE_INSTALLERCONFIG = {{ read_file("#{__DIR__}/templates/installerconfig.sh") }}

    getter rescue_conn : SSH::Connection
    getter target_disk : String
    getter hostname : String
    getter authorized_keys : Array(String)
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

    def initialize(
      @rescue_conn : SSH::Connection,
      @target_disk : String,
      @hostname : String,
      @authorized_keys : Array(String),
      @freebsd_version : String = "15.0",
      @mfsbsd_version : String = "14.2",
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
      raise ArgumentError.new("mfsbsd_version requis") if @mfsbsd_version.empty?
      raise ArgumentError.new("qemu_ram_mb doit être >= 1024") if @qemu_ram_mb < 1024
      raise ArgumentError.new("qemu_cpus doit être >= 1") if @qemu_cpus < 1

      # Le paramètre historique `iso_url` (ADR-011) reste accepté pour
      # rétrocompatibilité côté CLI mais pilote maintenant l'URL mfsBSD.
      @mfsbsd_url = iso_url || self.class.default_mfsbsd_url(@mfsbsd_version)
    end

    # URL par défaut de l'image mfsBSD SE, paramétrée par la version.
    def self.default_mfsbsd_url(mfsbsd_version : String) : String
      major = mfsbsd_version.split('.').first
      DEFAULT_MFSBSD_URL_TEMPLATE
        .gsub("__VERSION_MAJOR__", major)
        .gsub("__VERSION_MFS__", mfsbsd_version)
    end

    # Alias rétrocompat : le paramètre CLI historique s'appelait `iso_url`
    # (voie ADR-011). Il pilote maintenant l'URL mfsBSD.
    def iso_url : String
      @mfsbsd_url
    end

    # Exécute le bootstrap complet et renvoie une `SSH::Connection`
    # prête vers le FreeBSD fraîchement installé (utilisateur `admin`
    # par défaut — `PermitRootLogin no` est appliqué par FreeBSD 15).
    def run : SSH::Connection
      log_step("1/7 — vérifie que le rescue tourne bien sous Linux") { verify_linux_rescue }
      log_step("2/7 — installe qemu-system-x86, sshpass et curl côté rescue") { install_packages }
      log_step("3/7 — télécharge l'image mfsBSD SE #{@mfsbsd_version} si nécessaire") { download_mfsbsd_if_needed }
      log_step("4/7 — écrit l'installerconfig côté rescue") do
        @rescue_conn.write_file(INSTALLERCFG, render_installerconfig, mode: "0644")
      end
      log_step("5/7 — lance QEMU avec mfsBSD + disque #{@target_disk} passthrough") do
        launch_qemu_background
        wait_for_vm_ssh
      end
      log_step("6/7 — upload installerconfig + bsdinstall (10-25 min)") do
        scp_installerconfig_to_vm
        run_bsdinstall_in_vm
      end
      result = log_step("7/7 — reboot bare metal sur la FreeBSD posée, attente SSH") do
        reboot_bare_metal
        wait_for_installed_ssh
      end
      result
    end

    # Rend le fichier `installerconfig` à embarquer dans la VM.
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
        "-drive", "file=#{MFSBSD_PATH},format=raw,if=virtio",
        "-drive", "file=#{@target_disk},format=raw,if=virtio,cache=none",
        "-netdev", "user,id=net0,hostfwd=tcp::#{VM_SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-nographic",
        "-serial", "file:#{QEMU_SERIAL}",
        "-no-reboot",
      ]
      args.map { |a| Process.quote(a) }.join(' ')
    end

    private def verify_linux_rescue : Nil
      uname = @rescue_conn.exec("uname -s").stdout.strip
      raise "le rescue ne tourne pas sous Linux (uname -s = #{uname.inspect})" unless uname == "Linux"
    end

    private def install_packages : Nil
      @rescue_conn.exec(
        "mkdir -p #{Process.quote(WORK_DIR)} && " \
        "DEBIAN_FRONTEND=noninteractive apt-get update -qq && " \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 sshpass curl"
      )
    end

    private def download_mfsbsd_if_needed : Nil
      quoted = Process.quote(MFSBSD_PATH)
      quoted_url = Process.quote(@mfsbsd_url)
      @rescue_conn.exec(
        "test -s #{quoted} || curl -fLo #{quoted} #{quoted_url}"
      )
    end

    private def launch_qemu_background : Nil
      # Lance QEMU en nohup + detaché, stdout/stderr noyés. Le process
      # survit à notre session SSH : on ne l'attend pas ici, la fin de
      # l'install se détecte via le poweroff de la VM (QEMU quitte seul).
      cmd = "cd #{Process.quote(WORK_DIR)} && " \
            ": > #{Process.quote(QEMU_SERIAL)} && " \
            "nohup timeout #{QEMU_MAX_RUNTIME.total_seconds.to_i} #{qemu_command} " \
            ">/dev/null 2>&1 & disown"
      @rescue_conn.exec(cmd)
    end

    private def wait_for_vm_ssh : Nil
      # Boucle sshpass de polling ; succès dès que `uname -s` répond.
      deadline = Time.instant + VM_BOOT_TIMEOUT
      last_error = nil
      while Time.instant < deadline
        begin
          check = mfsbsd_ssh_cmd("uname -s")
          result = @rescue_conn.exec(check, raise_on_error: false)
          return if result.success? && result.stdout.strip == "FreeBSD"
        rescue ex
          last_error = ex
        end
        sleep VM_POLL_INTERVAL
      end
      raise "timeout : mfsBSD n'a pas répondu en SSH au bout de #{VM_BOOT_TIMEOUT.total_minutes.to_i} min" \
            " (dernière erreur : #{last_error.try(&.message)})"
    end

    private def scp_installerconfig_to_vm : Nil
      # sshpass + scp : mfsBSD SE accepte keyboard-interactive ; pas
      # besoin d'injecter une clé au préalable, sshpass suffit pour
      # toute la durée de l'install.
      cmd = "sshpass -p #{Process.quote(MFSBSD_ROOT_PASSWORD)} " \
            "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " \
            "-o PreferredAuthentications=keyboard-interactive " \
            "-o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 " \
            "-P #{VM_SSH_PORT} #{Process.quote(INSTALLERCFG)} " \
            "root@#{VM_SSH_HOST}:/tmp/installerconfig"
      @rescue_conn.exec(cmd)
    end

    private def run_bsdinstall_in_vm : Nil
      # BSDINSTALL_DISTSITE pointe sur le mirror FreeBSD 15 ; mfsBSD 14.2
      # sert juste de porteur. `nohup` + `&` + disown, puis on attend la
      # fin de QEMU (poweroff côté guest = QEMU qui exit).
      distsite = "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/#{@freebsd_version}-RELEASE"
      remote = "export BSDINSTALL_DISTSITE=#{Process.quote(distsite)} && " \
               "nohup bsdinstall script /tmp/installerconfig >#{BSDINSTALL_LG} 2>&1 & disown ; sleep 1"
      @rescue_conn.exec(mfsbsd_ssh_cmd(remote))

      # Attente : la VM s'éteint quand installerconfig termine par poweroff.
      # QEMU exit alors via `-no-reboot`. Le process QEMU sur le rescue
      # disparaît — on poll son absence. Le compteur inline du log_step
      # englobant donne le feedback visuel.
      wait_for_qemu_exit
    end

    private def wait_for_qemu_exit : Nil
      # Poll tant que le process qemu-system-x86_64 existe.
      deadline = Time.instant + QEMU_MAX_RUNTIME
      while Time.instant < deadline
        result = @rescue_conn.exec(
          "pgrep -f 'qemu-system-x86_64.*mfsbsd-se.img' >/dev/null",
          raise_on_error: false,
        )
        return unless result.success?
        sleep 10.seconds
      end
      raise "timeout : QEMU n'a pas terminé en #{QEMU_MAX_RUNTIME.total_minutes.to_i} min"
    end

    private def reboot_bare_metal : Nil
      # Rescue Linux : `reboot -f` court-circuite systemd. `sync` d'abord.
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
          return conn if result.success? && result.stdout.strip == "FreeBSD"
        rescue ex
          last_error = ex
        end
        sleep SSH_POLL_INTERVAL
      end
      raise "timeout : le FreeBSD installé n'a pas répondu en SSH au bout de #{SSH_WAIT_TIMEOUT.total_minutes.to_i} min (dernière erreur : #{last_error.try(&.message)})"
    end

    # Assemble une commande shell qui ouvre un ssh authentifié en
    # keyboard-interactive (mfsBSD SE) vers la VM, avec les options
    # anti-known_hosts standards pour un usage one-shot.
    private def mfsbsd_ssh_cmd(remote : String) : String
      "sshpass -p #{Process.quote(MFSBSD_ROOT_PASSWORD)} " \
      "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " \
      "-o PreferredAuthentications=keyboard-interactive " \
      "-o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 " \
      "-p #{VM_SSH_PORT} root@#{VM_SSH_HOST} #{Process.quote(remote)}"
    end

    # Échappement pour insertion dans une chaîne shell double-guillemets.
    private def shell_escape(value : String) : String
      value.gsub(/["$`\\]/) { |c| "\\#{c}" }
    end

    # Exécute un bloc en affichant le préfixe + un compteur de temps inline,
    # rafraîchi en place (`\r`), qui fige à sa valeur finale avec un `\n`
    # quand le bloc sort. La ligne qui suit vient donc *sous* le compteur
    # figé, qui reste trace permanente. Chaque ligne est horodatée
    # (JJ-MM-AAAA HHhMMmSS, convention Aloli) pour que le log entier
    # serve aussi d'historique horaire.
    #
    #   20-04-2026 21h35m12 [beryl bootstrap mfsbsd] 2/7 — apt install …  [  0s]\r
    #   20-04-2026 21h35m26 [beryl bootstrap mfsbsd] 2/7 — apt install …  [ 14s]\n
    #   20-04-2026 21h35m26 [beryl bootstrap mfsbsd] 3/7 — …              [  …]
    private def log_step(label : String, & : -> T) : T forall T
      line = "[#{self.class.timestamp}] [beryl bootstrap mfsbsd] #{label}"
      STDERR.print "#{line}  [   0s]"
      STDERR.flush
      start = Time.instant
      done = Channel(Nil).new
      spawn do
        loop do
          select
          when done.receive?
            break
          when timeout(1.second)
            elapsed = (Time.instant - start).total_seconds.to_i
            STDERR.printf("\r%s  [%4ds]", line, elapsed)
            STDERR.flush
          end
        end
      end
      begin
        result = yield
        elapsed = (Time.instant - start).total_seconds.to_i
        STDERR.printf("\r%s  [%4ds]\n", line, elapsed)
        result
      ensure
        done.send(nil)
      end
    end

    # Horodatage sensible à la locale :
    #
    # * `LANG=fr*` → `20/04/2026 21h35m12` (convention française)
    # * autres / non défini → `2026-04-20 21:35:12` (ISO 8601)
    #
    # Exposé comme méthode de classe pour que `log_step` (et autres
    # helpers) le partagent sans duplication.
    def self.timestamp : String
      Beryl.format_timestamp(Time.local)
    end
  end
end
