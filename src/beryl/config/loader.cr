require "yaml"

module Beryl::Config
  # Lit l'arborescence `~/.beryl/` et construit un `Root` exploitable.
  #
  # Tolère les fichiers/dossiers absents : un domaine peut avoir un
  # `<domaine>.yml` mais pas de dossier (pas encore de host), un
  # `_default.yml` peut manquer (utilise un hash vide), etc.
  #
  # Lève si la racine est un fichier (pas un dossier) ou si un YAML
  # est syntaxiquement invalide.
  module Loader
    # Charge une arborescence à partir du chemin racine (typiquement
    # `~/.beryl/`).
    def self.load(root_path : String) : {defaults: Hash(YAML::Any, YAML::Any), domains: Hash(String, Domain), env_file: EnvFile}
      expanded = File.expand_path(root_path, home: true)
      unless File.directory?(expanded)
        return {
          defaults: empty_hash,
          domains:  {} of String => Domain,
          env_file: EnvFile.new(File.join(expanded, ".env.yml"), {} of String => Hash(String, String)),
        }
      end

      defaults = load_defaults(File.join(expanded, "_default.yml"))
      env_file = EnvFile.load(File.join(expanded, ".env.yml"))
      domains = load_domains(expanded)

      {defaults: defaults, domains: domains, env_file: env_file}
    end

    # Charge `_default.yml` ou retourne un hash vide s'il n'existe pas.
    def self.load_defaults(path : String) : Hash(YAML::Any, YAML::Any)
      return empty_hash unless File.exists?(path)
      parsed = YAML.parse(File.read(path))
      parsed.as_h? || empty_hash
    end

    # Scanne le dossier racine, identifie les domaines (fichiers
    # `<domaine>.yml` sauf `_default.yml` et `.env.yml`) et charge
    # leurs hosts + groupes.
    def self.load_domains(root : String) : Hash(String, Domain)
      domains = {} of String => Domain

      Dir.glob(File.join(root, "*.yml")).sort.each do |path|
        basename = File.basename(path, ".yml")
        # Ignore les fichiers spéciaux.
        next if basename.starts_with?("_")
        next if basename == ".env"
        next if basename.starts_with?(".") # caché, on ignore

        domain = load_domain(root, basename, path)
        domains[basename] = domain
      end

      domains
    end

    # Charge un domaine : son `.yml` + son dossier (hosts directs +
    # groupes + hosts dans groupes).
    def self.load_domain(root : String, domain_name : String, yml_path : String) : Domain
      raw = parse_yaml_hash(yml_path)
      domain_dir = File.join(root, domain_name)

      direct_hosts = {} of String => HostNode
      groups = {} of String => Group

      if File.directory?(domain_dir)
        direct_hosts, groups = load_domain_contents(domain_dir)
      end

      Domain.new(
        name: domain_name,
        raw: raw,
        direct_hosts: direct_hosts,
        groups: groups,
        source_path: yml_path,
      )
    end

    # Scanne le dossier d'un domaine :
    # - Chaque `.yml` à la racine du dossier est UN host direct
    #   (sauf fichiers spéciaux `_*.yml`).
    # - Chaque sous-dossier est un groupe. Son `.yml` de définition
    #   est le fichier `<groupe>.yml` à côté du dossier.
    #   Convention Ruby/Crystal : fichier+dossier de même nom.
    def self.load_domain_contents(domain_dir : String) : {Hash(String, HostNode), Hash(String, Group)}
      direct_hosts = {} of String => HostNode
      groups = {} of String => Group

      # Fichiers au niveau domain_dir : potentiels hosts directs OU
      # fichiers de définition de groupe (si le sous-dossier existe).
      entries = Dir.children(domain_dir).sort
      yml_files = entries.select(&.ends_with?(".yml"))
      sub_dirs = entries.select { |e| File.directory?(File.join(domain_dir, e)) }

      # Pour chaque sous-dossier → groupe.
      sub_dirs.each do |group_dir_name|
        group_yml = "#{group_dir_name}.yml"
        group_yml_path = yml_files.includes?(group_yml) ? File.join(domain_dir, group_yml) : nil

        group_hosts = {} of String => HostNode
        Dir.glob(File.join(domain_dir, group_dir_name, "*.yml")).sort.each do |host_yml|
          host_name = File.basename(host_yml, ".yml")
          next if host_name.starts_with?("_")
          group_hosts[host_name] = HostNode.new(
            name: host_name,
            raw: parse_yaml_hash(host_yml),
            source_path: host_yml,
          )
        end

        groups[group_dir_name] = Group.new(
          name: group_dir_name,
          raw: group_yml_path ? parse_yaml_hash(group_yml_path) : empty_hash,
          hosts: group_hosts,
          source_path: group_yml_path,
        )
      end

      # Fichiers `.yml` qui ne sont PAS des définitions de groupes :
      # des hosts directs.
      yml_files.each do |yml|
        host_name = File.basename(yml, ".yml")
        next if host_name.starts_with?("_")
        # Si un dossier du même nom existe, c'est un fichier de groupe
        # déjà traité ci-dessus.
        next if sub_dirs.includes?(host_name)

        direct_hosts[host_name] = HostNode.new(
          name: host_name,
          raw: parse_yaml_hash(File.join(domain_dir, yml)),
          source_path: File.join(domain_dir, yml),
        )
      end

      {direct_hosts, groups}
    end

    # Parse un fichier YAML attendu à la racine comme un hash.
    # Retourne un hash vide si le fichier est vide ou contient
    # uniquement des commentaires.
    def self.parse_yaml_hash(path : String) : Hash(YAML::Any, YAML::Any)
      return empty_hash unless File.exists?(path)
      content = File.read(path)
      return empty_hash if content.strip.empty?
      parsed = YAML.parse(content)
      parsed.as_h? || empty_hash
    rescue ex : YAML::ParseException
      raise "YAML invalide dans #{path} : #{ex.message}"
    end

    private def self.empty_hash : Hash(YAML::Any, YAML::Any)
      {} of YAML::Any => YAML::Any
    end
  end
end
