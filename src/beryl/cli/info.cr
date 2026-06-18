require "option_parser"
require "../apply"

module Beryl::CLI
  # `beryl info [host] [--usage]` : inventaire des serveurs.
  #   - sans host  : tableau récap de TOUS les hosts (gamme, CPU, RAM, disques)
  #                  + total parc. Lecture HORS-LIGNE (depuis les host.yml
  #                  alimentés par `beryl scan` — instantané, pas de réseau).
  #   - avec host  : fiche détaillée d'un host.
  #   - --usage    : utilisation LIVE (zpool/df/uptime via SSH) en plus.
  module Info
    EXIT_OK    = 0
    EXIT_USAGE = 1

    def self.run(config_root : String, args : Array(String)) : Int32
      usage = false
      refresh = false
      adoc = false
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl info [host] [--usage] [--adoc]  |  beryl info --refresh [société|domaine]"
        p.on("--usage", "Utilisation LIVE (zpool/df/uptime via SSH)") { usage = true }
        p.on("--adoc", "Sort un document AsciiDoc (table récap du parc) sur stdout") { adoc = true }
        p.on("--refresh", "Rafraîchit gamme + specs + prix via l'API OVH (écrit les host.yml, SANS SSH)") { refresh = true }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
      return refresh_metadata(root, positional.first?) if refresh
      if adoc
        puts build_adoc(scoped_hosts(root, positional.first?), positional.first?)
        return EXIT_OK
      end

      if raw = positional.first?
        parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
        host = root.resolve(parsed[:host],
          account_hint: account_hint || parsed[:account],
          domain_hint: domain_hint || parsed[:domain])
        show_host(host, usage)
      else
        show_all(root, usage)
      end
      EXIT_OK
    rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost
      STDERR.puts "beryl : #{ex.message}"
      EXIT_USAGE
    end

    # Tableau récap de tous les hosts + total parc.
    private def self.show_all(root : Beryl::Config::Root, usage : Bool) : Nil
      hosts = root.all_hosts_by_fqdn.keys.sort.compact_map do |fqdn|
        begin
          root.resolve(fqdn)
        rescue
          nil
        end
      end

      header = ["HOST", "GAMME", "CPU", "RAM", "DISQUES"]
      rows = hosts.map do |h|
        hw = h.hardware
        [
          h.short_name,
          h.ovh_commercial_name || "—",
          hw ? "#{hw.cores}c/#{hw.threads}t" : "(non scanné)",
          hw ? "#{hw.ram_gb} Go" : "—",
          hw ? (hw.disks.empty? ? "—" : hw.disks.join(" + ")) : "—",
        ]
      end
      print_table(header, rows)

      scanned = hosts.count(&.hardware)
      puts
      puts "#{hosts.size} host(s) — #{scanned} scanné(s), #{hosts.size - scanned} à scanner."
      if usage
        puts
        puts "ℹ --usage est ignoré sans host précis : `beryl info <host> --usage`."
      end
    end

    # Fiche détaillée d'un host (specs hors-ligne + utilisation live si --usage).
    private def self.show_host(host : Beryl::Config::ResolvedHost, usage : Bool) : Nil
      puts "host:           #{host.fqdn}"
      puts "provider:       #{host.provider || "—"}"
      puts "service_name:   #{host.ovh_service_name || host.scaleway_server_id || "—"}"
      puts "gamme:          #{host.ovh_commercial_name || "—"}"
      puts "os:             #{host.os}"
      if hw = host.hardware
        puts "cpu:            #{hw.cpu} (#{hw.cores}c/#{hw.threads}t)"
        puts "ram:            #{hw.ram_gb} Go"
        puts "raid:           #{hw.raid || "aucun (RAID logiciel/ZFS)"}"
        puts "disques (provider) :"
        hw.disks.each { |d| puts "  - #{d}" }
      else
        puts "(host non scanné — lancez `beryl scan #{host.fqdn}` pour les specs/disques)"
      end

      return unless usage
      puts
      puts "utilisation (live) :"
      print_usage(host)
    end

    # Interroge le host EN LIVE (best-effort) : pools ZFS, remplissage, charge.
    private def self.print_usage(host : Beryl::Config::ResolvedHost) : Nil
      conn = host.connection
      unless conn.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
        puts "  ✗ injoignable (ou pas FreeBSD) — vérifiez l'accès SSH."
        return
      end
      {
        "zpool"  => "zpool list 2>/dev/null",
        "fs"     => "df -h -t zfs,ufs 2>/dev/null",
        "charge" => "uptime 2>/dev/null",
      }.each do |label, cmd|
        out = conn.exec(cmd, raise_on_error: false).stdout.strip
        next if out.empty?
        puts "  [#{label}]"
        out.each_line { |l| puts "    #{l}" }
      end
    rescue ex
      puts "  ✗ erreur live : #{ex.message}"
    end

    # `--refresh [périmètre]` : pour chaque host OVH du périmètre (société,
    # domaine, host, ou tous), récupère gamme + specs via l'API OVH et les
    # écrit dans le host.yml. AUCUN SSH, aucune modif serveur. Le périmètre
    # filtre par société / domaine / fqdn / nom court.
    # Hosts résolus du périmètre (société / domaine / fqdn / nom court ; vide = tous).
    private def self.scoped_hosts(root : Beryl::Config::Root, scope : String?) : Array(Beryl::Config::ResolvedHost)
      hosts = root.all_hosts_by_fqdn.keys.sort.compact_map do |fqdn|
        begin
          root.resolve(fqdn)
        rescue
          nil
        end
      end
      return hosts unless (s = scope)
      hosts.select { |h| {h.account_name, h.domain_name, h.fqdn, h.short_name}.includes?(s) }
    end

    private def self.refresh_metadata(root : Beryl::Config::Root, scope : String?) : Int32
      ovh_targets = scoped_hosts(root, scope).reject(&.virtual).select { |h| h.provider == "ovh" }
      if ovh_targets.empty?
        puts "Aucun host OVH dans le périmètre #{scope || "(tous)"}."
        return EXIT_OK
      end

      ok = 0
      ovh_targets.group_by(&.account_name).each do |account, hosts|
        hosts.first.apply_all_credentials_to_env!
        ovh = Beryl::Providers::Ovh.new
        unless ovh.available?
          puts "⚠ #{account} : credentials OVH absents — #{hosts.size} host(s) ignoré(s)."
          next
        end
        puts "société #{account} : index des serveurs OVH (API)…"
        index = ovh.ip_to_service_index
        hosts.each do |h|
          sn = h.ovh_service_name
          if sn.nil?
            ip = Beryl::CLI::Scan.resolve_host_ipv4(h.ssh_host)
            sn = ip ? index[ip]? : nil
          end
          unless sn
            puts "  ⚠ #{h.short_name} : service_name introuvable (DNS/IP) — ignoré."
            next
          end
          commercial = ovh.commercial_range(sn)
          hw = ovh.server_hardware(sn)
          price = ovh.monthly_price(sn)
          path = h.node.source_path
          content = File.read(path)
          content = upsert_block(content, "ovh", ovh_block(sn, commercial, price))
          content = upsert_block(content, "hardware", hardware_block(hw)) if hw
          File.write(path, content)
          ok += 1
          puts "  ✓ #{h.short_name} : #{commercial || "gamme ?"}#{price ? " — #{price} €/mois" : ""} — " \
               "#{hw ? "#{hw.cores}c/#{hw.threads}t, #{hw.ram_gb} Go, #{hw.disks.size} grp disque(s)" : "specs indisponibles"}"
        end
      end
      puts
      puts "#{ok}/#{ovh_targets.size} host(s) rafraîchi(s). `beryl info` pour la vue d'ensemble."
      EXIT_OK
    end

    # Lignes du bloc `ovh:` (service_name + gamme + prix/mois).
    private def self.ovh_block(service_name : String, commercial : String?, price : String? = nil) : Array(String)
      b = ["ovh:", "  service_name: #{service_name}"]
      b << "  commercial_name: #{commercial}" if commercial
      b << "  price_eur: #{price}" if price
      b
    end

    # Lignes du bloc `hardware:` (specs déclarées par le provider).
    private def self.hardware_block(hw : Beryl::HardwareSpec) : Array(String)
      b = ["hardware:", "  cpu: #{hw.cpu}", "  cores: #{hw.cores}",
           "  threads: #{hw.threads}", "  ram_gb: #{hw.ram_gb}"]
      b << "  raid: #{hw.raid}" if hw.raid
      unless hw.disks.empty?
        b << "  disks:"
        hw.disks.each { |d| b << "    - #{d}" }
      end
      b
    end

    # Remplace le bloc top-level `key:` (sa ligne + les lignes indentées qui
    # suivent) par `block`, en PRÉSERVANT tout le reste (commentaires inclus).
    # Si le bloc est absent, l'ajoute en fin de fichier (ligne vide de séparation).
    def self.upsert_block(content : String, key : String, block : Array(String)) : String
      lines = content.split('\n')
      if start = lines.index { |l| l.rstrip == "#{key}:" }
        i = start + 1
        while i < lines.size && lines[i].starts_with?(" ")
          i += 1
        end
        return (lines[0...start] + block + lines[i..]).join('\n')
      end
      out = lines.dup
      while !out.empty? && out.last.empty?
        out.pop
      end
      out << ""
      out.concat(block)
      out << ""
      out.join('\n')
    end

    # Document AsciiDoc récapitulatif du parc (table + totaux). Régénérable
    # (`beryl info --adoc <périmètre> > inventaire.adoc`).
    def self.build_adoc(hosts : Array(Beryl::Config::ResolvedHost), scope : String?) : String
      String.build do |io|
        io << "= Inventaire des serveurs"
        io << " — " << scope if scope
        io << '\n'
        io << ":toc:\n"
        io << ":generated: " << Beryl.format_timestamp(Time.local) << "\n\n"
        io << "[cols=\"1,2,3,1,3,1,1,1\",options=\"header\"]\n|===\n"
        io << "| Host | Gamme | CPU | RAM | Disques | vRack | Rôle | Prix/mois\n\n"

        total_cores = 0
        total_ram = 0
        total_price = 0.0
        hosts.each do |h|
          hw = h.hardware
          if hw
            total_cores += hw.cores
            total_ram += hw.ram_gb
          end
          total_price += (h.ovh_price.try(&.to_f?) || 0.0)
          cells = [
            h.short_name,
            h.ovh_commercial_name || "—",
            hw ? "#{hw.cpu} (#{hw.cores}c/#{hw.threads}t)" : "—",
            hw ? "#{hw.ram_gb} Go" : "—",
            (hw && !hw.disks.empty?) ? hw.disks.join(" + ") : "—",
            h.vrack_ip || "—",
            adoc_role(h),
            h.ovh_price ? "#{h.ovh_price} €" : "—",
          ]
          io << "| " << cells.map { |c| c.gsub("|", "\\|") }.join(" | ") << '\n'
        end

        io << "|===\n\n"
        io << "_#{hosts.size} serveurs · #{total_cores} cœurs · #{total_ram} Go RAM · "
        io << "#{"%.2f" % total_price} €/mois (somme des prix connus)._\n"
      end
    end

    # Rôle réseau lisible pour la table : bastion / caché / public / — (pas de vRack).
    private def self.adoc_role(h : Beryl::Config::ResolvedHost) : String
      return "bastion" if h.bastion?
      return "caché" if h.hidden?
      return "public" if h.vrack_ip
      "—"
    end

    # Table alignée (colonnes ljust), en-tête souligné.
    private def self.print_table(header : Array(String), rows : Array(Array(String))) : Nil
      all = [header] + rows
      widths = (0...header.size).map { |i| all.map { |r| r[i].size }.max }
      line = ->(r : Array(String)) do
        r.each_with_index.map { |c, i| c.ljust(widths[i]) }.to_a.join("  ")
      end
      puts line.call(header)
      puts widths.map { |w| "─" * w }.join("──")
      rows.each { |r| puts line.call(r) }
    end
  end
end
