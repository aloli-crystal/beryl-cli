require "base64"
require "ssh"

module Beryl::Bootstrap
  # DEPRECATED (ADR-010 / ADR-011) — n'est plus sur le chemin principal.
  #
  # Cette classe est la seconde phase du flux legacy mfsBSD + installer,
  # conçu pour installer FreeBSD depuis mfsBSD en RAM. Elle ne marche que
  # si la phase mfsBSD a pu booter, ce qui n'est pas le cas sur les dédiés
  # UEFI-only. Voir `ARCHITECTURE.adoc` ADR-010 et ADR-011.
  #
  # La voie actuelle est `Beryl::Bootstrap::QemuInRescue` qui remplace
  # `MfsBSD + Installer` en une seule étape (bsdinstall non interactif
  # dans une VM QEMU lancée côté rescue Linux).
  #
  # Installe FreeBSD 14.2 sur disque depuis une image mfsBSD SE 14.2
  # active en RAM. Les dists `base.txz` / `kernel.txz` sont embarqués
  # dans mfsBSD SE — pas de téléchargement nécessaire. Une future
  # sous-commande `beryl upgrade` gérera la migration vers FreeBSD 15
  # quand la mfsBSD SE 15 sera disponible.
  #
  # Le script shell d'installation est un template livré avec beryl
  # (`templates/install-pkgbase.sh`). Les placeholders `__XXX__` sont
  # substitués côté Crystal avant upload. Les clés SSH autorisées pour
  # root sont encodées en base64 pour traverser le shell sans encombre.
  #
  # IMPORTANT : ce script est **destructif** pour le disque cible.
  # L'implémentation actuelle cible une disposition simple 1 disque,
  # partition EFI + swap + pool ZFS. Des variantes (RAID mirror,
  # mode distset, GELI, bhyve) viendront après retour des tests grandeur nature.
  class Installer
    SSH_WAIT_TIMEOUT  = 20.minutes
    SSH_POLL_INTERVAL = 15.seconds

    # Charge le template au moment de la compilation : un seul binaire,
    # pas de fichier à déployer à côté.
    TEMPLATE_PKGBASE = {{ read_file("#{__DIR__}/templates/install-pkgbase.sh") }}

    getter mfsbsd_conn : SSH::Connection
    getter target_disk : String
    getter hostname : String
    getter authorized_keys : Array(String)
    getter pool_name : String
    getter swap_gb : Int32
    getter timezone : String
    getter abi : String

    def initialize(
      @mfsbsd_conn : SSH::Connection,
      @target_disk : String,
      @hostname : String,
      @authorized_keys : Array(String),
      @pool_name : String = "zroot",
      @swap_gb : Int32 = 4,
      @timezone : String = "Europe/Paris",
      @abi : String = "FreeBSD:14:amd64",
    )
      raise ArgumentError.new("authorized_keys ne peut pas être vide (sinon root sera injoignable)") if @authorized_keys.empty?
      raise ArgumentError.new("hostname requis") if @hostname.empty?
      raise ArgumentError.new("target_disk requis") if @target_disk.empty?
    end

    # Exécute l'installation complète et renvoie la connexion SSH vers
    # le serveur FreeBSD fraîchement installé (clé d'hôte ignorée — ce sera
    # fixé lors du premier `beryl apply`).
    def run : SSH::Connection
      log "1/4 — vérifie qu'on tourne bien dans mfsBSD"
      verify_mfsbsd

      log "2/4 — génère et téléverse le script d'installation"
      upload_script

      log "3/4 — exécute l'installation (destructive, #{@target_disk})"
      execute_script
      trigger_reboot

      log "4/4 — attend le retour SSH sur le système installé"
      wait_for_installed_system
    end

    # Rend le script d'installation en substituant les placeholders.
    # Exposé pour les tests.
    def render_script : String
      TEMPLATE_PKGBASE
        .gsub("__TARGET_DISK__", shell_escape(@target_disk))
        .gsub("__POOL_NAME__", shell_escape(@pool_name))
        .gsub("__HOSTNAME__", shell_escape(@hostname))
        .gsub("__ABI__", shell_escape(@abi))
        .gsub("__SWAP_GB__", @swap_gb.to_s)
        .gsub("__TIMEZONE__", shell_escape(@timezone))
        .gsub("__AUTHORIZED_KEYS_B64__", authorized_keys_base64)
    end

    # Concatène les clés et encode en base64 pour transport sûr à travers le shell.
    def authorized_keys_base64 : String
      plain = @authorized_keys.join('\n') + "\n"
      Base64.strict_encode(plain)
    end

    private def verify_mfsbsd : Nil
      uname = @mfsbsd_conn.exec("uname -s").stdout.strip
      raise "l'hôte ne tourne pas sous FreeBSD (uname -s = #{uname.inspect})" unless uname == "FreeBSD"
    end

    private def upload_script : Nil
      @mfsbsd_conn.write_file("/tmp/beryl-install.sh", render_script, mode: "0755")
    end

    private def execute_script : Nil
      @mfsbsd_conn.exec("/tmp/beryl-install.sh 2>&1 | tee /tmp/beryl-install.log")
    end

    private def trigger_reboot : Nil
      @mfsbsd_conn.exec("shutdown -r now", raise_on_error: false)
      sleep 30.seconds
    end

    private def wait_for_installed_system : SSH::Connection
      conn = SSH::Connection.new(
        host: @mfsbsd_conn.host,
        user: "root",
        port: @mfsbsd_conn.port,
      )

      deadline = Time.instant + SSH_WAIT_TIMEOUT
      last_error = nil
      while Time.instant < deadline
        begin
          result = conn.exec("uname -r", raise_on_error: false)
          if result.success? && result.stdout.strip.starts_with?("15.")
            log "système FreeBSD 15 installé et joignable (uname -r = #{result.stdout.strip})"
            return conn
          end
        rescue ex
          last_error = ex
        end
        sleep SSH_POLL_INTERVAL
      end

      raise "timeout : le système installé n'a pas répondu en SSH au bout de #{SSH_WAIT_TIMEOUT.total_minutes.to_i} min (dernière erreur : #{last_error.try(&.message)})"
    end

    # Échappement léger pour un insert dans une chaîne shell double-guillemets.
    private def shell_escape(value : String) : String
      value.gsub(/["$`\\]/) { |c| "\\#{c}" }
    end

    private def log(message : String) : Nil
      STDERR.puts "[beryl bootstrap installer] #{message}"
    end
  end
end
