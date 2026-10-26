require "option_parser"
require "./option_errors"
require "../config"
require "../ssh_config"

# Sous-commande `beryl ssh-config` : écrit un fichier par société,
# `~/.ssh/beryl--<société>.conf`, avec TOUS ses hosts (FQDN et nom court ;
# hosts cachés derrière le vRack par leurs bastions, avec replis — voir
# `Beryl::SshConfig`), et les inclut en tête de `~/.ssh/config`. Toujours
# tout le parc : chaque fichier est regénéré en entier. L'ancien fichier
# unique `~/.ssh/beryl.conf` (0.6.124) est retiré. Essai à blanc par défaut
# (contenu affiché) ; `--apply` écrit.
module Beryl::CLI::SshConfig
  EXIT_OK    = 0
  EXIT_USAGE = 1

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = true
    ssh_dir = File.join(Path.home.to_s, ".ssh")

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl ssh-config [--apply]\n\n" \
                 "Écrit ~/.ssh/#{Beryl::SshConfig::FILE_PREFIX}<société>.conf : tous les hosts gérés par beryl, par leur\n" \
                 "FQDN et leur nom court ; un host caché derrière le vRack passe par son bastion préféré, puis\n" \
                 "les autres. Les inclut en tête de ~/.ssh/config (« #{Beryl::SshConfig::INCLUDE_LINE} »).\n" \
                 "Un host (ou un groupe, dans son _defaults.yml) en `ssh_config: false` est écarté.\n"
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
    files = Beryl::SshConfig.render(hosts)
    counts = hosts.select(&.ssh_config?).group_by(&.account_name).transform_values(&.size)
    skipped = hosts.reject(&.ssh_config?).group_by(&.account_name).transform_values(&.size)
    main = File.join(ssh_dir, "config")
    current = File.exists?(main) ? File.read(main) : ""
    included = Beryl::SshConfig.with_include(current)
    legacy = File.join(ssh_dir, Beryl::SshConfig::LEGACY_FILE)
    remove_legacy = File.exists?(legacy) && Beryl::SshConfig.legacy_generated?(File.read(legacy))

    if dry_run
      files.each do |account, content|
        puts "──── #{File.join(ssh_dir, Beryl::SshConfig.file_name(account))} ────"
        puts content
        puts
      end
    else
      Dir.mkdir_p(ssh_dir, 0o700)
    end
    verb = dry_run ? "serait" : "✓"
    files.each do |account, content|
      path = File.join(ssh_dir, Beryl::SshConfig.file_name(account))
      tally = "#{counts[account]} host(s)#{(n = skipped[account]?) ? ", #{n} écarté(s) par ssh_config: false" : ""}"
      if File.exists?(path) && File.read(path) == content
        STDERR.puts "[beryl ssh-config] #{path} déjà à jour (#{tally})."
        next
      end
      File.write(path, content, perm: 0o600) unless dry_run
      STDERR.puts "[beryl ssh-config] #{dry_run ? "#{path} serait écrit" : "✓ #{path} écrit"} (#{tally})."
    end
    if included
      unless dry_run
        File.copy(main, "#{main}.beryl-avant") if File.exists?(main)
        File.write(main, included, perm: 0o600)
      end
      STDERR.puts "[beryl ssh-config] #{verb} #{main} : « #{Beryl::SshConfig::INCLUDE_LINE} » en tête" \
                  "#{current.includes?(Beryl::SshConfig::LEGACY_INCLUDE) ? ", à la place de « #{Beryl::SshConfig::LEGACY_INCLUDE} »" : ""}" \
                  "#{dry_run ? "" : " (ancien : #{main}.beryl-avant)"}."
    end
    if remove_legacy
      File.delete(legacy) unless dry_run
      STDERR.puts "[beryl ssh-config] #{verb} #{legacy} retiré (remplacé par les fichiers par société)."
    end
    STDERR.puts "[beryl ssh-config] dry-run ; --apply pour écrire." if dry_run
    EXIT_OK
  end
end
