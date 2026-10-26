require "option_parser"
require "./option_errors"
require "../config"
require "../ssh_config"

# Sous-commande `beryl ssh-config` : écrit `~/.ssh/beryl.conf` (hosts cachés
# derrière le vRack, rebond à replis — voir `Beryl::SshConfig`) et l'inclut en
# tête de `~/.ssh/config`. Toujours TOUT le parc (toutes sociétés) : le
# fichier est regénéré en entier, une portée en ferait disparaître le reste.
# Essai à blanc par défaut (contenu affiché) ; `--apply` écrit.
module Beryl::CLI::SshConfig
  EXIT_OK    = 0
  EXIT_USAGE = 1

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = true
    ssh_dir = File.join(Path.home.to_s, ".ssh")

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl ssh-config [--apply]\n\n" \
                 "Écrit ~/.ssh/#{Beryl::SshConfig::FILE_NAME} : pour chaque host caché derrière le vRack, son IP vRack\n" \
                 "et un rebond qui essaie son bastion préféré puis les autres ; l'inclut en tête de ~/.ssh/config.\n" \
                 "`ssh ke.quimeo.net` (user et clé de votre config) ou `ssh ke` passent alors par les bastions.\n"
      p.on("--apply", "Écrit les fichiers (sinon : dry-run, affiche le contenu)") { dry_run = false }
      p.on("--ssh-dir=DIR", "Dossier ssh (défaut : ~/.ssh)") { |v| ssh_dir = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)

    root = Beryl::Config::Root.load(config_root)
    hosts = root.all_hosts_by_fqdn.keys.compact_map do |fqdn|
      root.resolve(fqdn)
    rescue
      nil
    end
    content = Beryl::SshConfig.render(hosts)
    count = content.lines.count(&.starts_with?("# ")) - 2
    conf = File.join(ssh_dir, Beryl::SshConfig::FILE_NAME)
    main = File.join(ssh_dir, "config")
    current = File.exists?(main) ? File.read(main) : ""
    included = Beryl::SshConfig.with_include(current)
    unchanged = File.exists?(conf) && File.read(conf) == content

    if dry_run
      puts content
      STDERR.puts
      STDERR.puts "[beryl ssh-config] #{count} host(s) caché(s) — #{conf} #{unchanged ? "déjà à jour" : "serait écrit"}" \
                  "#{included ? " ; « #{Beryl::SshConfig::INCLUDE_LINE} » serait ajouté en tête de #{main}" : ""} " \
                  "(dry-run ; --apply pour écrire)."
      return EXIT_OK
    end

    Dir.mkdir_p(ssh_dir, 0o700)
    if unchanged
      STDERR.puts "[beryl ssh-config] #{conf} déjà à jour (#{count} host(s) caché(s))."
    else
      File.write(conf, content, perm: 0o600)
      STDERR.puts "[beryl ssh-config] ✓ #{conf} écrit (#{count} host(s) caché(s))."
    end
    if included
      File.copy(main, "#{main}.beryl-avant") if File.exists?(main)
      File.write(main, included, perm: 0o600)
      STDERR.puts "[beryl ssh-config] ✓ « #{Beryl::SshConfig::INCLUDE_LINE} » ajouté en tête de #{main}" \
                  "#{File.exists?("#{main}.beryl-avant") ? " (ancien : #{main}.beryl-avant)" : ""}."
    end
    EXIT_OK
  end
end
