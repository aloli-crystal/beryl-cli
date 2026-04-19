require "http/server"
require "option_parser"

module Beryl::CLI::PrepRescue
  DEFAULT_PORT   = 8080
  DEFAULT_BIND   = "127.0.0.1"
  DEFAULT_PUBKEY = "~/.ssh/id_ed25519.pub"

  # Gabarit du script de provisioning Debian/Ubuntu.
  # `__PORT__` est substitué à la volée par le port d'écoute effectif.
  SETUP_SCRIPT_TEMPLATE = <<-'SH'
  #!/bin/sh
  # Script de provisioning Debian/Ubuntu généré par `beryl prep-rescue`.
  # Rôle : installer openssh-server, activer root, injecter la clé SSH.
  set -eu

  HOST_URL="http://10.0.2.2:__PORT__"

  echo "==> [beryl prep-rescue] apt update + openssh-server + curl"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openssh-server curl

  echo "==> [beryl prep-rescue] clé SSH root"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  curl -fL "$HOST_URL/k" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys

  echo "==> [beryl prep-rescue] sshd : PermitRootLogin yes"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
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
                 "un script de provisioning pour un rescue Linux Debian/Ubuntu.\n" \
                 "Contourne l'absence de copier-coller dans les consoles de VM."
      p.on("--port=PORT", "Port d'écoute local (défaut : #{DEFAULT_PORT})") { |v| port = v.to_i }
      p.on("--bind=ADDR", "Adresse d'écoute (défaut : #{DEFAULT_BIND})") { |v| bind = v }
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
    setup_script = SETUP_SCRIPT_TEMPLATE.gsub("__PORT__", port.to_s)

    STDERR.puts "[beryl prep-rescue] clé SSH : #{pubkey_path}"
    STDERR.puts "[beryl prep-rescue] écoute sur http://#{bind}:#{port}"
    STDERR.puts
    STDERR.puts "Dans la VM (rescue Linux Debian/Ubuntu), tapez cette ligne unique :"
    STDERR.puts
    STDERR.puts "    curl -fL http://10.0.2.2:#{port}/s | sudo sh"
    STDERR.puts
    STDERR.puts "Pour un rescue distant (OVH/Scaleway), remplacez 10.0.2.2 par l'IP publique"
    STDERR.puts "de votre poste ; pensez à ouvrir le port #{port} dans votre firewall si nécessaire."
    STDERR.puts
    STDERR.puts "Ctrl+C pour arrêter le serveur."
    STDERR.puts

    server = HTTP::Server.new do |ctx|
      case ctx.request.path
      when "/k"
        ctx.response.content_type = "text/plain"
        ctx.response.print(pubkey + "\n")
        STDERR.puts "[beryl prep-rescue] 200 /k (clé SSH servie)"
      when "/s"
        ctx.response.content_type = "text/plain"
        ctx.response.print(setup_script)
        STDERR.puts "[beryl prep-rescue] 200 /s (script servi — exécution en cours côté VM)"
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
end
