require "../cli/credentials"

module Beryl::Providers
  # Provider Dedibox / Online.net pour beryl. Les serveurs sont
  # identifiés par un **entier** (`dedibox.server_id`, type `Int32`)
  # et non un `serviceName` textuel (OVH) ni un UUID (Scaleway).
  #
  # Les clés SSH IAM sont globales au compte et injectées automatiquement
  # par Dedibox dans tout passage en rescue — pas besoin de spécifier
  # `dedibox.ssh_key_name` comme chez OVH.
  #
  # Spécificité du flow rescue Dedibox : l'API expose deux étapes
  # distinctes (`prepare_rescue` pose l'intention, `reboot` l'exécute),
  # là où OVH fait les deux en une seule `prepare_rescue`. Beryl
  # enchaîne les deux pour homogénéiser l'interface.
  #
  # Le client Dedibox est injectable via le constructeur pour les
  # tests. En production, on laisse le défaut et `client` résout à
  # la demande via `Credentials.dedibox_client`.
  class Dedibox < Beryl::Provider
    include Beryl::ComputeProvider

    # Image rescue par défaut. Debian 12 est le choix le plus stable
    # pour héberger le bootstrap mfsBSD-in-QEMU côté beryl (cohérent
    # avec ce qu'on fait sur OVH rescue).
    DEFAULT_RESCUE_IMAGE = "debian-12_amd64"

    def initialize(@injected_client : DediboxApi::Client? = nil)
    end

    private def client : DediboxApi::Client
      @injected_client || Beryl::CLI::Credentials.dedibox_client
    end

    def name : String
      "dedibox"
    end

    def display_name : String
      "Dedibox / Online.net"
    end

    def capabilities : Array(Symbol)
      # Dedibox expose aussi du DNS (via Scaleway Domains côté compte
      # fusionné) et du stockage objet, mais aucun n'est câblé dans
      # beryl aujourd'hui. Scope compute uniquement.
      [:compute]
    end

    # --- ComputeProvider ---

    # `resource_id` doit être la représentation String d'un entier
    # (ex: "186260"). `ssh_key_ref` est ignoré : Dedibox injecte
    # automatiquement toutes les clés IAM du compte.
    def request_rescue(resource_id : String, ssh_key_ref : String) : String
      _ = ssh_key_ref
      id = parse_id(resource_id)
      client.servers.prepare_rescue(id, DEFAULT_RESCUE_IMAGE)
      ok = client.servers.reboot(id, reason: "beryl rescue")
      raise "Dedibox a refusé le reboot (server #{id})" unless ok
      id.to_s
    end

    def boot_from_disk(resource_id : String) : String
      id = parse_id(resource_id)
      # Helper combo boot_normal + reboot encapsulé côté shard
      # (dedibox-api 0.1.3+) pour ne pas faire fuiter la sémantique
      # Dedibox (« sans boot_normal, le reboot reste en rescue »)
      # dans beryl.
      raise "Dedibox a refusé le reboot (server #{id})" unless client.servers.reboot_to_disk(id, reason: "beryl boot-hd")
      id.to_s
    end

    def compute_task_status(task_id : String) : String
      # Dedibox ne propose pas de task async à poller. L'état se lit
      # via `GET /server/{id}.boot_mode` ou par tentative SSH.
      _ = task_id
      raise NotImplementedError.new(
        "Dedibox : pas de notion de task async à poller. Utilisez " \
        "`client.servers.info(id).boot_mode` pour l'état courant."
      )
    end

    def compute_task_done?(status : String) : Bool
      # Dedibox n'expose pas de statut de task ; cette méthode n'est
      # appelée qu'en bout de chaîne hypothétique. Valeurs cohérentes
      # avec `boot_mode` : `normal` ou `rescue`.
      status == "normal" || status == "rescue"
    end

    def available? : Bool
      token = ENV["DEDIBOX_TOKEN"]?
      !token.nil? && !token.empty?
    end

    def list_ssh_keys : Array(Beryl::SshKeyInfo)
      client.ssh_keys.list.map do |k|
        Beryl::SshKeyInfo.new(
          id: k.id.to_s,
          name: k.description,
          public_key: k.key,
        )
      end
    end

    def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
      # Dedibox : aucune référence de clé à écrire dans le YAML host
      # puisque toutes les clés IAM sont auto-injectées en rescue.
      # On conserve l'id pour traçabilité (diagnostic) sans qu'il
      # soit consommé par request_rescue.
      _ = key_id
      {} of String => String | Array(String)
    end

    def credentials_env_vars : Array(Beryl::EnvVarSpec)
      [
        Beryl::EnvVarSpec.new(
          name: "DEDIBOX_TOKEN",
          description: "Bearer token généré depuis la console " \
                       "https://console.online.net/fr/api/access " \
                       "(scope all recommandé)",
          secret: true,
        ),
      ]
    end

    def credentials_help_url : String
      "https://console.online.net/fr/api/access"
    end

    def credentials_help_details : String?
      lines = [] of String
      lines << "Créez un token depuis la console Dedibox :"
      lines << "  1. Ouvrez https://console.online.net/fr/api/access"
      lines << "  2. Onglet « Tokens » → « Créer un nouveau token »"
      lines << "  3. Scope recommandé : all (restreignable plus tard)"
      lines << "  4. Copiez le token (affiché UNE SEULE FOIS)"
      lines << ""
      lines << "Note : l'API Dedibox n'expose PAS d'endpoint pour modifier"
      lines << "le reverse DNS. `beryl scan --dns` posera les records DNS"
      lines << "et renommera le hostname console, mais le reverse reste à"
      lines << "régler dans la console web (IP failover / Reverse DNS)."
      lines.join("\n")
    end

    def owns?(host_name : String) : Bool
      return false unless @injected_client || available?
      id = host_name.to_i?
      return false unless id
      client.servers.list.includes?(id)
    rescue
      false
    end

    # Convertit un `resource_id` String en Int32 avec message d'erreur
    # clair. Dedibox utilise des IDs entiers partout ; un caller qui
    # passe un FQDN ou un UUID se trompe de provider.
    private def parse_id(resource_id : String) : Int32
      resource_id.to_i? || raise ArgumentError.new(
        "Dedibox : resource_id #{resource_id.inspect} n'est pas un entier. " \
        "Les serveurs Dedibox sont identifiés par un entier (dedibox.server_id). " \
        "Pour un OVH, utilisez provider: ovh ; pour un Scaleway, provider: scaleway."
      )
    end
  end
end
