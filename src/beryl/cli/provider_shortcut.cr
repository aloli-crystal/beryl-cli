require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "dedibox-api/dedibox_api"

# Raccourci path-like par ID provider partagé entre `beryl rescue` et
# `beryl scan` (et toute commande future qui cible un serveur encore
# anonyme).
#
# Pattern : `beryl <cmd> aloli/<ID> --provider=<name>` où `<ID>` est :
#
#   - un entier pour Dedibox (ex: `186260`)
#   - un UUID v4 pour Scaleway (8-4-4-4-12 hex)
#
# Beryl détecte ce pattern, interroge l'API du provider pour récupérer
# l'IP publique du serveur, et utilise cette IP comme cible SSH (le
# reverse DNS temporaire n'est pas nécessaire, le YAML host n'est pas
# nécessaire).
module Beryl::CLI::ProviderShortcut
  # Zones Scaleway Elastic Metal à balayer pour localiser un UUID
  # quand la zone n'est pas connue a priori. Liste à compléter
  # quand Scaleway ajoute de nouvelles régions.
  SCALEWAY_ZONES = %w[fr-par-1 fr-par-2 fr-par-3 nl-ams-1 nl-ams-2 nl-ams-3 pl-waw-1 pl-waw-2 pl-waw-3]

  UUID_RX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  INT_RX  = /\A\d+\z/

  class NotFound < Exception
  end

  # Résultat d'une résolution réussie. `zone` n'est renseigné que
  # pour Scaleway (zone découverte par scan) : nil pour Dedibox
  # (pas de notion de zone côté API Dedibox) et pour OVH (pas de
  # shortcut).
  alias Resolved = NamedTuple(ip: String, server_id: String, zone: String?)

  # Retourne `{ip, server_id, zone}` si `host_name` est un ID
  # provider pur et si l'appel API réussit. Retourne `nil` si le
  # `host_name` ne correspond pas au pattern attendu pour ce
  # provider. Lève `NotFound` si le pattern matche mais que l'API
  # ne trouve rien.
  #
  # La zone est capitale côté Scaleway : sans elle, l'appel
  # `reboot` qui suit repartirait sur la zone par défaut du shard
  # (fr-par-2) et échouerait en 404 si le serveur est ailleurs
  # (constaté sur chouquette, zone pl-waw-3).
  #
  # `ovh_factory` / `scaleway_factory` / `dedibox_factory` sont des
  # closures qui retournent un client API (injectables pour les tests).
  def self.resolve(
    host_name : String,
    provider : String,
    *,
    ovh_factory : (-> OvhApi::Client)? = nil,
    scaleway_factory : (-> ScalewayApi::Client)? = nil,
    dedibox_factory : (-> DediboxApi::Client)? = nil,
  ) : Resolved?
    case provider
    when "dedibox"
      return nil unless host_name =~ INT_RX
      factory = dedibox_factory || raise ArgumentError.new("dedibox_factory requis")
      info = factory.call.servers.info(host_name.to_i)
      ip = info.public_ip || raise NotFound.new(
        "Dedibox #{host_name} : aucune IP publique trouvée via l'API"
      )
      {ip: ip, server_id: host_name, zone: nil}
    when "scaleway"
      return nil unless host_name =~ UUID_RX
      factory = scaleway_factory || raise ArgumentError.new("scaleway_factory requis")
      client = factory.call
      SCALEWAY_ZONES.each do |zone|
        begin
          server = client.baremetal.servers.get(server_id: host_name, zone: zone)
          ip = server.ips.first?.try(&.address) || next
          return {ip: ip, server_id: host_name, zone: zone}
        rescue ScalewayApi::NotFound
          next
        rescue ex : ScalewayApi::ApiError
          # 501 "unknown service" : zone pas encore activée pour
          # le baremetal. On passe à la suivante.
          next if ex.http_status == 501
          raise ex
        end
      end
      raise NotFound.new(
        "Scaleway UUID #{host_name} : introuvable dans les zones connues " \
        "(#{SCALEWAY_ZONES.join(", ")})"
      )
    else
      # Pas de shortcut pour OVH (le FQDN EST déjà le service_name
      # et résout en DNS) ni pour les providers inconnus.
      nil
    end
  end
end
