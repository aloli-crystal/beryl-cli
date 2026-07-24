require "../primitive"

module Beryl::Apply
  # Primitive `ip-forward` : active le routage IP (le host relaie les paquets
  # entre interfaces), de façon PERSISTANTE (`sysrc *gateway_enable`) ET
  # IMMÉDIATE (`sysctl`). Socle des passerelles/VPN : exit-node Tailscale,
  # subnet-router, serveur WireGuard. Idempotent : skip si déjà actif.
  #
  # IPv4 : `gateway_enable=YES` + `net.inet.ip.forwarding=1`.
  # IPv6 (défaut, la flotte est dual-stack) : `ipv6_gateway_enable=YES` +
  # `net.inet6.ip6.forwarding=1`. `ipv6: false` pour ne router que l'IPv4.
  #
  #     - ip-forward              # v4 + v6
  #     - ip-forward: { ipv6: false }
  class IpForward < Primitive
    # (sysrc var, sysctl oid) pour un famille d'adresses. Pur, exposé pour test.
    def self.knobs(ipv6 : Bool) : Array({String, String})
      k = [{"gateway_enable", "net.inet.ip.forwarding"}]
      k << {"ipv6_gateway_enable", "net.inet6.ip6.forwarding"} if ipv6
      k
    end

    def name : String
      "ip-forward"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      ipv6 = bool(params, "ipv6", default: true)
      knobs = self.class.knobs(ipv6)

      all_ok = knobs.all? do |rc, oid|
        rc_on = shell.exec("sysrc -n #{rc} 2>/dev/null", raise_on_error: false).stdout.strip.upcase == "YES"
        sc_on = shell.exec("sysctl -n #{oid} 2>/dev/null", raise_on_error: false).stdout.strip == "1"
        rc_on && sc_on
      end
      fam = ipv6 ? "IPv4+IPv6" : "IPv4"
      return StepResult.skipped("forwarding #{fam} déjà actif") if all_ok
      return StepResult.applied("activerait le forwarding #{fam} (dry-run)") if dry_run

      knobs.each do |rc, oid|
        shell.exec("sysrc #{Process.quote("#{rc}=YES")}")                        # persistance (boot)
        shell.exec("sysctl #{Process.quote("#{oid}=1")}", raise_on_error: false) # immédiat
      end
      StepResult.applied("forwarding #{fam} activé (#{knobs.map { |_, oid| oid }.join(", ")})")
    end
  end

  Primitive.register(IpForward.new)
end
