require "option_parser"
require "../config"

module Beryl::CLI
  # `beryl vrack-dns [--zone …] [--to <résolveur>…]` : génère la zone DNS
  # interne du vRack au format unbound `local-data`, à partir des IP vRack de
  # TOUS les hosts (`vrack-interface`). Source de vérité = les host.yml → zéro
  # table à maintenir. Sans `--to` : affiche la zone. Avec `--to <z>` :
  # la déploie sur le(s) résolveur(s) + recharge unbound.
  module VrackDns
    EXIT_OK    = 0
    EXIT_USAGE = 1
    EXIT_FAIL  = 2

    ZONE_DEFAULT    = "vrack.internal"
    UNBOUND_INCLUDE = "/usr/local/etc/unbound/vrack.conf"

    def self.run(config_root : String, args : Array(String)) : Int32
      zone = ZONE_DEFAULT
      to_hosts = [] of String
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl vrack-dns [--zone #{ZONE_DEFAULT}] [--to <résolveur>]"
        p.on("--zone NAME", "Zone DNS interne (défaut #{ZONE_DEFAULT})") { |v| zone = v }
        p.on("--to HOST", "Déployer la zone sur ce résolveur (répétable)") { |v| to_hosts << v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
      records = collect_records(root)
      if records.empty?
        STDERR.puts "beryl : aucun host avec une IP vRack (`vrack-interface`) — rien à générer."
        return EXIT_USAGE
      end

      zone_data = unbound_local_data(records, zone)
      STDERR.puts "# Zone #{zone} — #{records.size} hôte(s) :"
      puts zone_data
      return EXIT_OK if to_hosts.empty?

      ok = true
      to_hosts.each do |hostname|
        host = root.resolve(hostname)
        conn = host.connection
        STDERR.puts "→ déploiement sur #{host.fqdn}…"
        tmp = "/tmp/beryl-vrack.conf"
        conn.write_file(tmp, zone_data, mode: "0644")
        inst = conn.exec("sudo -n install -m 0644 #{tmp} #{UNBOUND_INCLUDE} && rm -f #{tmp}", raise_on_error: false)
        unless inst.success?
          STDERR.puts "  ⚠ install échoué : #{inst.stderr.strip}"
          ok = false
          next
        end
        rel = conn.exec("sudo -n unbound-control reload 2>/dev/null || sudo -n service unbound reload", raise_on_error: false)
        STDERR.puts(rel.success? ? "  ✓ zone posée + unbound rechargé" : "  ⚠ zone posée, rechargement KO : #{rel.stderr.strip}")
        ok &&= rel.success?
      end
      ok ? EXIT_OK : EXIT_FAIL
    rescue ex
      STDERR.puts "beryl : erreur vrack-dns — #{ex.message}"
      EXIT_FAIL
    end

    # {nom court, IP vRack} de tous les hosts qui ont une IP vRack.
    def self.collect_records(root : Beryl::Config::Root) : Array({String, String})
      records = [] of {String, String}
      root.all_hosts_by_fqdn.each_key do |fqdn|
        host = begin
          root.resolve(fqdn)
        rescue
          next
        end
        if ip = host.vrack_ip
          records << {fqdn.split('.').first, ip}
        end
      end
      records
    end

    # `local-data` unbound (A + PTR) pour la zone, triés par nom. Pur (testé).
    def self.unbound_local_data(records : Array({String, String}), zone : String) : String
      String.build do |io|
        records.sort_by { |r| r[0] }.each do |name, ip|
          fqdn = "#{name}.#{zone}"
          io << "  local-data: \"#{fqdn}. IN A #{ip}\"\n"
          io << "  local-data-ptr: \"#{ip} #{fqdn}.\"\n"
        end
      end
    end
  end
end
