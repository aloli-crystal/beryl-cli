require "api-ovh/ovh_api"
require "api-scaleway/scaleway_api"
require "api-dedibox/dedibox_api"

# Raccourci path-like par ID provider partagé entre `beryl rescue` et
# `beryl scan` (et toute commande future qui cible un serveur encore
# anonyme).
#
# Pattern : `beryl <cmd> acme/<ID> --provider=<name>` où `<ID>` est :
#
#   - un entier pour Dedibox (ex: `186260`)
#   - un UUID v4 pour Scaleway (8-4-4-4-12 hex)
#
# Beryl détecte ce pattern, interroge l'API du provider pour récupérer
# l'IP publique du serveur, et utilise cette IP comme cible SSH (le
# reverse DNS temporaire n'est pas nécessaire, le YAML host n'est pas
# nécessaire).
module Beryl::CLI::ProviderShortcut
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
      server = factory.call.baremetal.servers.find_any_zone(host_name) ||
               raise NotFound.new(
                 "Scaleway UUID #{host_name} : introuvable dans les zones connues " \
                 "(#{ScalewayApi::ZONES.join(", ")})"
               )
      ip = server.ips.first?.try(&.address) || raise NotFound.new(
        "Scaleway UUID #{host_name} : trouvé dans la zone #{server.zone}, mais aucune IP attachée"
      )
      {ip: ip, server_id: host_name, zone: server.zone}
    else
      # Pas de shortcut pour OVH (le FQDN EST déjà le service_name
      # et résout en DNS) ni pour les providers inconnus.
      nil
    end
  end
end
