require "api-gandi"

module Beryl::Providers
  # Provider Gandi pour beryl — capability `:dns` uniquement (gestion
  # de zone via l'API Gandi LiveDNS v5, shard `api-gandi`).
  #
  # Gandi n'héberge pas de serveurs : pas de capability `:compute`.
  # Le reverse DNS (PTR) n'est PAS géré par Gandi LiveDNS (il relève de
  # l'hébergeur qui possède le bloc d'IP, ex: OVH) → `set_reverse` lève.
  #
  # Le client est injectable via le constructeur pour les tests ; en
  # production il est résolu à la demande depuis `GANDI_PAT`.
  class Gandi < Beryl::Provider
    include Beryl::DnsProvider

    def initialize(@injected_client : GandiApi::Client? = nil)
    end

    private def client : GandiApi::Client
      @injected_client || GandiApi::Client.new(token: ENV["GANDI_PAT"]? || raise(
        "GANDI_PAT absent : générez un Personal Access Token Gandi (permission « Gérer la configuration technique des domaines ») " \
        "et ajoutez-le via `beryl add-provider <société>/gandi`."
      ))
    end

    def name : String
      "gandi"
    end

    def display_name : String
      "Gandi"
    end

    def capabilities : Array(Symbol)
      [:dns]
    end

    # --- DnsProvider ---

    def ensure_record(zone : String, field_type : String, sub_domain : String, target : String) : Nil
      client.livedns.ensure_record(zone, field_type, sub_domain, target)
    end

    # Gandi LiveDNS propage automatiquement : pas de refresh explicite.
    def refresh_zone(zone : String) : Nil
    end

    def set_reverse(ip : String, reverse : String, block : String? = nil) : Nil
      raise "Gandi ne gère pas le reverse DNS (PTR de #{ip}) : il relève de l'hébergeur " \
            "propriétaire du bloc d'IP (ex: OVH). Posez le reverse via le compute provider."
    end

    # --- Provider (méthodes obligatoires) ---

    def available? : Bool
      !!(@injected_client || ENV["GANDI_PAT"]?)
    end

    # Gandi est DNS-only : aucune clé SSH côté panel.
    def list_ssh_keys : Array(Beryl::SshKeyInfo)
      [] of Beryl::SshKeyInfo
    end

    # Non applicable (pas de compute). Bloc vide.
    def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
      {} of String => String | Array(String)
    end

    def credentials_env_vars : Array(Beryl::EnvVarSpec)
      [
        Beryl::EnvVarSpec.new(
          name: "GANDI_PAT",
          description: "Personal Access Token Gandi avec la permission « Gérer la configuration technique des domaines »",
          secret: true,
        ),
      ]
    end

    def credentials_help_url : String
      "https://admin.gandi.net/organizations/ (Paramètres du compte → Personal Access Tokens → créer un token avec « Gérer la configuration technique des domaines »)"
    end

    def credentials_help_details : String?
      "Beryl appelle l'API Gandi LiveDNS v5 :\n" \
      "  GET/PUT  /v5/livedns/domains/<zone>/records/...\n" \
      "Le PAT doit porter la permission « Gérer la configuration technique des domaines » sur l'organisation du domaine."
    end
  end
end
