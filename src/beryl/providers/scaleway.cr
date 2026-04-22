require "../cli/credentials"

module Beryl::Providers
  # Provider Scaleway Elastic Metal pour beryl. Les clés SSH sont
  # gérées au niveau IAM (pas par projet) et identifiées par un UUID +
  # un nom humain — on expose les noms dans `list_ssh_keys` mais on
  # écrit les UUIDs dans le YAML (c'est ce que consomme l'API `create`).
  class Scaleway < Beryl::Provider
    def name : String
      "scaleway"
    end

    def display_name : String
      "Scaleway Elastic Metal"
    end

    def available? : Bool
      sk = ENV["SCW_SECRET_KEY"]?
      !sk.nil? && !sk.empty?
    end

    def list_ssh_keys : Array(Beryl::SshKeyInfo)
      Beryl::CLI::Credentials.scaleway_client.ssh_keys.list.map do |k|
        # Côté Scaleway, l'id stable est l'UUID (c'est ce qu'attendent
        # les appels `create` ou `install`). On le met dans `id` et
        # on garde le nom lisible dans `name` pour l'affichage.
        Beryl::SshKeyInfo.new(id: k.id, name: k.name, public_key: k.public_key)
      end
    end

    def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
      # Scaleway YAML : `scaleway.ssh_key_ids: [uuid]`. `key_id` est
      # déjà l'UUID fourni par `list_ssh_keys` (SshKeyInfo#id). On
      # tolère aussi un nom fourni à la main via --ssh-key-name.
      uuid = resolve_key_uuid(key_id)
      result = {} of String => String | Array(String)
      result["ssh_key_ids"] = [uuid]
      result
    end

    private def resolve_key_uuid(key_id : String) : String
      return key_id if key_id =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      keys = Beryl::CLI::Credentials.scaleway_client.ssh_keys.list
      match = keys.find { |k| k.name == key_id || k.id == key_id }
      raise "clé SSH Scaleway introuvable : #{key_id}. Disponibles : #{keys.map(&.name).join(", ")}" unless match
      match.id
    end

    def credentials_env_vars : Array(Beryl::EnvVarSpec)
      [
        Beryl::EnvVarSpec.new(
          name: "SCW_SECRET_KEY",
          description: "Secret key (UUID généré dans Console → IAM → API keys)",
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "SCW_DEFAULT_ZONE",
          description: "Zone par défaut (fr-par-1, fr-par-2, nl-ams-1, pl-waw-1…)",
          optional: true,
          default: "fr-par-2",
        ),
        Beryl::EnvVarSpec.new(
          name: "SCW_DEFAULT_PROJECT_ID",
          description: "ID de projet (Console → Settings → Project). Optionnel pour rescue/reboot.",
          optional: true,
        ),
      ]
    end

    def credentials_help_url : String
      "https://console.scaleway.com/iam/api-keys (créez une API key avec les permissions Bare Metal + Domains)"
    end

    def owns?(host_name : String) : Bool
      return false unless available?
      # Scaleway baremetal.servers.list renvoie des Server avec `id`
      # (UUID) et `name` (libre). On matche sur les deux pour accepter
      # `beryl rescue <uuid>` comme `beryl rescue mon-serveur-custom`.
      client = Beryl::CLI::Credentials.scaleway_client
      client.baremetal.servers.list.any? { |s| s.id == host_name || s.name == host_name }
    rescue
      false
    end
  end
end
