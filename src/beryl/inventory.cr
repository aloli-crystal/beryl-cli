require "yaml"
require "./ssh"

module Beryl
  # Un hôte cible : nom, paramètres de connexion SSH, hébergeur, recettes.
  class Host
    getter name : String
    getter provider : String?
    getter user : String
    getter port : Int32
    getter identity_file : String?
    getter recipes : Array(String)
    getter variables : Hash(String, YAML::Any)

    # Configuration spécifique au fournisseur, lue depuis le bloc YAML
    # portant le nom du provider (ex. `ovh:` ou `scaleway:`). Permet de
    # porter des identifiants d'API (serviceName OVH, server_id Scaleway,
    # etc.) sans polluer le schéma général. Vide si aucun bloc n'est
    # présent.
    getter provider_config : Hash(String, YAML::Any)

    # Configuration FreeBSD spécifique (bloc `freebsd:` du YAML). `nil` si
    # le bloc est absent. Sert de source d'informations pour `beryl
    # bootstrap` : disques, RAID, users, packages, sudoers, etc. Les
    # flags CLI priment quand ils sont présents (règle :
    # « CLI > YAML > erreur explicite », pas de défaut silencieux).
    getter freebsd_config : FreebsdConfig?

    def initialize(
      @name : String,
      @provider : String? = nil,
      @user : String = "root",
      @port : Int32 = 22,
      @identity_file : String? = nil,
      @recipes : Array(String) = [] of String,
      @variables : Hash(String, YAML::Any) = {} of String => YAML::Any,
      @provider_config : Hash(String, YAML::Any) = {} of String => YAML::Any,
      @freebsd_config : FreebsdConfig? = nil,
    )
    end

    # Hostname à utiliser pour SSH vers cet hôte. Pour un host OVH
    # avec `ovh.service_name` déclaré, on utilise le FQDN OVH (ex.
    # `ns3156789.ip-51-83-6.eu`) qui est toujours résoluble —
    # indépendamment de la présence d'un DNS custom sur le nom logique
    # (`rails01.aloli.fr`) et de la phase (rescue ou installé, l'IP
    # côté hébergeur ne change pas).
    #
    # Fallback sur `@name` pour :
    # - les hosts sans provider (VM locale, autre hébergeur)
    # - les hosts OVH sans `service_name` déclaré
    # - les hosts Scaleway (pas de FQDN équivalent exposé par l'API)
    #
    # Règle Aloli « même comportement pour toutes les actions » : toutes
    # les commandes (scan, bootstrap, apply, rescue, wipe, boot-hd)
    # utilisent cette méthode pour leur connexion SSH, directement ou
    # via `#connection`.
    def ssh_host : String
      if @provider == "ovh"
        if sn = ovh_service_name
          return sn
        end
      end
      @name
    end

    # Vrai si `ssh_host` diffère du nom logique. Utile côté UI pour
    # afficher « rails01.aloli.fr (= ns3156789.ip-51-83-6.eu côté OVH) »
    # dans les logs et garder la traçabilité.
    def ssh_host_is_provider_name? : Bool
      ssh_host != @name
    end

    # Construit une connexion SSH prête à l'emploi. Utilise `ssh_host`
    # comme cible — donc le FQDN OVH pour les hosts OVH, le nom logique
    # partout ailleurs. Unique pour toutes les phases (rescue comme
    # installé).
    def connection : SSH::Connection
      SSH::Connection.new(
        host: ssh_host,
        user: @user,
        port: @port,
        identity_file: @identity_file,
      )
    end

    # Nom du service OVH (`serviceName`, ex. `ns3156789.ip-51-83-6.eu`).
    # Retourne nil si le provider n'est pas `ovh` ou si le champ est absent.
    def ovh_service_name : String?
      return nil unless @provider == "ovh"
      @provider_config["service_name"]?.try(&.as_s)
    end

    # Nom de la clé SSH déclarée dans `/me/sshKey` côté OVH. Utilisée par
    # `prepare_rescue` pour injecter la clé dans le rescue.
    def ovh_ssh_key_name : String?
      return nil unless @provider == "ovh"
      @provider_config["ssh_key_name"]?.try(&.as_s)
    end

    # Zone Scaleway où réside le serveur (ex. `fr-par-2`). Retourne nil si
    # le provider n'est pas `scaleway` ou si le champ est absent.
    def scaleway_zone : String?
      return nil unless @provider == "scaleway"
      @provider_config["zone"]?.try(&.as_s)
    end

    # UUID du serveur Elastic Metal Scaleway. Retourne nil si le provider
    # n'est pas `scaleway` ou si le champ est absent.
    def scaleway_server_id : String?
      return nil unless @provider == "scaleway"
      @provider_config["server_id"]?.try(&.as_s)
    end
  end

  # Inventaire d'hôtes chargé depuis un fichier YAML.
  #
  # Exemple de fichier `inventory.yml` :
  # ```yaml
  # defaults:
  #   user: root
  #   port: 22
  #   identity_file: ~/.ssh/id_ed25519
  #
  # hosts:
  #   web01.aloli.fr:
  #     provider: ovh
  #     recipes:
  #       - core-system
  #       - nginx-crystal-deploy
  # ```
  class Inventory
    class NotFound < Exception; end

    # Paramètres valables pour le bootstrap, optionnellement surchargés dans
    # la section `bootstrap:` au niveau `defaults:` de l'inventaire.
    #
    # ```yaml
    # defaults:
    #   bootstrap:
    #     mfsbsd_image_url: https://depenguin.me/files/mfsbsd-15.0-RELEASE-amd64.iso
    # ```
    class BootstrapDefaults
      getter mfsbsd_image_url : String?

      def initialize(@mfsbsd_image_url : String? = nil)
      end
    end

    getter hosts : Hash(String, Host)
    getter bootstrap_defaults : BootstrapDefaults

    def initialize(@hosts : Hash(String, Host), @bootstrap_defaults : BootstrapDefaults = BootstrapDefaults.new)
    end

    # Charge un inventaire depuis un fichier ou un dossier.
    #
    # * Fichier YAML unique : chemin historique, `from_yaml` direct.
    # * Dossier : convention `groups/*.yml` + `hosts/*.yml`. Chaque hôte
    #   peut déclarer `groups: [group1, group2]` pour hériter des
    #   valeurs déclarées dans `groups/group1.yml`, puis `group2.yml`,
    #   avant ses propres overrides. Merge : les scalaires et listes
    #   sont remplacés par la valeur la plus spécifique (groupes dans
    #   l'ordre, puis host). Les hashes imbriqués sont fusionnés.
    #
    # Détection : si `path` est un dossier, chargement en mode arborescent.
    def self.load(path : String) : Inventory
      if File.directory?(path)
        load_tree(path)
      else
        from_yaml(File.read(path))
      end
    end

    # Chargement arborescent : groups/*.yml + hosts/*.yml. Chaque host
    # hérite des groupes listés dans son champ `groups:` (ordre =
    # priorité croissante), puis ses propres champs s'appliquent en
    # dernier.
    #
    # Convention Aloli : un fichier par host, un fichier par groupe.
    # Plus lisible qu'un gros inventory.yml pour ≥ quelques dizaines de
    # serveurs, diffs git propres par serveur.
    def self.load_tree(root_dir : String) : Inventory
      groups_dir = File.join(root_dir, "groups")
      hosts_dir = File.join(root_dir, "hosts")
      unless File.directory?(hosts_dir)
        raise "inventaire arborescent : dossier 'hosts/' requis dans #{root_dir}"
      end

      groups = {} of String => YAML::Any
      if File.directory?(groups_dir)
        Dir.glob(File.join(groups_dir, "*.yml")).sort.each do |f|
          name = File.basename(f, ".yml")
          groups[name] = YAML.parse(File.read(f))
        end
      end

      bootstrap_defaults = BootstrapDefaults.new
      hosts = {} of String => Host
      Dir.glob(File.join(hosts_dir, "*.yml")).sort.each do |f|
        host_name = File.basename(f, ".yml")
        host_yaml = YAML.parse(File.read(f))
        host_cfg = host_yaml.as_h? || {} of YAML::Any => YAML::Any
        group_names = extract_string_array(host_cfg["groups"]?)
        # Merge : on part vide, on empile les groupes dans l'ordre,
        # puis les champs host. Dernier écrit = gagnant.
        merged = {} of YAML::Any => YAML::Any
        group_names.each do |gn|
          group_yaml = groups[gn]?
          raise "hôte #{host_name} : groupe inconnu `#{gn}` (fichier groups/#{gn}.yml absent)" unless group_yaml
          group_cfg = group_yaml.as_h? || {} of YAML::Any => YAML::Any
          merged = deep_merge_yaml(merged, group_cfg)
        end
        merged = deep_merge_yaml(merged, host_cfg)

        hosts[host_name] = build_host_from_hash(host_name, merged)
      end

      new(hosts, bootstrap_defaults)
    end

    # Deep merge de deux Hash(YAML::Any, YAML::Any) avec règles
    # Aloli-spécifiques pour le bloc `freebsd:`.
    #
    # Règles générales (override gagne) :
    # - Hash imbriqué → récurse
    # - Scalaire → override remplace
    # - Array → override remplace (sauf règles freebsd: ci-dessous)
    #
    # Règles spécifiques au bloc `freebsd:` (feedback Philippe, 22 avril
    # 2026 : « installation standard des utilisateurs et programmes »
    # en groupe, « personnalisée des serveurs » par host) :
    #
    # - `freebsd.packages` → append + dédup (groupe = base, host ajoute)
    # - `freebsd.sudoers`  → append + dédup (même logique)
    # - `freebsd.users`    → merge par `name:` (host user avec même nom
    #                        override groupe user)
    # - `freebsd.disks`    → override (spécifique au host, par nature)
    # - tout le reste      → override
    #
    # `path` suit la position courante dans l'arbre YAML (« freebsd »,
    # « freebsd.packages », etc.) pour que les règles soient localisées.
    private def self.deep_merge_yaml(
      base : Hash(YAML::Any, YAML::Any),
      override : Hash(YAML::Any, YAML::Any),
      path : String = "",
    ) : Hash(YAML::Any, YAML::Any)
      result = base.dup
      override.each do |k, v|
        key_name = k.as_s? || k.to_s
        sub_path = path.empty? ? key_name : "#{path}.#{key_name}"
        existing = result[k]?
        if existing && (eh = existing.as_h?) && (vh = v.as_h?)
          result[k] = YAML::Any.new(deep_merge_yaml(eh, vh, path: sub_path))
        elsif existing && (ea = existing.as_a?) && (va = v.as_a?) && append_array_path?(sub_path)
          result[k] = YAML::Any.new(merge_yaml_arrays(ea, va, merge_by_name: sub_path == "freebsd.users"))
        else
          result[k] = v
        end
      end
      result
    end

    # Vrai quand le chemin YAML est une liste qui doit s'appender au
    # lieu d'être remplacée. Liste volontairement courte et explicite
    # (pas de règle générale « toutes les arrays s'appendent ») pour
    # éviter les surprises sur `disks` par exemple.
    private def self.append_array_path?(path : String) : Bool
      {"freebsd.packages", "freebsd.sudoers", "freebsd.users"}.includes?(path)
    end

    # Fusionne deux arrays YAML :
    # - `merge_by_name: true` → les entrées sont des hashes avec un
    #   champ `name:`. Une entrée override avec le même name remplace
    #   l'entrée base (utile pour `freebsd.users` : un host peut
    #   redéfinir les clés SSH de `admin` sans dupliquer le user).
    # - `merge_by_name: false` → append + dédup par contenu (scalaires
    #   dupliqués entre groupe et host sont repliés).
    private def self.merge_yaml_arrays(
      base : Array(YAML::Any),
      override : Array(YAML::Any),
      merge_by_name : Bool,
    ) : Array(YAML::Any)
      if merge_by_name
        override_names = Set(String).new
        override.each do |entry|
          if (h = entry.as_h?) && (n = h[YAML::Any.new("name")]?.try(&.as_s))
            override_names.add(n)
          end
        end
        kept = base.reject do |entry|
          if (h = entry.as_h?) && (n = h[YAML::Any.new("name")]?.try(&.as_s))
            override_names.includes?(n)
          else
            false
          end
        end
        kept + override
      else
        seen = [] of YAML::Any
        (base + override).each do |item|
          seen << item unless seen.includes?(item)
        end
        seen
      end
    end

    # Construit un Host à partir d'un hash YAML déjà mergé (groupes +
    # fichier host). Partage la logique avec `from_yaml` mais travaille
    # sur un hash plutôt que sur le format `defaults:` + `hosts:`.
    private def self.build_host_from_hash(
      name : String,
      cfg : Hash(YAML::Any, YAML::Any),
    ) : Host
      provider = cfg["provider"]?.try(&.as_s)
      provider_config = if provider
                          extract_string_keyed_hash(cfg[provider]?)
                        else
                          {} of String => YAML::Any
                        end

      Host.new(
        name: name,
        provider: provider,
        user: cfg["user"]?.try(&.as_s) || "root",
        port: cfg["port"]?.try(&.as_i) || 22,
        identity_file: cfg["identity_file"]?.try(&.as_s),
        recipes: extract_string_array(cfg["recipes"]?),
        variables: extract_string_keyed_hash(cfg["variables"]?),
        provider_config: provider_config,
        freebsd_config: FreebsdConfig.from_yaml(cfg["freebsd"]?),
      )
    end

    def self.from_yaml(source : String) : Inventory
      root = YAML.parse(source).as_h? || raise "inventaire invalide : racine non-hash"

      defaults = root["defaults"]?.try(&.as_h) || empty_hash
      default_user = defaults["user"]?.try(&.as_s) || "root"
      default_port = defaults["port"]?.try(&.as_i) || 22
      default_identity = defaults["identity_file"]?.try(&.as_s)

      bootstrap_section = defaults["bootstrap"]?.try(&.as_h) || empty_hash
      bootstrap_defaults = BootstrapDefaults.new(
        mfsbsd_image_url: bootstrap_section["mfsbsd_image_url"]?.try(&.as_s),
      )

      hosts_any = root["hosts"]?.try(&.as_h) || empty_hash

      hosts = {} of String => Host
      hosts_any.each do |name_any, cfg_any|
        name = name_any.as_s
        cfg = cfg_any.as_h? || empty_hash
        provider = cfg["provider"]?.try(&.as_s)

        # Bloc spécifique au provider (ex. sous la clé `ovh:` ou
        # `scaleway:`). Les identifiants d'API y vivent pour éviter
        # d'encombrer le schéma général.
        provider_config = if provider
                            extract_string_keyed_hash(cfg[provider]?)
                          else
                            {} of String => YAML::Any
                          end

        hosts[name] = Host.new(
          name: name,
          provider: provider,
          user: cfg["user"]?.try(&.as_s) || default_user,
          port: cfg["port"]?.try(&.as_i) || default_port,
          identity_file: cfg["identity_file"]?.try(&.as_s) || default_identity,
          recipes: extract_string_array(cfg["recipes"]?),
          variables: extract_string_keyed_hash(cfg["variables"]?),
          provider_config: provider_config,
          freebsd_config: FreebsdConfig.from_yaml(cfg["freebsd"]?),
        )
      end

      new(hosts, bootstrap_defaults)
    end

    def find?(name : String) : Host?
      @hosts[name]?
    end

    def find(name : String) : Host
      @hosts[name]? || raise NotFound.new("hôte inconnu dans l'inventaire : #{name}")
    end

    def names : Array(String)
      @hosts.keys
    end

    def size : Int32
      @hosts.size
    end

    private def self.empty_hash : Hash(YAML::Any, YAML::Any)
      {} of YAML::Any => YAML::Any
    end

    private def self.extract_string_array(value : YAML::Any?) : Array(String)
      return [] of String unless value
      value.as_a.map(&.as_s)
    end

    private def self.extract_string_keyed_hash(value : YAML::Any?) : Hash(String, YAML::Any)
      return {} of String => YAML::Any unless value
      result = {} of String => YAML::Any
      value.as_h.each do |k, v|
        result[k.as_s] = v
      end
      result
    end
  end
end
