require "../ssh"

module Beryl::Bootstrap
  # Bascule un serveur depuis son rescue Linux (fourni par l'hébergeur)
  # vers une image mfsBSD bootable qui tourne entièrement en RAM.
  #
  # Méthode : téléchargement de l'image mfsBSD depuis le rescue Linux,
  # écriture `dd` sur le disque cible (destructif), redémarrage, puis
  # réouverture SSH vers l'image mfsBSD fraîchement démarrée.
  #
  # La clé d'hôte SSH change entre les deux phases : la connexion de retour
  # est construite via `SSH::Connection.insecure_bootstrap` pour ignorer
  # volontairement la vérification (MITM possible, mais c'est le seul
  # mode envisageable pour le bootstrap initial).
  class MfsBSD
    DEFAULT_IMAGE_URL   = "https://depenguin.me/files/mfsbsd-15.0-RELEASE-amd64.iso"
    SSH_WAIT_TIMEOUT    = 20.minutes
    SSH_POLL_INTERVAL   = 15.seconds
    REBOOT_GRACE_PERIOD = 30.seconds

    getter rescue_conn : SSH::Connection
    getter image_url : String
    getter target_disk : String
    getter mfsbsd_user : String
    getter mfsbsd_port : Int32

    def initialize(
      @rescue_conn : SSH::Connection,
      @target_disk : String,
      @image_url : String = DEFAULT_IMAGE_URL,
      @mfsbsd_user : String = "root",
      @mfsbsd_port : Int32 = 22,
    )
    end

    # Exécute la bascule complète et renvoie une connexion SSH vers mfsBSD.
    def run : SSH::Connection
      log "1/5 — vérifie que le rescue tourne bien sous Linux"
      verify_linux_rescue

      log "2/5 — télécharge l'image mfsBSD (#{@image_url})"
      download_image

      log "3/5 — écrit l'image sur #{@target_disk} (opération destructive)"
      write_image

      log "4/5 — déclenche le redémarrage (la connexion SSH va se fermer)"
      trigger_reboot

      log "5/5 — attend le retour SSH sur mfsBSD (clé d'hôte changée)"
      wait_for_mfsbsd
    end

    # Renvoie une commande shell qui détecte le disque principal.
    #
    # À exécuter manuellement via `rescue_conn.exec(MfsBSD.detect_disk_cmd)`
    # avant d'instancier MfsBSD, puis passer le résultat en `target_disk:`.
    # Volontairement *non* appelée automatiquement : l'opérateur doit
    # valider visuellement le disque avant de lancer un `dd` destructif.
    def self.detect_disk_cmd : String
      "lsblk -dno NAME,TYPE,SIZE | awk '$2==\"disk\"{print \"/dev/\" $1, $3}'"
    end

    private def verify_linux_rescue : Nil
      uname = @rescue_conn.exec("uname -s").stdout.strip
      raise "le rescue ne tourne pas sous Linux (uname -s = #{uname.inspect})" unless uname == "Linux"
    end

    private def download_image : Nil
      @rescue_conn.exec("curl -fLo /tmp/mfsbsd.img #{Process.quote(@image_url)}")
    end

    private def write_image : Nil
      @rescue_conn.exec(
        "dd if=/tmp/mfsbsd.img of=#{Process.quote(@target_disk)} bs=4M status=progress oflag=sync && sync"
      )
    end

    private def trigger_reboot : Nil
      # La connexion SSH meurt pendant le reboot, donc on ignore l'exit code.
      @rescue_conn.exec("reboot", raise_on_error: false)
      sleep REBOOT_GRACE_PERIOD
    end

    private def wait_for_mfsbsd : SSH::Connection
      conn = SSH::Connection.insecure_bootstrap(
        host: @rescue_conn.host,
        user: @mfsbsd_user,
        port: @mfsbsd_port,
      )

      deadline = Time.instant + SSH_WAIT_TIMEOUT
      last_error = nil
      while Time.instant < deadline
        begin
          result = conn.exec("uname -s", raise_on_error: false)
          if result.success? && result.stdout.strip == "FreeBSD"
            log "mfsBSD est joignable (uname -s = FreeBSD)"
            return conn
          end
        rescue ex
          last_error = ex
        end
        sleep SSH_POLL_INTERVAL
      end

      raise "timeout : mfsBSD n'a pas répondu en SSH au bout de #{SSH_WAIT_TIMEOUT.total_minutes.to_i} min (dernière erreur : #{last_error.try(&.message)})"
    end

    private def log(message : String) : Nil
      STDERR.puts "[beryl bootstrap mfsbsd] #{message}"
    end
  end
end
