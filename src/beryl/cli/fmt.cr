require "option_parser"
require "yaml-tidy"

module Beryl::CLI
  # `beryl fmt [host|société|domaine] [--check]` : normalise les fichiers de
  # config beryl — `*.host.yml`, `_default.yml`, `*.domain.yml`, `*.group.yml`,
  # `_account.yml` : clés triées alpha (récursif), commentaires préservés ; un
  # `*.host.yml` reçoit en plus son FQDN en 1ʳᵉ ligne.
  #
  # NE TOUCHE PAS aux secrets (`.env*`, `*.sample`). N'a PAS besoin du coffre :
  # c'est de la lecture/écriture de fichiers, aucune résolution de config.
  module Fmt
    EXIT_OK = 0

    CONFIG_BASENAMES = {"_defaults.yml", "_default.yml", "_account.yml"}
    CONFIG_SUFFIXES  = {".host.yml", ".domain.yml", ".group.yml"}

    def self.run(config_root : String, args : Array(String)) : Int32
      check = false
      positional = [] of String
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl fmt [host|société|domaine] [--check]"
        p.on("--check", "Liste les fichiers à normaliser SANS écrire") { check = true }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      files = config_files(config_root)
      if scope = positional.first?
        files = files.select { |f| in_scope?(f, config_root, scope) }
      end

      changed = 0
      files.sort.each do |path|
        before = File.read(path)
        after = YamlTidy.tidy(before, header: host_fqdn(path))
        next if before == after
        changed += 1
        label = path.lchop("#{config_root}/")
        if check
          puts "≠ #{label}"
        else
          File.write(path, after)
          puts "✓ #{label}"
        end
      end

      total = files.size
      if changed.zero?
        puts "Tout est déjà normalisé (#{total} fichier(s))."
      elsif check
        puts "#{changed}/#{total} fichier(s) à normaliser — `beryl fmt #{positional.first? || ""}`.".squeeze(' ')
      else
        puts "#{changed}/#{total} fichier(s) normalisé(s). Relisez `git diff` avant de committer."
      end
      EXIT_OK
    end

    # Fichiers de config beryl sous config_root — PAS les secrets (`.env*`).
    def self.config_files(config_root : String) : Array(String)
      Dir.glob(File.join(config_root, "**", "*.yml")).select do |p|
        base = File.basename(p)
        next false if base.starts_with?(".env") || base.ends_with?(".sample")
        CONFIG_BASENAMES.includes?(base) || CONFIG_SUFFIXES.any? { |s| base.ends_with?(s) }
      end
    end

    # FQDN d'un `*.host.yml` (depuis le chemin : `<short>.host.yml` sous le
    # dossier `<domaine>/`). nil pour les fichiers structurels (pas d'en-tête FQDN).
    def self.host_fqdn(path : String) : String?
      base = File.basename(path)
      return nil unless base.ends_with?(".host.yml")
      "#{base.rchop(".host.yml")}.#{File.basename(File.dirname(path))}"
    end

    # Le fichier est-il dans le périmètre (société / domaine / host court / fqdn) ?
    def self.in_scope?(path : String, config_root : String, scope : String) : Bool
      parts = path.lchop("#{config_root}/").split("/")
      tokens = Set(String).new
      parts[0...-1].each { |d| tokens << d } # société + domaine (dossiers)
      base = parts[-1]
      if base.ends_with?(".host.yml")
        tokens << base.rchop(".host.yml")
        host_fqdn(path).try { |f| tokens << f }
      elsif base.ends_with?(".domain.yml")
        tokens << base.rchop(".domain.yml")
      end
      tokens.includes?(scope)
    end
  end
end
