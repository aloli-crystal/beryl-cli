require "yaml"

module Beryl::Config
  # Lit l'arborescence `~/.beryl/` et construit un `Root` exploitable.
  #
  # Nouvelle arborescence (ADR-014) :
  #
  #   ~/.beryl/
  #   ├── _default.yml
  #   ├── .env.yml
  #   ├── <société>/
  #   │   ├── _account.yml            # optionnel : métadonnées société
  #   │   ├── <domaine>.yml
  #   │   ├── <domaine>/              # hosts directs + groupes
  #   │   │   ├── <host>.yml
  #   │   │   └── <groupe>/
  #   │   │       ├── <host>.yml
  #   │   │       └── ...
  #   │   └── ...
  #   └── <autre société>/
  #
  # Tolère les fichiers/dossiers absents : une société peut avoir un
  # seul domaine sans sous-dossier d'hosts, un `_default.yml` peut
  # manquer, etc. Seul `~/.beryl/` lui-même peut être absent (on
  # retourne un Root vide).
  module Loader
    # Alias pour le tuple retourné par `.load`.
    alias Result = NamedTuple(
      defaults: Hash(YAML::Any, YAML::Any),
      accounts: Hash(String, Account),
      env_file: EnvFile,
    )

    # Charge une arborescence à partir du chemin racine (typiquement
    # `~/.beryl/`). Retourne defaults + accounts + env_file.
    def self.load(root_path : String) : Result
      expanded = File.expand_path(root_path, home: true)
      unless File.directory?(expanded)
        return {
          defaults: empty_hash,
          accounts: {} of String => Account,
          env_file: EnvFile.new(File.join(expanded, ".env.yml"), EnvFile::Data.new),
        }
      end

      defaults = load_defaults(File.join(expanded, "_default.yml"))
      env_file = EnvFile.load(File.join(expanded, ".env.yml"))
      accounts = load_accounts(expanded)

      {defaults: defaults, accounts: accounts, env_file: env_file}
    end

    # Charge `_default.yml` ou retourne un hash vide s'il n'existe pas.
    def self.load_defaults(path : String) : Hash(YAML::Any, YAML::Any)
      return empty_hash unless File.exists?(path)
      parsed = YAML.parse(File.read(path))
      parsed.as_h? || empty_hash
    end

    # Scanne le dossier racine et charge les sociétés.
    # Une société = un sous-dossier du root, **sauf** les dossiers
    # réservés (nom commençant par `_`, nom caché `.`).
    def self.load_accounts(root : String) : Hash(String, Account)
      accounts = {} of String => Account
      Dir.children(root).sort.each do |entry|
        next if entry.starts_with?("_")
        next if entry.starts_with?(".")
        path = File.join(root, entry)
        next unless File.directory?(path)
        accounts[entry] = load_account(entry, path)
      end
      accounts
    end

    # Charge une société : son `_account.yml` éventuel + ses domaines.
    def self.load_account(name : String, path : String) : Account
      metadata_path = File.join(path, "_account.yml")
      metadata = File.exists?(metadata_path) ? parse_yaml_hash(metadata_path) : empty_hash
      domains = load_domains(path)
      Account.new(name: name, path: path, metadata: metadata, domains: domains)
    end

    # Scanne le dossier d'une société pour identifier les domaines
    # (fichiers `<domaine>.yml` sauf `_*.yml` et fichiers cachés).
    def self.load_domains(account_dir : String) : Hash(String, Domain)
      domains = {} of String => Domain

      Dir.glob(File.join(account_dir, "*.yml")).sort.each do |yml_path|
        basename = File.basename(yml_path, ".yml")
        next if basename.starts_with?("_")
        next if basename.starts_with?(".")

        domain = load_domain(account_dir, basename, yml_path)
        domains[basename] = domain
      end

      domains
    end

    # Charge un domaine : son `.yml` + son dossier (hosts directs +
    # groupes + hosts dans groupes).
    def self.load_domain(account_dir : String, domain_name : String, yml_path : String) : Domain
      raw = parse_yaml_hash(yml_path)
      domain_dir = File.join(account_dir, domain_name)

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
    def self.load_domain_contents(domain_dir : String) : {Hash(String, HostNode), Hash(String, Group)}
      direct_hosts = {} of String => HostNode
      groups = {} of String => Group

      entries = Dir.children(domain_dir).sort
      yml_files = entries.select(&.ends_with?(".yml"))
      sub_dirs = entries.select { |e| File.directory?(File.join(domain_dir, e)) }

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

      yml_files.each do |yml|
        host_name = File.basename(yml, ".yml")
        next if host_name.starts_with?("_")
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
