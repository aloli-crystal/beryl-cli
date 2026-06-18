require "../primitive"

module Beryl::Apply
  # Primitive `netif` : pose une IP statique sur une interface réseau, de
  # façon persistante (`sysrc ifconfig_<iface>`) ET immédiate (`ifconfig`).
  # Idempotente : skip si l'interface porte déjà l'IP ET que le rc.conf est
  # à jour. Ne touche QUE l'interface nommée (sûr pour une iface privée
  # comme le vRack — l'interface publique n'est pas affectée).
  #
  #     - netif:
  #         iface: ix1
  #         ip: 192.168.42.10
  #         netmask: 255.255.255.0   # optionnel
  class Netif < Primitive
    def name : String
      "netif"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      iface = (string(params, "iface") || "auto").strip
      ip = required_string(params, "ip")
      return StepResult.failed("`ip` requis (IP privée du host sur le réseau)") if ip.empty?
      netmask = string(params, "netmask") || "255.255.255.0"

      # Auto-détection (iface vide ou "auto") : le NIC vRack = la SEULE
      # interface Ethernet physique `status: active` qui n'est PAS celle de
      # la route par défaut (= l'interface publique). Robuste même quand le
      # NIC vRack porte DÉJÀ une IP (idempotent au ré-apply). USB/IPMI
      # `ue*`, loopback et ifaces virtuelles exclus. Ambiguïté ou absence →
      # on exige un `iface:` explicite.
      if iface.empty? || iface == "auto"
        candidates = detect_vrack_iface(shell)
        case candidates.size
        when 1 then iface = candidates.first
        when 0
          return StepResult.failed("auto-détection : aucune interface Ethernet candidate hors interface publique — précisez `iface:` explicitement")
        else
          return StepResult.failed("auto-détection ambiguë (#{candidates.join(", ")}) — précisez `iface:`")
        end
      end

      # L'interface doit EXISTER avant toute écriture : sinon netif
      # laisserait un `ifconfig_<iface>` parasite dans rc.conf (warning au
      # boot) et renverrait une erreur opaque. On échoue tôt en listant les
      # interfaces — le nom du NIC vRack varie selon le matériel (ix, igb,
      # bce, mlxen…), `ix1` n'est qu'un défaut.
      unless shell.exec("ifconfig #{Process.quote(iface)} 2>/dev/null", raise_on_error: false).success?
        available = shell.exec("ifconfig -l 2>/dev/null", raise_on_error: false).stdout.strip
        return StepResult.failed("interface #{iface} absente — interfaces disponibles : #{available}")
      end

      rc_var = "ifconfig_#{iface}"
      rc_val = "inet #{ip} netmask #{netmask}"
      # IPv4 actuellement portées par l'iface (l'IPv6 link-local est ignorée).
      current_ips = shell.exec(
        "ifconfig #{Process.quote(iface)} inet 2>/dev/null | awk '/inet /{print $2}'",
        raise_on_error: false,
      ).stdout.split
      rc_current = shell.exec("sysrc -n #{Process.quote(rc_var)} 2>/dev/null", raise_on_error: false).stdout.strip

      # Mode ALIAS (transitoire) : ajoute l'IP en alias SANS retirer les autres
      # ni persister dans rc.conf. Sert à la rotation d'IP de `beryl vrack` :
      # monter la nouvelle IP le temps de la VALIDER, avant de la promouvoir
      # (un `netif` normal ensuite la pose en primaire + retire l'ancienne).
      if bool(params, "alias", default: false)
        return StepResult.skipped("#{iface} porte déjà #{ip}") if current_ips.includes?(ip)
        return StepResult.applied("#{iface} : alias #{ip} (dry-run)") if dry_run
        shell.exec("ifconfig #{Process.quote(iface)} inet #{Process.quote(ip)} netmask #{Process.quote(netmask)} alias")
        return StepResult.applied("#{iface} : alias #{ip} ajouté (transitoire)")
      end

      # Idempotent : l'iface porte EXACTEMENT l'IP voulue (et rien d'autre)
      # ET rc.conf est à jour. Le « rien d'autre » est crucial : un
      # changement d'IP doit FAIRE DISPARAÎTRE l'ancienne (sinon elle
      # subsistait en alias et l'apply semblait sans effet — bug constaté).
      if current_ips == [ip] && rc_current == rc_val
        return StepResult.skipped("#{iface} déjà à #{ip}")
      end

      stale = current_ips.reject { |a| a == ip }
      if dry_run
        delta = stale.empty? ? "#{iface} → #{ip}" : "#{iface} → #{ip} (retire #{stale.join(", ")})"
        return StepResult.applied("#{delta} netmask #{netmask} (dry-run)")
      end

      shell.exec("sysrc #{Process.quote("#{rc_var}=#{rc_val}")}") # persistance (boot)
      # netif gère l'UNIQUE IPv4 de cette interface privée → on retire toute
      # autre IPv4 (notamment l'ancienne lors d'un changement d'IP).
      stale.each do |old|
        shell.exec("ifconfig #{Process.quote(iface)} inet #{Process.quote(old)} -alias", raise_on_error: false)
      end
      shell.exec("ifconfig #{Process.quote(iface)} inet #{Process.quote(ip)} netmask #{Process.quote(netmask)}") # immédiat
      done = stale.empty? ? "#{iface} configuré : #{ip}" : "#{iface} : #{stale.join(", ")} → #{ip}"
      StepResult.applied("#{done} netmask #{netmask}")
    end

    # Détecte le(s) NIC vRack candidats : interface Ethernet physique
    # `status: active` qui n'est PAS l'interface de la route par défaut (=
    # la publique). Indépendant de la présence d'une IP sur l'iface (donc
    # idempotent). Exclut loopback, USB/IPMI (`ue*`) et ifaces virtuelles.
    # Le caller n'accepte la détection que si elle renvoie EXACTEMENT un.
    private def detect_vrack_iface(shell : Shell) : Array(String)
      script = "pub=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); " \
               "for i in $(ifconfig -l ether 2>/dev/null); do " \
               "case \"$i\" in ue*|lo*|tap*|tun*|bridge*|vlan*|wg*) continue;; esac; " \
               "[ \"$i\" = \"$pub\" ] && continue; " \
               "ifconfig \"$i\" 2>/dev/null | grep -q 'status: active' || continue; " \
               "echo \"$i\"; done"
      shell.exec(script, raise_on_error: false).stdout.split
    end
  end

  Primitive.register(Netif.new)
end
