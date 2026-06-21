require "api-ovh/ovh_api"

# Helpers OVH compute pour le nommage d'un serveur dédié : détection des
# IPs (IPv4/IPv6) à partir du `service_name`, dérivation du bloc /64 pour
# le reverse, et renommage du `displayName` côté panel.
#
# Le FORWARD DNS (A/AAAA + refresh) ne vit plus ici : il passe par
# l'abstraction multi-provider `Beryl::DnsProvider` (OVH, Gandi…) — voir
# `Beryl::CLI::DnsApply`. Ce module ne garde que ce qui est spécifique au
# compute OVH (lecture serveur + reverse au niveau bloc + rename).
module Beryl::CLI::DnsSetup
  # Infos d'un serveur OVH (IPs, displayName actuel) calculées par
  # `build_plan` pour alimenter le flux de nommage. Exposé pour
  # affichage à l'opérateur avant confirmation.
  struct Plan
    getter service_name : String
    getter fqdn : String       # ex. loulou.example.net
    getter short_name : String # ex. loulou
    getter zone : String       # ex. example.net
    getter ipv4 : String
    getter ipv6 : String?
    getter current_display_name : String?

    def initialize(@service_name, @fqdn, @short_name, @zone, @ipv4, @ipv6, @current_display_name)
    end
  end

  # Récupère les infos nécessaires (IPs, displayName actuel) pour
  # construire un Plan cohérent. Utilise `client.dedicated_servers.info`
  # et `client.dedicated_servers.ips` du shard ovh-api 0.3.0.
  def self.build_plan(
    client : OvhApi::Client,
    service_name : String,
    short_name : String,
    zone : String,
  ) : Plan
    server_info = client.dedicated_servers.info(service_name)
    ipv4 = server_info["ip"]?.try(&.as_s) || raise "aucune IPv4 déclarée sur #{service_name}"
    display_name = server_info["name"]?.try(&.as_s)

    # Liste des IPs affectées au serveur. On cherche la première v6.
    # Format des IPs : "51.83.6.X/32" pour v4, "2001:...::/64" pour v6.
    ipv6 = nil
    client.dedicated_servers.ips(service_name).each do |cidr|
      next unless cidr.includes?(':')
      base = cidr.split('/').first
      ipv6 = derive_ipv6_address(base, cidr)
      break
    end

    fqdn = "#{short_name}.#{zone}"
    Plan.new(service_name, fqdn, short_name, zone, ipv4, ipv6, display_name)
  end

  # À partir d'un bloc CIDR IPv6 (ex. "2001:41d0:2:6e01::/64"), déduit
  # l'adresse usable habituelle chez OVH : base + "::1".
  def self.derive_ipv6_address(base : String, cidr : String) : String
    # Si le bloc se termine par ::/64, l'IP usable standard OVH est
    # ::1 (ou plutôt l'adresse que le serveur utilise effectivement).
    # Faute d'info précise, on pose ::1 qui marche dans 99% des cas.
    if cidr.ends_with?("/64") && base.ends_with?("::")
      base + "1"
    else
      base
    end
  end

  # Déduit le bloc /64 (préfixe réseau) d'une adresse IPv6. OVH gère le
  # reverse au niveau du BLOC : pour une IPv6 l'API attend
  # `POST /ip/{bloc /64}/reverse` avec l'adresse précise dans `ipReverse`,
  # PAS l'adresse /128 dans le path (sinon 404 « This service does not
  # exist » — le /128 n'est pas un service IP, seul le /64 routé l'est).
  # En IPv4 le souci ne se pose pas : bloc == adresse (/32).
  #
  # Le /64 est exactement le réseau de n'importe quelle adresse du bloc
  # (les 64 premiers bits), donc le dériver de l'adresse est exact — pas
  # une devinette. Ex. `2001:41d0:306:2b67::1` → `2001:41d0:306:2b67::/64`.
  def self.ipv6_block_64(address : String) : String
    addr = address.split('/').first
    if addr.includes?("::")
      left, right = addr.split("::", 2)
      left_groups = left.empty? ? [] of String : left.split(':')
      right_groups = right.empty? ? [] of String : right.split(':')
      zeros = 8 - left_groups.size - right_groups.size
      groups = left_groups + Array.new(zeros, "0") + right_groups
    else
      groups = addr.split(':')
    end
    "#{groups.first(4).join(':')}::/64"
  end

  def self.update_display_name(
    client : OvhApi::Client,
    service_name : String,
    new_name : String,
    logger : Proc(String, Nil),
  ) : Nil
    logger.call("renomme displayName OVH : #{service_name} → #{new_name}")
    client.dedicated_servers.update(service_name, display_name: new_name)
  end
end
