require "../cli/credentials"

module Beryl::Providers
  # Provider OVHcloud pour beryl. Encapsule la détection des credentials
  # (via `Beryl::CLI::Credentials.ovh_client`) et le listing des clés
  # SSH enregistrées dans le compte.
  class Ovh < Beryl::Provider
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
      client = Beryl::CLI::Credentials.ovh_client
      names = client.ssh_keys.list
      names.map do |name|
        # L'API OVH oblige un GET supplémentaire par clé pour
        # récupérer le contenu. Coûteux si beaucoup de clés, mais
        # simple et suffisant pour le volume typique (1 à 5 clés).
        full = client.ssh_keys.get(name)
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
  end
end
