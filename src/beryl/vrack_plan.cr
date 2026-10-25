require "./config"

# Plan d'adressage vRack, lu dans les fiches (SEULE source de vérité : nom du
# vRack et réseau dans les `_defaults.yml`, IP dans chaque `.host.yml` ; plus
# de registre à part). Contrôles affichés par `beryl info` :
#
# * collision : deux serveurs sur la même IP dans un même vRack ;
# * IP invalide pour un serveur (`.0` réseau, `.255` diffusion) ;
# * IP hors du réseau `vrack.subnet`, s'il est déclaré.
#
# Une fiche peut porter une LISTE d'IP le temps d'une rotation (`beryl
# vrack`) : ses deux adresses lui appartiennent, ce n'est pas une collision.
module Beryl::VrackPlan
  extend self

  record Entry, host : String, ip : String, vrack : String?, subnet : String?

  # Une ligne par IP vRack déclarée. Pur côté config.
  def entries(hosts : Array(Beryl::Config::ResolvedHost)) : Array(Entry)
    hosts.flat_map do |h|
      h.vrack_ips.map { |ip| Entry.new(h.short_name, ip, h.vrack_name, h.vrack_subnet) }
    end
  end

  # Problèmes du plan d'adressage, en phrases prêtes à afficher. Pur.
  def problems(entries : Array(Entry)) : Array(String)
    found = [] of String
    entries.group_by(&.vrack).each do |vrack, in_vrack|
      in_vrack.group_by(&.ip).each do |ip, same|
        owners = same.map(&.host).uniq
        next if owners.size < 2
        found << "collision #{ip} : #{owners.join(", ")}#{vrack ? " (vRack #{vrack})" : ""}"
      end
    end
    entries.each do |e|
      found << "#{e.host} : #{e.ip} n'est pas une adresse de serveur (.0 ou .255)" if invalid_host_ip?(e.ip)
      if (net = e.subnet) && !in_subnet?(e.ip, net)
        found << "#{e.host} : #{e.ip} hors du réseau #{net}"
      end
    end
    found
  end

  # Dernier octet 0 (réseau) ou 255 (diffusion). Pur.
  def invalid_host_ip?(ip : String) : Bool
    last = ip.split('.').last?.try(&.to_i?)
    last == 0 || last == 255
  end

  # `ip` dans le réseau IPv4 `cidr` (`192.168.42.0/24`) ? Faux si illisible. Pur.
  def in_subnet?(ip : String, cidr : String) : Bool
    base, _, bits = cidr.partition('/')
    n = bits.empty? ? 32 : bits.to_i?
    a = ipv4(ip)
    b = ipv4(base)
    return false unless n && a && b && n >= 0 && n <= 32
    mask = n == 0 ? 0_u32 : (0xFFFFFFFF_u32 << (32 - n))
    (a & mask) == (b & mask)
  end

  private def ipv4(s : String) : UInt32?
    parts = s.split('.').map(&.to_u32?)
    return unless parts.size == 4 && parts.all? { |p| p && p <= 255 }
    parts.reduce(0_u32) { |acc, p| (acc << 8) | p.not_nil! }
  end
end
