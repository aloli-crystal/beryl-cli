require "option_parser"
require "silex"

module Beryl::CLI::BakeSeed
  DEFAULT_OUTPUT   = "~/vms/seed.img"
  DEFAULT_PUBKEY   = "~/.ssh/id_ed25519.pub"
  DEFAULT_HOSTNAME = "beryl-test-vm"
  DEFAULT_SIZE_KB  = 128

  def self.run(args : Array(String)) : Int32
    output_path = File.expand_path(DEFAULT_OUTPUT, home: true)
    pubkey_path = File.expand_path(DEFAULT_PUBKEY, home: true)
    hostname = DEFAULT_HOSTNAME
    size_kb = DEFAULT_SIZE_KB
    ssh_user = "root"

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl bake-seed [options]\n\n" \
                 "Génère un seed.img NoCloud cloud-init contenant votre clé SSH\n" \
                 "publique, prêt à attacher à une VM Ubuntu Server live en 2ᵉ\n" \
                 "cdrom. Cloud-init configure SSH pour l'utilisateur choisi\n" \
                 "automatiquement au premier boot."
      p.on("--output=PATH", "Fichier de sortie (défaut : #{DEFAULT_OUTPUT})") do |v|
        output_path = File.expand_path(v, home: true)
      end
      p.on("--pubkey=FILE", "Clé publique SSH (défaut : #{DEFAULT_PUBKEY})") do |v|
        pubkey_path = File.expand_path(v, home: true)
      end
      p.on("--hostname=NAME", "Hostname cible (défaut : #{DEFAULT_HOSTNAME})") { |v| hostname = v }
      p.on("--user=USER", "Utilisateur autorisé (défaut : root)") { |v| ssh_user = v }
      p.on("--size=KB", "Taille de l'image en Ko (défaut : #{DEFAULT_SIZE_KB})") { |v| size_kb = v.to_i }
      p.on("-h", "--help", "Aide") do
        puts p
        exit 0
      end
    end
    parser.parse(args)

    unless File.exists?(pubkey_path)
      STDERR.puts "beryl bake-seed : clé publique SSH introuvable : #{pubkey_path}"
      return 1
    end

    pubkey = File.read(pubkey_path).strip
    meta_data = <<-YAML
    instance-id: iid-#{hostname}
    local-hostname: #{hostname}
    YAML

    user_data = build_user_data(ssh_user, pubkey, hostname)

    image = Silex::FatImage.new(size_bytes: size_kb * 1024, label: "CIDATA")
    image.add_file("meta-data", meta_data)
    image.add_file("user-data", user_data)

    Dir.mkdir_p(File.dirname(output_path))
    File.write(output_path, image.to_slice)

    STDERR.puts "[beryl bake-seed] écrit : #{output_path} (#{File.size(output_path)} octets)"
    STDERR.puts "[beryl bake-seed] étiquette  : CIDATA (NoCloud)"
    STDERR.puts "[beryl bake-seed] hostname   : #{hostname}"
    STDERR.puts "[beryl bake-seed] utilisateur: #{ssh_user}"
    STDERR.puts "[beryl bake-seed] clé        : #{pubkey_path}"
    STDERR.puts
    STDERR.puts "Attachez ce fichier comme second cdrom à une VM Ubuntu Server live"
    STDERR.puts "(cloud-init actif). Exemple d'intégration dans un YAML launch.sh :"
    STDERR.puts
    STDERR.puts "  seed_iso: #{output_path}"
    0
  rescue ex : Exception
    STDERR.puts "beryl bake-seed : #{ex.class}: #{ex.message}"
    1
  end

  private def self.build_user_data(user : String, pubkey : String, hostname : String) : String
    if user == "root"
      # Pour root, inutile de créer l'utilisateur, il faut juste poser la clé.
      <<-CLOUD
      #cloud-config
      hostname: #{hostname}
      ssh_pwauth: false
      disable_root: false
      ssh_authorized_keys:
        - #{pubkey}
      runcmd:
        - systemctl enable --now ssh
      CLOUD
    else
      <<-CLOUD
      #cloud-config
      hostname: #{hostname}
      ssh_pwauth: false
      users:
        - name: #{user}
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          ssh_authorized_keys:
            - #{pubkey}
      runcmd:
        - systemctl enable --now ssh
      CLOUD
    end
  end
end
