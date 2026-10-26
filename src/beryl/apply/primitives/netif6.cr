require "socket"
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
  #         keep: [2001:db8::5]      # optionnel : autres IPv6 globales à garder
  #
  # Seules restent sur l'interface l'adresse de la fiche (et `keep`) : toute
  # AUTRE IPv6 globale est retirée, après la pose de la nouvelle. Une ancienne
  # adresse oubliée servait sinon d'adresse source, non routée (ke, no :
  # ancien bloc resté à côté du bon, rien ne sortait). Les link-local
  # (`fe80::`) et `::1` ne sont jamais touchées.
  #
  # Passerelle GLOBALE (anciennes gammes OVH : `<bloc /56>ff:ff:ff:ff:ff`, hors
  # du /64 du serveur) : elle n'est joignable qu'avec une route hôte « sur le
  # lien » posée AVANT la route par défaut — à chaud (`route -6 add -host GW
  # -interface IFACE`) et au boot (`ipv6_static_routes` += `beryl_gw`, que
  # rc.d/routing applique avant `ipv6_defaultrouter`). Revenir à `fe80::1`
  # retire cette route de rc.conf.
  #
  # Le routeur interroge alors le serveur (NDP « who has <adresse> ») depuis
  # une adresse HORS du préfixe du serveur ; FreeBSD ignore ces demandes par
  # défaut et le serveur reste injoignable en entrée (il sort, mais personne
  # ne le joint : qwerty, 8 oct. 2026). La primitive active donc
  # `net.inet6.icmp6.nd6_onlink_ns_rfc4861=1`, à chaud et dans
  # /etc/sysctl.conf.
  #         iface: auto              # optionnel (défaut : l'interface publique)
  class Netif6 < Primitive
    def name : String
      "netif6"
    end

    # Valeur `ifconfig_<iface>_ipv6` pour rc.conf. Pur, exposé pour test.
    def self.rc_value(address : String, prefixlen : String) : String
      "inet6 #{address} prefixlen #{prefixlen}"
    end

    # Forme canonique (RFC 5952, compressée) d'une IPv6, `%scope` gardé : l'API
    # OVH écrit `fe80:0000:…:0001`, netstat et rc.conf `fe80::1`. Adresse
    # illisible : rendue telle quelle. Pur, exposé pour test.
    def self.canonical(address : String) : String
      ip, sep, scope = address.partition('%')
      "#{Socket::IPAddress.new(ip, 0).address}#{sep}#{scope}"
    rescue Socket::Error
      address
    end

    # Passerelle scopée : une gw link-local (`fe80::…`) exige `%<iface>` pour
    # être routable ; une gw globale reste telle quelle. Pur, exposé pour test.
    def self.gateway_scoped(gateway : String, iface : String) : String
      return gateway if gateway.includes?('%')
      gateway.starts_with?("fe80") ? "#{gateway}%#{iface}" : gateway
    end

    # Réglage noyau : accepter les demandes NDP venues d'un routeur hors préfixe.
    NS_SYSCTL = "net.inet6.icmp6.nd6_onlink_ns_rfc4861"

    # Nom de la route statique rc.conf vers une passerelle globale.
    GW_ROUTE = "beryl_gw"

    # Valeur `ipv6_route_beryl_gw` (route hôte sur le lien). Pur, exposé pour test.
    def self.gw_route_value(gateway : String, iface : String) : String
      "#{gateway} -prefixlen 128 -interface #{iface}"
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

      unless Primitive.probe?(shell, "ifconfig #{Process.quote(iface)} 2>/dev/null")
        available = shell.exec("ifconfig -l 2>/dev/null", raise_on_error: false).stdout.strip
        return StepResult.failed("interface #{iface} absente — interfaces disponibles : #{available}")
      end

      gw = self.class.gateway_scoped(self.class.canonical(gateway), iface)
      rc_var = "ifconfig_#{iface}_ipv6"
      rc_val = self.class.rc_value(address, prefixlen)

      cur_addrs = shell.exec(
        "ifconfig #{Process.quote(iface)} inet6 2>/dev/null | awk '/inet6 /{print $2}'",
        raise_on_error: false,
      ).stdout.split
      has_addr = cur_addrs.includes?(address)
      wanted = ([address] + string_array(params, "keep")).map { |a| self.class.canonical(a.strip) }
      stale = self.class.stale_globals(cur_addrs, wanted)
      cur_route = shell.exec(
        "netstat -rn -f inet6 2>/dev/null | awk '$1==\"default\"{print $2; exit}'",
        raise_on_error: false,
      ).stdout.strip
      has_route = cur_route == gw
      rc_addr_ok = shell.exec("sysrc -n #{Process.quote(rc_var)} 2>/dev/null", raise_on_error: false).stdout.strip == rc_val
      rc_router_ok = shell.exec("sysrc -n ipv6_defaultrouter 2>/dev/null", raise_on_error: false).stdout.strip == gw
      # Passerelle globale → route hôte sur le lien (rc.conf + table).
      onlink = !gw.starts_with?("fe80")
      statics = shell.exec("sysrc -n ipv6_static_routes 2>/dev/null", raise_on_error: false).stdout.split
      rc_gw_route = shell.exec("sysrc -n ipv6_route_#{GW_ROUTE} 2>/dev/null", raise_on_error: false).stdout.strip
      ns_live = shell.exec("sysctl -n #{NS_SYSCTL} 2>/dev/null", raise_on_error: false).stdout.strip == "1"
      ns_boot = Primitive.probe?(shell, "grep -qx #{Process.quote("#{NS_SYSCTL}=1")} /etc/sysctl.conf 2>/dev/null")
      ns_ok = !onlink || (ns_live && ns_boot)
      rc_gw_ok =
        if onlink
          statics.includes?(GW_ROUTE) && rc_gw_route == self.class.gw_route_value(gw, iface)
        else
          !statics.includes?(GW_ROUTE)
        end

      if has_addr && stale.empty? && has_route && rc_addr_ok && rc_router_ok && rc_gw_ok && ns_ok
        return StepResult.skipped("#{iface} déjà en #{address} (défaut via #{gw})")
      end

      if dry_run
        via = onlink ? " (route sur le lien vers la passerelle)" : ""
        old = !cur_route.empty? && !has_route ? ", remplace #{cur_route}" : ""
        drop = stale.empty? ? "" : ", retire #{stale.join(", ")}"
        return StepResult.applied("#{iface} → #{address} prefixlen #{prefixlen}, défaut via #{gw}#{via}#{old}#{drop} (dry-run)")
      end

      # Persistance (boot).
      shell.exec("sysrc #{Process.quote("#{rc_var}=#{rc_val}")}")
      shell.exec("sysrc #{Process.quote("ipv6_defaultrouter=#{gw}")}")
      if onlink
        shell.exec("sysctl #{NS_SYSCTL}=1")
        unless ns_boot
          line = Process.quote("#{NS_SYSCTL}=1")
          shell.exec("sed -i '' '/^#{NS_SYSCTL}=/d' /etc/sysctl.conf 2>/dev/null; echo #{line} >> /etc/sysctl.conf")
        end
        shell.exec("sysrc #{Process.quote("ipv6_route_#{GW_ROUTE}=#{self.class.gw_route_value(gw, iface)}")}")
        shell.exec("sysrc #{Process.quote("ipv6_static_routes+=#{GW_ROUTE}")}") unless statics.includes?(GW_ROUTE)
      elsif statics.includes?(GW_ROUTE)
        shell.exec("sysrc #{Process.quote("ipv6_static_routes-=#{GW_ROUTE}")}")
        shell.exec("sysrc -x #{Process.quote("ipv6_route_#{GW_ROUTE}")}", raise_on_error: false)
      end
      # Immédiat, SANS toucher l'IPv4 : alias + route par défaut. « route already
      # in table » / adresse déjà posée → non bloquant (raise_on_error: false).
      unless has_addr
        shell.exec("ifconfig #{Process.quote(iface)} inet6 #{Process.quote(address)} prefixlen #{Process.quote(prefixlen)} alias", raise_on_error: false)
      end
      unless has_route
        # Route hôte vers une passerelle globale (« File exists » si déjà là :
        # non bloquant), puis route par défaut : `change` si une autre existe
        # (`add` échouerait en « route already in table »).
        if onlink
          shell.exec("route -6 add -host #{Process.quote(gw)} -interface #{Process.quote(iface)}", raise_on_error: false)
        end
        verb = cur_route.empty? ? "add" : "change"
        shell.exec("route -6 #{verb} default #{Process.quote(gw)}", raise_on_error: false)
      end
      # Anciennes adresses globales retirées APRÈS la pose de la nouvelle et
      # de la route : la connectivité v6 ne passe jamais par zéro adresse.
      stale.each do |old_addr|
        shell.exec("ifconfig #{Process.quote(iface)} inet6 #{Process.quote(old_addr)} delete", raise_on_error: false)
      end
      dropped = stale.empty? ? "" : " ; retirée(s) : #{stale.join(", ")}"
      StepResult.applied("#{iface} : #{address} prefixlen #{prefixlen} + défaut via #{gw}#{dropped}")
    end

    # IPv6 GLOBALES de l'interface à retirer : ni voulues, ni link-local
    # (`fe80::`), ni `::1`. Formes canoniques comparées. Pur, exposé pour test.
    def self.stale_globals(current : Array(String), wanted : Array(String)) : Array(String)
      current.map { |a| canonical(a) }.reject do |a|
        a.starts_with?("fe80:") || a == "::1" || !a.includes?(':') || wanted.includes?(a)
      end.uniq
    end
  end

  Primitive.register(Netif6.new)
end
