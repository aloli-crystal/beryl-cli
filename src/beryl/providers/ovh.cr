require "../cli/credentials"

module Beryl::Providers
  # Provider OVHcloud pour beryl. Encapsule la détection des credentials
  # (via `Beryl::CLI::Credentials.ovh_client`) et le listing des clés
  # SSH enregistrées dans le compte.
  #
  # Le client OVH est injectable via le constructeur pour les tests.
  # En production, on laisse le défaut `nil` et `client` résout à
  # la demande via `Credentials.ovh_client`.
  class Ovh < Beryl::Provider
    def initialize(@injected_client : OvhApi::Client? = nil)
    end

    private def client : OvhApi::Client
      @injected_client || Beryl::CLI::Credentials.ovh_client
    end

    def name : String
      "ovh"
    end

    def display_name : String
      "OVHcloud"
    end

    def available? : Bool
      ENV["OVH_APPLICATION_KEY"]? && ENV["OVH_APPLICATION_SECRET"]? && ENV["OVH_CONSUMER_KEY"]? ? true : false
    end

    def list_ssh_keys : Array(Beryl::SshKeyInfo)
      c = client
      names = c.ssh_keys.list
      names.map do |name|
        # L'API OVH oblige un GET supplémentaire par clé pour
        # récupérer le contenu. Coûteux si beaucoup de clés, mais
        # simple et suffisant pour le volume typique (1 à 5 clés).
        full = c.ssh_keys.get(name)
        Beryl::SshKeyInfo.new(id: name, name: name, public_key: full.key)
      end
    end

    # Côté YAML, OVH attend `ovh.ssh_key_name: <label>`. Le label est
    # directement le `keyName` OVH. Consommé par `beryl rescue` qui
    # passe cette valeur à `client.dedicated_servers.prepare_rescue`.
    def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
      result = {} of String => String | Array(String)
      result["ssh_key_name"] = key_id
      result
    end

    def credentials_env_vars : Array(Beryl::EnvVarSpec)
      [
        Beryl::EnvVarSpec.new(
          name: "OVH_APPLICATION_KEY",
          description: "Clé applicative (générée à l'URL d'aide)",
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_APPLICATION_SECRET",
          description: "Secret applicatif (donné une fois à la génération)",
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_CONSUMER_KEY",
          description: "Consumer key (token utilisateur, validé dans le navigateur)",
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_ENDPOINT",
          description: "Datacenter (eu|ca|us|kimsufi_eu|kimsufi_ca|soyoustart_eu|soyoustart_ca)",
          optional: true,
          default: "eu",
        ),
      ]
    end

    def credentials_help_url : String
      "https://eu.api.ovh.com/createToken/ (créez une application si vous n'en avez pas : https://eu.api.ovh.com/createApp/)"
    end

    def owns?(host_name : String) : Bool
      # Quand un client est injecté (cas test), on l'utilise sans
      # vérifier `available?` (les env vars ne sont pas forcément
      # posées en spec).
      return false unless @injected_client || available?
      client.dedicated_servers.list.includes?(host_name)
    rescue
      false
    end
  end
end
