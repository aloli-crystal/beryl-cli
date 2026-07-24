require "../primitive"

module Beryl::Apply
  # Primitive `wireguard-interface` : configure une interface WireGuard
  # (`wg-quick`, conf `/usr/local/etc/wireguard/<iface>.conf`), l'active au boot
  # (`sysrc wireguard_enable` + `wireguard_interfaces`) et la monte. Idempotente :
  # skip si la conf voulue est déjà en place ET l'interface montée.
  #
  # La CLÉ PRIVÉE du serveur vient du COFFRE (jamais en clair dans le YAML) :
  # `private_key_env` nomme la variable d'ENV (injectée par le coffre au moment
  # de l'apply). Générez-la UNE fois : `wg genkey` (privée → coffre) / `wg pubkey`
  # (publique → à donner aux pairs). Le NAT/forwarding/ouverture UDP sont posés
  # À PART dans la recette (`ip-forward`, `pf-rule`).
  #
  #     - wireguard-interface:
  #         address: "10.100.0.1/24"        # IP du serveur dans le tunnel
  #         listen_port: 51820
  #         private_key_env: WG_PRIVKEY
  #         peers:
  #           - { name: iphone, public_key: "abc…=", allowed_ips: "10.100.0.2/32" }
  #           - { name: pixel,  public_key: "def…=", allowed_ips: "10.100.0.3/32" }
  class WireguardInterface < Primitive
    CONF_DIR = "/usr/local/etc/wireguard"

    def name : String
      "wireguard-interface"
    end

    # Contenu de `<iface>.conf` (format wg-quick). Pur, exposé pour test.
    # `peers` : liste de {name?, public_key, allowed_ips}.
    def self.build_conf(address : String, listen_port : String, private_key : String,
                        peers : Array(Hash(String, String))) : String
      String.build do |s|
        s << "# Géré par beryl (wireguard-interface). Édition manuelle écrasée.\n"
        s << "[Interface]\n"
        s << "Address = " << address << '\n'
        s << "ListenPort = " << listen_port << '\n'
        s << "PrivateKey = " << private_key << '\n'
        peers.each do |peer|
          s << '\n'
          nm = peer["name"]?
          s << "# " << nm << '\n' if nm && !nm.empty?
          s << "[Peer]\n"
          s << "PublicKey = " << peer["public_key"] << '\n'
          s << "AllowedIPs = " << peer["allowed_ips"] << '\n'
        end
      end
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      iface = string(params, "iface") || "wg0"
      address = required_string(params, "address")
      listen_port = string(params, "listen_port") || "51820"
      private_key_env = string(params, "private_key_env") || "WG_PRIVKEY"
      private_key = ENV[private_key_env]?
      if private_key.nil? || private_key.empty?
        raise PrimitiveError.new("`wireguard-interface` : clé privée absente — variable de coffre `#{private_key_env}` vide (générez `wg genkey`, mettez-la au coffre)")
      end
      peers = parse_peers(params)

      conf_path = "#{CONF_DIR}/#{iface}.conf"
      desired = self.class.build_conf(address, listen_port, private_key, peers)

      current = shell.exec("cat #{Process.quote(conf_path)} 2>/dev/null", raise_on_error: false).stdout
      up = shell.exec("ifconfig #{Process.quote(iface)} >/dev/null 2>&1", raise_on_error: false).success?
      rc_iface = shell.exec("sysrc -n wireguard_interfaces 2>/dev/null", raise_on_error: false).stdout.split
      rc_on = shell.exec("sysrc -n wireguard_enable 2>/dev/null", raise_on_error: false).stdout.strip.upcase == "YES"

      if current == desired && up && rc_on && rc_iface.includes?(iface)
        return StepResult.skipped("#{iface} déjà configuré (#{peers.size} pair(s))")
      end

      if dry_run
        return StepResult.applied("configurerait #{iface} : #{address}, port #{listen_port}, #{peers.size} pair(s) (dry-run)")
      end

      shell.exec("mkdir -p #{Process.quote(CONF_DIR)}")
      shell.exec("chmod 700 #{Process.quote(CONF_DIR)}")
      shell.write_file(conf_path, desired, "0600")
      shell.exec("sysrc wireguard_enable=YES")
      # Ajoute l'iface à wireguard_interfaces sans écraser les autres.
      unless rc_iface.includes?(iface)
        merged = (rc_iface + [iface]).uniq.join(' ')
        shell.exec("sysrc #{Process.quote("wireguard_interfaces=#{merged}")}")
      end
      # Applique : restart si déjà montée (recharge la conf), start sinon.
      action = up ? "restart" : "start"
      res = shell.exec("service wireguard #{action} #{Process.quote(iface)}", raise_on_error: false)
      unless res.success?
        return StepResult.failed("service wireguard #{action} #{iface} échoue : #{res.stderr.strip.lines.last? || "code #{res.exit_code}"}")
      end
      StepResult.applied("#{iface} configuré : #{address}, port #{listen_port}, #{peers.size} pair(s)")
    end

    private def parse_peers(params : Hash(String, YAML::Any)) : Array(Hash(String, String))
      result = [] of Hash(String, String)
      raw = params["peers"]?
      return result if raw.nil?
      arr = raw.as_a?
      return result if arr.nil?
      arr.each do |entry|
        h = entry.as_h?
        next unless h
        pub = h[YAML::Any.new("public_key")]?.try(&.as_s?)
        allowed = h[YAML::Any.new("allowed_ips")]?.try(&.as_s?)
        if pub.nil? || pub.empty? || allowed.nil? || allowed.empty?
          raise PrimitiveError.new("`wireguard-interface` : chaque pair exige `public_key` et `allowed_ips`")
        end
        nm = h[YAML::Any.new("name")]?.try(&.as_s?) || ""
        result << {"name" => nm, "public_key" => pub, "allowed_ips" => allowed}
      end
      result
    end
  end

  Primitive.register(WireguardInterface.new)
end
