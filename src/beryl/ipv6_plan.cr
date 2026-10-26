require "./config"

# Cohérence IPv6 des fiches OVH : l'adresse posée (`ovh.ipv6`, celle de
# `netif-ipv6` et de l'AAAA) doit appartenir au bloc qu'OVH route vers le
# serveur (`ovh.ipv6_block`, lu dans l'API par `beryl info --refresh`).
# Affiché par `beryl info` à côté du plan d'adressage vRack. Une adresse hors
# du bloc ne sort pas (vu sur ke : un ancien AAAA recopié dans la fiche).
module Beryl::Ipv6Plan
  extend self

  # Problèmes, en phrases prêtes à afficher. Fiche sans bloc : pas de contrôle.
  def problems(hosts : Array(Beryl::Config::ResolvedHost)) : Array(String)
    hosts.compact_map do |h|
      ip = h.ovh_ipv6
      block = h.ovh_ipv6_block
      next unless ip && block
      next if in_block?(ip, block)
      "#{h.short_name} : IPv6 #{ip} hors du bloc #{block} (OVH) — `beryl info #{h.short_name} --refresh` puis `beryl sync #{h.short_name} --apply`"
    end
  end

  # `ip` dans le bloc IPv6 `cidr` (`2001:db8:1200::/56`) ? Faux si illisible. Pur.
  def in_block?(ip : String, cidr : String) : Bool
    base, _, bits = cidr.partition('/')
    n = bits.empty? ? 128 : bits.to_i?
    a = value(ip)
    b = value(base)
    return false unless n && a && b && n >= 0 && n <= 128
    return true if n == 0
    shift = 128 - n
    (a >> shift) == (b >> shift)
  end

  # Adresse IPv6 → entier 128 bits (forme courte `::` acceptée, zone `%…`
  # ignorée), nil si illisible. Pur.
  def value(addr : String) : UInt128?
    a = addr.partition('%').first.downcase
    return if a.empty? || a.scan("::").size > 1
    head, sep, tail = a.partition("::")
    left = head.empty? ? [] of String : head.split(':')
    right = tail.empty? ? [] of String : tail.split(':')
    groups = if sep.empty?
               left
             else
               missing = 8 - left.size - right.size
               return if missing < 1
               left + Array.new(missing, "0") + right
             end
    return unless groups.size == 8
    groups.reduce(0_u128) do |acc, g|
      return unless (1..4).includes?(g.size) && g.each_char.all?(&.hex?)
      (acc << 16) | g.to_u128(16)
    end
  end
end
