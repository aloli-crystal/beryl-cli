require "../primitive"

module Beryl::Apply
  # Primitive `netif6` : pose l'IPv6 publique STATIQUE d'un serveur, de façon
  # persistante (`sysrc ifconfig_<iface>_ipv6` + `ipv6_defaultrouter`) ET
  # immédiate — SANS couper l'IPv4. Chez OVH il n'y a ni DHCPv6 ni RA/SLAAC :
  # l'adresse est statique et la passerelle est la link-local `fe80::1`
  # (constante, scopée `%<iface>`).
  #
  # SÛR pour le SSH v4 : l'adresse est ajoutée en `alias` et la route par
  # défaut v6 posée à chaud — on ne fait JAMAIS `service netif restart` (qui
  # couperait l'IPv4 de l'interface publique). Idempotent : skip si l'adresse
  # et la route par défaut sont déjà là ET que rc.conf est à jour.
  #
  # ⚠️ Utiliser une adresse hôte NON nulle (`<bloc>::1`, pas `<bloc>::` qui est
  # l'anycast Subnet-Router → reste en DAD `tentative`, inutilisable).
  #
  #     - netif6:
  #         address: 2001:41d0:250:dd00::1
  #         prefixlen: 64            # optionnel (défaut 64)
  #         gateway: fe80::1         # optionnel (défaut fe80::1, OVH)
  #         iface: auto              # optionnel (défaut : l'interface publique)
  class Netif6 < Primitive
    def name : String
      "netif6"
    end

    # Valeur `ifconfig_<iface>_ipv6` pour rc.conf. Pur, exposé pour test.
    def self.rc_value(address : String, prefixlen : String) : String
      "inet6 #{address} prefixlen #{prefixlen}"
    end

    # Passerelle scopée : une gw link-local (`fe80::…`) exige `%<iface>` pour
    # être routable ; une gw globale reste telle quelle. Pur, exposé pour test.
    def self.gateway_scoped(gateway : String, iface : String) : String
      return gateway if gateway.includes?('%')
      gateway.starts_with?("fe80") ? "#{gateway}%#{iface}" : gateway
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      address = required_string(params, "address")
      return StepResult.failed("`address` requis (IPv6 publique de l'hôte, forme <bloc>::1)") if address.empty?
      prefixlen = (string(params, "prefixlen") || "64").strip
      gateway = (string(params, "gateway") || "fe80::1").strip
      iface = (string(params, "iface") || "auto").strip

      # Auto-détection : l'interface PUBLIQUE = celle de la route par défaut
      # (contraire de `netif`, qui vise l'interface privée vRack).
      if iface.empty? || iface == "auto"
        iface = shell.exec(
          "route -n get default 2>/dev/null | awk '/interface:/{print $2}'",
          raise_on_error: false,
        ).stdout.strip
        return StepResult.failed("auto-détection de l'interface publique impossible — précisez `iface:`") if iface.empty?
      end

      unless shell.exec("ifconfig #{Process.quote(iface)} 2>/dev/null", raise_on_error: false).success?
        available = shell.exec("ifconfig -l 2>/dev/null", raise_on_error: false).stdout.strip
        return StepResult.failed("interface #{iface} absente — interfaces disponibles : #{available}")
      end

      gw = self.class.gateway_scoped(gateway, iface)
      rc_var = "ifconfig_#{iface}_ipv6"
      rc_val = self.class.rc_value(address, prefixlen)

      cur_addrs = shell.exec(
        "ifconfig #{Process.quote(iface)} inet6 2>/dev/null | awk '/inet6 /{print $2}'",
        raise_on_error: false,
      ).stdout.split
      has_addr = cur_addrs.includes?(address)
      cur_route = shell.exec(
        "netstat -rn -f inet6 2>/dev/null | awk '$1==\"default\"{print $2; exit}'",
        raise_on_error: false,
      ).stdout.strip
      has_route = cur_route == gw
      rc_addr_ok = shell.exec("sysrc -n #{Process.quote(rc_var)} 2>/dev/null", raise_on_error: false).stdout.strip == rc_val
      rc_router_ok = shell.exec("sysrc -n ipv6_defaultrouter 2>/dev/null", raise_on_error: false).stdout.strip == gw

      if has_addr && has_route && rc_addr_ok && rc_router_ok
        return StepResult.skipped("#{iface} déjà en #{address} (défaut via #{gw})")
      end

      if dry_run
        return StepResult.applied("#{iface} → #{address} prefixlen #{prefixlen}, défaut via #{gw} (dry-run)")
      end

      # Persistance (boot).
      shell.exec("sysrc #{Process.quote("#{rc_var}=#{rc_val}")}")
      shell.exec("sysrc #{Process.quote("ipv6_defaultrouter=#{gw}")}")
      # Immédiat, SANS toucher l'IPv4 : alias + route par défaut. « route already
      # in table » / adresse déjà posée → non bloquant (raise_on_error: false).
      unless has_addr
        shell.exec("ifconfig #{Process.quote(iface)} inet6 #{Process.quote(address)} prefixlen #{Process.quote(prefixlen)} alias", raise_on_error: false)
      end
      unless has_route
        shell.exec("route -6 add default #{Process.quote(gw)}", raise_on_error: false)
      end
      StepResult.applied("#{iface} : #{address} prefixlen #{prefixlen} + défaut via #{gw}")
    end
  end

  Primitive.register(Netif6.new)
end
