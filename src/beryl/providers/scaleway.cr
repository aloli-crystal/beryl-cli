require "../cli/credentials"

module Beryl::Providers
  # Provider Scaleway Elastic Metal pour beryl. Les clés SSH sont
  # gérées au niveau IAM (pas par projet) et identifiées par un UUID +
  # un nom humain — on expose les noms dans `list_ssh_keys` mais on
  # écrit les UUIDs dans le YAML (c'est ce que consomme l'API `create`).
  #
  # Le client Scaleway est injectable via le constructeur pour les
  # tests. En production, on laisse le défaut et `client` résout à la
  # demande via `Credentials.scaleway_client`.
  class Scaleway < Beryl::Provider
    def initialize(@injected_client : ScalewayApi::Client? = nil)
    end

    private def client : ScalewayApi::Client
      @injected_client || Beryl::CLI::Credentials.scaleway_client
    end

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
      client.ssh_keys.list.map do |k|
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
      keys = client.ssh_keys.list
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
      "https://console.scaleway.com/iam/api-keys (créez une API key avec les policies listées ci-dessous)"
    end

    # Permissions IAM Scaleway requises par beryl. Contrairement à OVH,
    # Scaleway ne permet pas de générer une API key depuis zéro via
    # l'API (chicken-and-egg : il faut déjà une key pour en créer une).
    # L'utilisateur doit donc créer la key manuellement dans la console,
    # en cochant les permission_set_names ci-dessous.
    #
    # Référence : https://www.scaleway.com/en/developers/api/iam/#permission-sets
    def required_permissions : Array(String)
      [
        "BareMetalFullAccess",  # list/reboot/install servers (rescue, bootstrap)
        "DomainsDNSFullAccess", # pose records A/AAAA, reverses, refresh zone
        "IAMReadOnly",          # lecture SSH keys (list_ssh_keys)
      ]
    end

    # Détails affichés pendant `beryl init` : liste textuelle des
    # permissions IAM à cocher dans la console Scaleway.
    def credentials_help_details : String?
      lines = [] of String
      lines << "Créez une API key dans la console Scaleway, onglet Permission sets :"
      required_permissions.each { |p| lines << "  - #{p}" }
      lines << "Puis copiez la 'Secret Key' ci-dessous (pas l''Access Key', on n'en a pas besoin)."
      lines.join("\n")
    end

    def owns?(host_name : String) : Bool
      return false unless @injected_client || available?
      # Scaleway baremetal.servers.list renvoie des Server avec `id`
      # (UUID) et `name` (libre). On matche sur les deux pour accepter
      # `beryl rescue <uuid>` comme `beryl rescue mon-serveur-custom`.
      client.baremetal.servers.list.any? { |s| s.id == host_name || s.name == host_name }
    rescue
      false
    end
  end
end
