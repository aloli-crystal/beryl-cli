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

    def initialize(
      @name : String,
      @provider : String? = nil,
      @user : String = "root",
      @port : Int32 = 22,
      @identity_file : String? = nil,
      @recipes : Array(String) = [] of String,
      @variables : Hash(String, YAML::Any) = {} of String => YAML::Any,
    )
    end

    # Construit une connexion SSH prête à l'emploi vers cet hôte.
    def connection : SSH::Connection
      SSH::Connection.new(
        host: @name,
        user: @user,
        port: @port,
        identity_file: @identity_file,
      )
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

    def self.load(path : String) : Inventory
      from_yaml(File.read(path))
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

        hosts[name] = Host.new(
          name: name,
          provider: cfg["provider"]?.try(&.as_s),
          user: cfg["user"]?.try(&.as_s) || default_user,
          port: cfg["port"]?.try(&.as_i) || default_port,
          identity_file: cfg["identity_file"]?.try(&.as_s) || default_identity,
          recipes: extract_string_array(cfg["recipes"]?),
          variables: extract_string_keyed_hash(cfg["variables"]?),
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
