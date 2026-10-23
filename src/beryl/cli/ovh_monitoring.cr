require "api-ovh/ovh_api"
require "../xdg"

# Monitoring OVH d'un serveur dédié (propriété `monitoring` de
# `/dedicated/server/{serviceName}` : OVH pinge le serveur, ouvre un incident
# et peut faire intervenir un technicien s'il ne répond plus).
#
# `beryl rescue` le COUPE : un serveur qu'on redémarre en rescue, qu'on
# efface ou qu'on installe ne répond pas pendant de longues minutes, et ce
# n'est pas une panne. Il est RÉTABLI au retour sur disque (`boot-hd`, fin de
# `bootstrap`), mais seulement si c'est beryl qui l'avait coupé : un marqueur
# par serviceName dans `<état>/ovh-monitoring/` (cf. `Beryl::Xdg.state_dir`).
# Un monitoring désactivé à la main reste désactivé.
#
# Appel direct de l'API (`client.call`) : le shard api-ovh n'expose pas
# encore cette propriété.
module Beryl::CLI::OvhMonitoring
  extend self

  def dir : String
    File.join(Beryl::Xdg.state_dir, "ovh-monitoring")
  end

  def marker(service_name : String, base : String = dir) : String
    File.join(base, service_name)
  end

  def enabled?(client : OvhApi::Client, service_name : String) : Bool
    client.call("GET", "/dedicated/server/#{service_name}").try(&.["monitoring"]?.try(&.as_bool?)) || false
  end

  def set(client : OvhApi::Client, service_name : String, on : Bool) : Nil
    client.call("PUT", "/dedicated/server/#{service_name}", body: {"monitoring" => on})
  end

  # Coupe le monitoring s'il est actif et pose le marqueur. Message pour le
  # journal de la commande, nil si rien à faire (déjà coupé).
  def suspend(client : OvhApi::Client, service_name : String, base : String = dir) : String?
    return unless enabled?(client, service_name)
    set(client, service_name, false)
    Dir.mkdir_p(base)
    File.write(marker(service_name, base), "#{Time.local.to_rfc3339}\n")
    "monitoring OVH coupé (rétabli au retour sur disque : boot-hd, bootstrap)"
  end

  # Coupé par `beryl rescue` (et pas encore rétabli) ? Date de la coupure,
  # ou nil.
  def suspended_at(service_name : String, base : String = dir) : String?
    path = marker(service_name, base)
    File.exists?(path) ? File.read(path).strip : nil
  end

  # Réglage À LA MAIN (`beryl monitoring on|off`) : il prime sur la coupure
  # de rescue, le marqueur est retiré (boot-hd ne le rétablira plus).
  def set_by_hand(client : OvhApi::Client, service_name : String, on : Bool, base : String = dir) : Nil
    set(client, service_name, on)
    path = marker(service_name, base)
    File.delete(path) if File.exists?(path)
  end

  # Rétablit le monitoring si beryl l'avait coupé, et retire le marqueur.
  # Message pour le journal, nil si rien à faire.
  def resume(client : OvhApi::Client, service_name : String, base : String = dir) : String?
    path = marker(service_name, base)
    return unless File.exists?(path)
    set(client, service_name, true)
    File.delete(path)
    "monitoring OVH rétabli"
  end
end
