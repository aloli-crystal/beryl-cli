require "api-ovh/ovh_api"
require "../apply/primitives/netif6"

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
    # Bloc IPv6 TEL QUE DÉCLARÉ par l'hébergeur (`…::/64`, ou `…::1/128` sur
    # une Kimsufi qui n'a qu'une adresse) : c'est lui le « service IP » du
    # reverse. nil → bloc /64 dérivé de l'adresse.
    getter ipv6_block : String?

    def initialize(@service_name, @fqdn, @short_name, @zone, @ipv4, @ipv6, @ipv6_block : String? = nil)
    end
  end

  # Récupère les infos nécessaires (IPs) pour construire un Plan
  # cohérent. Utilise `client.dedicated_servers.info`
  # et `client.dedicated_servers.ips` du shard ovh-api 0.3.0.
  def self.build_plan(
    client : OvhApi::Client,
    service_name : String,
    short_name : String,
    zone : String,
  ) : Plan
    server_info = client.dedicated_servers.info(service_name)
    ipv4 = server_info["ip"]?.try(&.as_s) || raise "aucune IPv4 déclarée sur #{service_name}"

    # Bloc IPv6 : celui ROUTÉ vers le serveur (`specifications/network` →
    # `routing.ipv6`), à défaut le premier v6 de `/ips` — qui peut lister un
    # ancien bloc (ADV recyclé). Format : "2001:...::/56" ou "/64".
    ipv6 = nil
    ipv6_block = routed_ipv6_block(client, service_name) ||
                 client.dedicated_servers.ips(service_name).find(&.includes?(':'))
    if cidr = ipv6_block
      ipv6 = derive_ipv6_address(Beryl::Apply::Netif6.canonical(cidr.split('/').first), cidr)
    end

    fqdn = "#{short_name}.#{zone}"
    Plan.new(service_name, fqdn, short_name, zone, ipv4, ipv6, ipv6_block)
  end

  # Bloc IPv6 du serveur selon `specifications/network` (`routing.ipv6.ip`,
  # le /56 ou /64 ; PAS `.network`, le /48 agrégé de la baie), forme
  # canonique + longueur de préfixe ; nil si absent.
  def self.routed_ipv6_block(client : OvhApi::Client, service_name : String) : String?
    v6 = client.call("GET", "/dedicated/server/#{service_name}/specifications/network")
      .try(&.["routing"]?).try(&.["ipv6"]?)
    raw = v6.try(&.["ip"]?).try(&.as_s?).presence
    return unless raw && raw.includes?(':')
    base, slash, len = raw.partition('/')
    "#{Beryl::Apply::Netif6.canonical(base)}#{slash}#{len}"
  rescue
    nil
  end

  # À partir d'un bloc CIDR IPv6 (ex. "2001:41d0:2:6e01::/64"), déduit
  # l'adresse usable habituelle chez OVH : base + "::1". Vaut pour tout bloc
  # jusqu'au /64 : les ADV récents reçoivent un /56 ("…:6600::/56"), dont
  # l'adresse « :: » est le réseau (anycast routeur), jamais le serveur.
  def self.derive_ipv6_address(base : String, cidr : String) : String
    prefix = cidr.split('/')[1]?.try(&.to_i?)
    if prefix && prefix <= 64 && base.ends_with?("::")
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
end
