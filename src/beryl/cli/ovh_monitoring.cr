require "api-ovh/ovh_api"

# Monitoring OVH d'un serveur dédié (propriété `monitoring` de
# `/dedicated/server/{serviceName}` : OVH pinge le serveur, ouvre un incident
# et peut faire intervenir un technicien s'il ne répond plus).
#
# Règle simple, sans état côté poste :
#
# * `beryl rescue` le COUPE, toujours (déjà coupé : rien de changé) — un
#   serveur qu'on redémarre en rescue, qu'on efface ou qu'on installe ne
#   répond pas pendant de longues minutes, et ce n'est pas une panne ;
# * `beryl bootstrap` et `beryl boot-hd` le REMETTENT EN SERVICE, toujours,
#   une fois le système joignable, sauf `--no-monitoring`.
#
# Appel direct de l'API (`client.call`) : le shard api-ovh n'expose pas
# encore cette propriété.
module Beryl::CLI::OvhMonitoring
  extend self

  # État lu chez OVH : true/false, ou nil si la réponse ne porte pas le champ
  # `monitoring` (illisible).
  def state(client : OvhApi::Client, service_name : String) : Bool?
    client.call("GET", "/dedicated/server/#{service_name}").try(&.["monitoring"]?.try(&.as_bool?))
  end

  def set(client : OvhApi::Client, service_name : String, on : Bool) : Nil
    client.call("PUT", "/dedicated/server/#{service_name}", body: {"monitoring" => on})
  end

  # Coupe le monitoring (idempotent). Message pour le journal.
  def suspend(client : OvhApi::Client, service_name : String) : String
    set(client, service_name, false)
    "monitoring OVH coupé (remis en service par bootstrap / boot-hd)"
  end

  # Remet le monitoring en service (idempotent). Message pour le journal.
  def resume(client : OvhApi::Client, service_name : String) : String
    set(client, service_name, true)
    "monitoring OVH remis en service"
  end
end
