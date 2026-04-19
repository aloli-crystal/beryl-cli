require "http/client"
require "http/server"
require "option_parser"

module Beryl::CLI::PrepRescue
  DEFAULT_PORT   = 8080
  DEFAULT_BIND   = "127.0.0.1"
  DEFAULT_PUBKEY = "~/.ssh/id_ed25519.pub"

  PUBLIC_IP_URL     = "https://api.ipify.org"
  PUBLIC_IP_TIMEOUT = 3.seconds

  MACOS_FW_CTL = "/usr/libexec/ApplicationFirewall/socketfilterfw"

  # Gabarit du script de provisioning Debian/Ubuntu.
  # `__HOST_URL__` est substitué à la volée par l'URL de base complète.
  #
  # Principe minimaliste : on ne touche à RIEN dans sshd_config. Debian 12+
  # et Ubuntu 22.04+ ont déjà `PermitRootLogin prohibit-password` par défaut
  # (accepte la clé, refuse le mot de passe). Comme aucun mot de passe root
  # n'est défini, la seule auth possible est par clé — exactement ce qu'on
  # veut. Le script se contente donc d'installer sshd et d'injecter la clé.
  SETUP_SCRIPT_TEMPLATE = <<-'SH'
  #!/bin/sh
  # Script de provisioning Debian/Ubuntu généré par `beryl prep-rescue`.
  # Installe openssh-server et injecte la clé publique dans /root/.ssh/.
  set -eu

  HOST_URL="__HOST_URL__"

  echo "==> [beryl prep-rescue] apt update + openssh-server + curl"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openssh-server curl

  echo "==> [beryl prep-rescue] clé SSH root"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  curl -fL "$HOST_URL/k" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys

  # Ne garde que la clé d'hôte ED25519. Évite de polluer known_hosts côté
  # opérateur avec trois entrées par VM (RSA, ECDSA, ED25519) à purger à
  # chaque recréation. Aligné sur Mozilla Modern OpenSSH.
  echo "==> [beryl prep-rescue] retire les clés d'hôte RSA/ECDSA"
  rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
  rm -f /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub

  systemctl enable --now ssh

  echo "==> [beryl prep-rescue] terminé. beryl bootstrap peut maintenant se connecter."
  SH

  def self.run(args : Array(String)) : Int32
    port = DEFAULT_PORT
    bind = DEFAULT_BIND
    pubkey_path = File.expand_path(DEFAULT_PUBKEY, home: true)

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl prep-rescue [options]\n\n" \
                 "Lance un serveur HTTP local qui sert votre clé publique SSH et\n" \
                 "un script de provisioning pour un rescue Linux Debian/Ubuntu."
      p.on("--port=PORT", "Port d'écoute local (défaut : #{DEFAULT_PORT})") { |v| port = v.to_i }
      p.on("--bind=ADDR", "Adresse d'écoute (défaut : #{DEFAULT_BIND})") { |v| bind = v }
      p.on("--public", "Raccourci pour --bind 0.0.0.0 (exposer à internet)") { bind = "0.0.0.0" }
      p.on("--pubkey=FILE", "Fichier de clé publique SSH (défaut : #{DEFAULT_PUBKEY})") do |v|
        pubkey_path = File.expand_path(v, home: true)
      end
      p.on("-h", "--help", "Affiche cette aide") do
        puts p
        exit 0
      end
    end
    parser.parse(args)

    unless File.exists?(pubkey_path)
      STDERR.puts "beryl prep-rescue : fichier de clé SSH introuvable : #{pubkey_path}"
      return 1
    end

    pubkey = File.read(pubkey_path).strip
    loopback = loopback_bind?(bind)
    public_ip = loopback ? nil : fetch_public_ip

    STDERR.puts "[beryl prep-rescue] clé SSH : #{pubkey_path}"
    STDERR.puts "[beryl prep-rescue] écoute sur http://#{bind}:#{port}"
    STDERR.puts

    STDERR.puts "Pour une VM QEMU locale (user-mode NAT), dans la VM :"
    STDERR.puts
    STDERR.puts "    curl -fL http://10.0.2.2:#{port}/s | sudo sh"
    STDERR.puts

    if !loopback
      if public_ip
        STDERR.puts "Pour un rescue distant (OVH/Scaleway), dans le rescue :"
        STDERR.puts
        STDERR.puts "    curl -fL http://#{public_ip}:#{port}/s | sudo sh"
        STDERR.puts
        print_public_checklist(port, public_ip)
      else
        STDERR.puts "Pour un rescue distant : IP publique indéterminée (pas de connexion internet ?)."
        STDERR.puts "Remplacez manuellement dans la commande curl par l'IP publique de ce poste."
        STDERR.puts
      end
    end

    STDERR.puts "Ctrl+C pour arrêter le serveur."
    STDERR.puts

    # Setup script renders with the base URL suitable for the VM local case.
    # Pour le rescue distant, la variable HOST_URL est remplacée à la volée
    # quand le script est fetché via l'IP publique (Host header inspecté).
    server = HTTP::Server.new do |ctx|
      case ctx.request.path
      when "/k"
        ctx.response.content_type = "text/plain"
        ctx.response.print(pubkey + "\n")
        STDERR.puts "[beryl prep-rescue] 200 /k (clé SSH servie)"
      when "/s"
        host_header = ctx.request.headers["Host"]?.to_s.split(":").first? || "10.0.2.2"
        host_url = "http://#{host_header}:#{port}"
        script = SETUP_SCRIPT_TEMPLATE.gsub("__HOST_URL__", host_url)
        ctx.response.content_type = "text/plain"
        ctx.response.print(script)
        STDERR.puts "[beryl prep-rescue] 200 /s (script servi via #{host_url})"
      else
        ctx.response.status = HTTP::Status::NOT_FOUND
        ctx.response.content_type = "text/plain"
        ctx.response.print("404\n")
        STDERR.puts "[beryl prep-rescue] 404 #{ctx.request.path}"
      end
    end

    Signal::INT.trap do
      STDERR.puts
      STDERR.puts "[beryl prep-rescue] arrêt"
      server.close
      exit 0
    end

    server.bind_tcp(bind, port)
    server.listen
    0
  end

  # Tente de récupérer l'IP publique. Retourne nil si la requête échoue
  # (hors ligne, time-out, DNS down, etc.).
  private def self.fetch_public_ip : String?
    uri = URI.parse(PUBLIC_IP_URL)
    HTTP::Client.new(uri).tap do |client|
      client.connect_timeout = PUBLIC_IP_TIMEOUT
      client.read_timeout = PUBLIC_IP_TIMEOUT
    end.get(uri.request_target).body.strip
  rescue ex : Exception
    STDERR.puts "[beryl prep-rescue] détection IP publique : #{ex.class}: #{ex.message}"
    nil
  end

  private def self.loopback_bind?(addr : String) : Bool
    addr == "127.0.0.1" || addr == "localhost" || addr == "::1"
  end

  private def self.print_public_checklist(port : Int32, public_ip : String) : Nil
    exe = File.expand_path(PROGRAM_NAME)
    STDERR.puts "Avant que le rescue distant puisse atteindre ce port, vérifiez :"
    STDERR.puts
    STDERR.puts "  1. Pare-feu macOS (Application Firewall)"
    STDERR.puts "     Autoriser beryl :"
    STDERR.puts "       sudo #{MACOS_FW_CTL} --add #{exe.inspect}"
    STDERR.puts "       sudo #{MACOS_FW_CTL} --unblockapp #{exe.inspect}"
    STDERR.puts "     Retirer l'exception après usage :"
    STDERR.puts "       sudo #{MACOS_FW_CTL} --remove #{exe.inspect}"
    STDERR.puts
    STDERR.puts "  2. Routeur / box internet"
    STDERR.puts "     Redirection du port TCP #{port} vers votre Mac."
    STDERR.puts "     Documentation par opérateur :"
    STDERR.puts "       - Freebox   https://www.free.fr/assistance/4407.html"
    STDERR.puts "       - Orange    https://assistance.orange.fr/livebox-modem/tous-les-themes/utilisation-et-reglages/parametrer-des-redirections-de-port_57587-57616"
    STDERR.puts "       - Bouygues  https://www.assistance.bouyguestelecom.fr/s/article/box-comment-configurer-un-service-nat-pat"
    STDERR.puts "       - SFR       https://assistance.sfr.fr/internet-tel-fixe/box-nb6/connaitre-les-nouvelles-options-avancees-du-parametrage-de-votre-box.html"
    STDERR.puts
    STDERR.puts "  3. Test rapide depuis un autre réseau (4G par exemple) :"
    STDERR.puts "       curl -v http://#{public_ip}:#{port}/k"
    STDERR.puts
  end
end
