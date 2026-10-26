require "yaml"

module Beryl::Config
  # Lit l'arborescence `~/.config/beryl/` et construit un `Root` exploitable.
  #
  # Arborescence (ADR-014) : le type d'un fichier est dans son nom
  # (`*.host.yml`), celui d'un dossier dans sa PLACE — un dossier sous une
  # société est un domaine (nom à point), un dossier sous un domaine est un
  # GROUPE (nom sans point). Chaque niveau a ses réglages communs dans son
  # `_defaults.yml`.
  #
  #   ~/.config/beryl/
  #   ├── _default.yml
  #   ├── .env.yml
  #   ├── <société>/
  #   │   ├── _account.yml            # optionnel : métadonnées société
  #   │   ├── .env.toml.age           # optionnel : coffre credentials chiffré
  #   │   ├── <domaine>.domain.yml
  #   │   ├── <domaine>/              # hosts directs + groupes
  #   │   │   ├── <host>.host.yml
  #   │   │   └── <groupe>/           # GROUPE (nom sans point)
  #   │   │       ├── _defaults.yml   # optionnel : réglages communs du groupe
  #   │   │       ├── <host>.host.yml
  #   │   │       └── ...
  #   │   ├── <sous.domaine>/         # un sous-domaine est À CÔTÉ, jamais dedans
  #   │   └── ...
  #   └── <autre société>/
  #
  # Règle de typage :
  #   - `*.domain.yml` → domaine ;
  #   - `*.host.yml`   → host (direct, ou membre d'un groupe) ;
  #   - `<groupe>/`    → groupe (dossier sans point sous un domaine) ;
  #   - `*.recipe.yml` → recette (lue par `beryl sync`, ignorée ici).
  #
  # Tolère les fichiers/dossiers absents : une société peut avoir un
  # seul domaine sans sous-dossier d'hosts, un `_default.yml` peut
  # manquer, etc. Seul `~/.config/beryl/` lui-même peut être absent (on
  # retourne un Root vide).
  #
  # Suffixes typés (un seul endroit où ils sont déclarés).
  DOMAIN_SUFFIX = ".domain.yml"
  HOST_SUFFIX   = ".host.yml"
  # Ancienne déclaration de groupe, REFUSÉE (remplacée par `<groupe>/_defaults.yml`).
  GROUP_SUFFIX = ".group.yml"

  module Loader
    # Alias pour le tuple retourné par `.load`.
    alias Result = NamedTuple(
      defaults: Hash(YAML::Any, YAML::Any),
      accounts: Hash(String, Account),
      env_file: EnvFile,
    )

    # Charge une arborescence à partir du chemin racine (typiquement
    # `~/.config/beryl/`). Retourne defaults + accounts + env_file.
    def self.load(root_path : String) : Result
      expanded = File.expand_path(root_path, home: true)
      unless File.directory?(expanded)
        return {
          defaults: empty_hash,
          accounts: {} of String => Account,
          env_file: EnvFile.new(File.join(expanded, ".env.yml"), EnvFile::Data.new),
        }
      end

      defaults = load_defaults(defaults_path(expanded))
      env_file = EnvFile.load(File.join(expanded, ".env.yml"))
      accounts = load_accounts(expanded)

      # Pour chaque société qui dispose d'un coffre chiffré
      # `<société>/.env.toml.age`, on **remplace** la section
      # homonyme du `.env.yml` racine par le contenu déchiffré du
      # coffre. C'est le coffre qui fait autorité : la migration
      # vers les coffres est progressive (cf. `beryl env migrate`)
      # et tant qu'une société n'a pas migré, son fragment du
      # `.env.yml` continue d'être lu sans changement.
      accounts.each do |name, account|
        vault_path = File.join(account.path, EnvFile::VAULT_FILENAME)
        next unless File.exists?(vault_path)
        providers = EnvFile.load_vault(vault_path)
        env_file.set_account(name, providers)
      end

      {defaults: defaults, accounts: accounts, env_file: env_file}
    end

    # Chemin du fichier de défauts d'un dossier : `_defaults.yml` (nouveau,
    # PLURIEL — un fichier contient PLUSIEURS défauts) s'il existe, sinon
    # `_default.yml` (legacy). Permet le renommage progressif.
    def self.defaults_path(dir : String) : String
      plural = File.join(dir, "_defaults.yml")
      File.exists?(plural) ? plural : File.join(dir, "_default.yml")
    end

    # Charge le fichier de défauts ou retourne un hash vide s'il n'existe pas.
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

    # Charge une société : son défaut + ses domaines. Le défaut société est
    # `_default.yml` (nouvelle convention « _default.yml par dossier »),
    # sinon `_account.yml` (ancien nom, rétro-compat).
    def self.load_account(name : String, path : String) : Account
      default_path = defaults_path(path)
      legacy_path = File.join(path, "_account.yml")
      meta_path = File.exists?(default_path) ? default_path : legacy_path
      metadata = File.exists?(meta_path) ? parse_yaml_hash(meta_path) : empty_hash
      domains = load_domains(path)
      Account.new(name: name, path: path, metadata: metadata, domains: domains)
    end

    # Domaines d'une société, découverts par NOM = union :
    #   * des SOUS-DOSSIERS `<domaine>/` (nouvelle convention : le dossier
    #     EST le domaine, son défaut est `<domaine>/_default.yml`) ;
    #   * des fichiers `<domaine>.domain.yml` (ancien, rétro-compat).
    # Hors `_*`, fichiers/dossiers cachés, et sous-dossiers SANS point (un
    # domaine est un FQDN ; `recipes`/`info` sont des dossiers de service).
    def self.load_domains(account_dir : String) : Hash(String, Domain)
      names = Set(String).new
      Dir.children(account_dir).each do |entry|
        next if entry.starts_with?("_") || entry.starts_with?(".")
        # Un domaine est un FQDN → il CONTIENT un point (`example.net`). Les
        # sous-dossiers de SERVICE (`recipes`, `info`, futurs…) n'en ont pas
        # et sont donc ignorés — sans liste d'exceptions à maintenir.
        next unless entry.includes?('.')
        names << entry if File.directory?(File.join(account_dir, entry))
      end
      Dir.glob(File.join(account_dir, "*#{DOMAIN_SUFFIX}")).each do |yml_path|
        basename = File.basename(yml_path)
        next if basename.starts_with?("_") || basename.starts_with?(".")
        names << basename.rchop(DOMAIN_SUFFIX)
      end

      domains = {} of String => Domain
      names.to_a.sort.each { |name| domains[name] = load_domain(account_dir, name) }
      domains
    end

    # Charge un domaine `name` : son raw depuis `<name>/_default.yml`
    # (nouveau) sinon `<name>.domain.yml` (ancien) ; ses hosts/groupes
    # depuis le dossier `<name>/`.
    def self.load_domain(account_dir : String, name : String) : Domain
      domain_dir = File.join(account_dir, name)
      default_yml = defaults_path(domain_dir)
      legacy_yml = File.join(account_dir, "#{name}#{DOMAIN_SUFFIX}")

      source_path, raw =
        if File.exists?(default_yml)
          {default_yml, parse_yaml_hash(default_yml)}
        elsif File.exists?(legacy_yml)
          {legacy_yml, parse_yaml_hash(legacy_yml)}
        else
          {default_yml, empty_hash}
        end

      direct_hosts = {} of String => HostNode
      groups = {} of String => Group
      direct_hosts, groups = load_domain_contents(domain_dir) if File.directory?(domain_dir)

      Domain.new(
        name: name,
        raw: raw,
        direct_hosts: direct_hosts,
        groups: groups,
        source_path: source_path,
      )
    end

    # Scanne le dossier d'un domaine :
    # - `*.host.yml` à la racine = host direct ;
    # - chaque SOUS-DOSSIER = un groupe (réglages : `<groupe>/_defaults.yml`,
    #   membres : ses `*.host.yml`) ;
    # - refusés, avec la correction à faire : un sous-dossier à point (un
    #   sous-domaine se range À CÔTÉ de son parent), un groupe du nom d'un
    #   host du domaine, un ancien `<groupe>.group.yml`.
    def self.load_domain_contents(domain_dir : String) : {Hash(String, HostNode), Hash(String, Group)}
      direct_hosts = {} of String => HostNode
      groups = {} of String => Group

      entries = Dir.children(domain_dir).sort

      # Hosts directs.
      entries.select(&.ends_with?(HOST_SUFFIX)).each do |file|
        name = File.basename(file).rchop(HOST_SUFFIX)
        next if name.starts_with?("_")
        path = File.join(domain_dir, file)
        direct_hosts[name] = HostNode.new(
          name: name,
          raw: parse_yaml_hash(path),
          source_path: path,
        )
      end

      if legacy = entries.find(&.ends_with?(GROUP_SUFFIX))
        group = legacy.rchop(GROUP_SUFFIX)
        raise "#{File.join(domain_dir, legacy)} : ancienne déclaration de groupe. Un dossier sous un domaine EST un groupe ; " \
              "ses réglages communs vont dans #{group}/_defaults.yml (déplacez ce fichier)."
      end

      entries.each do |entry|
        next if entry.starts_with?("_") || entry.starts_with?(".")
        dir = File.join(domain_dir, entry)
        next unless File.directory?(dir)
        if entry.includes?('.')
          raise "dossier « #{entry} » dans #{File.basename(domain_dir)}/ : un nom à point est un domaine. Un sous-domaine " \
                "se range à la racine de la société, à côté de son domaine parent (<société>/#{entry}/), pas dedans."
        end
        if direct_hosts.has_key?(entry)
          raise "groupe « #{entry} » (#{dir}) : un host du domaine porte déjà ce nom (#{entry}#{HOST_SUFFIX}) — renommez le groupe."
        end
        groups[entry] = load_group(domain_dir, entry)
      end

      {direct_hosts, groups}
    end

    # Charge un groupe : ses réglages `<groupe>/_defaults.yml` (ou
    # `_default.yml` ; optionnel) + ses hosts (`<groupe>/*.host.yml`).
    def self.load_group(domain_dir : String, group_name : String) : Group
      group_dir = File.join(domain_dir, group_name)
      group_hosts = {} of String => HostNode
      Dir.glob(File.join(group_dir, "*#{HOST_SUFFIX}")).sort.each do |host_yml|
        host_name = File.basename(host_yml).rchop(HOST_SUFFIX)
        next if host_name.starts_with?("_")
        group_hosts[host_name] = HostNode.new(
          name: host_name,
          raw: parse_yaml_hash(host_yml),
          source_path: host_yml,
        )
      end
      defaults = defaults_path(group_dir)
      Group.new(
        name: group_name,
        raw: parse_yaml_hash(defaults),
        hosts: group_hosts,
        source_path: File.exists?(defaults) ? defaults : nil,
      )
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
