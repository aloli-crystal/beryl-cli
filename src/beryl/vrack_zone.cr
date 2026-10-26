require "./config"

# DNS interne du vRack, lu dans les fiches (SEULE source de vérité, comme le
# plan d'adressage) : chaque host qui a une IP vRack y a un nom
# `<court>.<zone>` (zone `vrack.zone` du merge, `vrack.internal` par défaut,
# domaine réservé à l'usage privé). Les bastions du vRack (`vrack.bastion:
# true`) servent la zone (recette `unbound-vrack`) ; chaque host l'interroge
# par son résolveur local (recette `vrack-resolver`).
#
# `beryl apply` en fait des variables built-in (`vrack_zone`,
# `vrack_local_data`, `vrack_stub_addrs`, `vrack_reverse_zone`) : la zone est
# écrite PAR la recette, à chaque apply, sans étape à part.
module Beryl::VrackZone
  extend self

  DEFAULT_ZONE = "vrack.internal"

  record Peer, name : String, ip : String, bastion : Bool

  # Hosts du même vRack (`vrack.name`) qui ont une IP vRack, triés par nom.
  # Pendant une rotation (`beryl vrack`, liste d'IP), l'adresse active. Pur.
  def peers(hosts : Array(Beryl::Config::ResolvedHost), vrack : String?) : Array(Peer)
    hosts.compact_map do |h|
      next unless h.vrack_name == vrack
      next unless ip = h.vrack_ip
      Peer.new(h.short_name, ip, h.bastion?)
    end.uniq(&.name).sort_by(&.name)
  end

  # `local-data` unbound (A + PTR) de la zone. Pur.
  def local_data(peers : Array(Peer), zone : String) : String
    String.build do |io|
      peers.each do |p|
        fqdn = "#{p.name}.#{zone}"
        io << "    local-data: \"#{fqdn}. IN A #{p.ip}\"\n"
        io << "    local-data-ptr: \"#{p.ip} #{fqdn}.\"\n"
      end
    end.rstrip("\n")
  end

  # `stub-addr` des bastions (serveurs de la zone), un par ligne. Pur.
  def stub_addrs(peers : Array(Peer)) : String
    peers.select(&.bastion).map { |p| "    stub-addr: #{p.ip}" }.join("\n")
  end

  # Zone inverse d'un réseau découpé à l'octet (`/8`, `/16`, `/24`), sinon nil.
  # Ex. `192.168.42.0/24` → `42.168.192.in-addr.arpa`. Pur.
  def reverse_zone(cidr : String?) : String?
    return unless cidr
    base, _, bits = cidr.partition('/')
    octets = base.split('.')
    n = bits.to_i?
    return unless octets.size == 4 && n && {8, 16, 24}.includes?(n)
    "#{octets.first(n // 8).reverse.join('.')}.in-addr.arpa"
  end
end
