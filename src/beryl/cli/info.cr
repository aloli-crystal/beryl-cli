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
        hosts = scoped_hosts(root, positional.first?)
        usage_map = usage ? gather_usage_map(hosts) : nil
        puts build_adoc(hosts, positional.first?, usage_map)
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

    # Affiche l'utilisation disque LIVE d'un host (table). Best-effort.
    private def self.print_usage(host : Beryl::Config::ResolvedHost) : Nil
      rows = gather_usage(host)
      if rows.nil?
        puts "  ✗ injoignable — vérifiez l'accès SSH (user #{host.connect_user})."
        return
      end
      if rows.empty?
        puts "  (aucun volume détecté)"
        return
      end
      print_table(["VOLUME", "TAILLE", "UTILISÉ", "LIBRE", "%"],
        rows.map { |r| [r.label, r.size, r.used, r.free, r.pct] })
    end

    # Utilisation disque normalisée (une ligne par volume).
    record UsageRow, label : String, size : String, used : String, free : String, pct : String

    # Récupère l'utilisation disque EN LIVE (best-effort) : pools ZFS
    # (`zpool list`) ou, à défaut, systèmes de fichiers réels (`df -h`, pseudo-FS
    # filtrés). nil si le host est injoignable. Marche FreeBSD ET Linux.
    private def self.gather_usage(host : Beryl::Config::ResolvedHost) : Array(UsageRow)?
      conn = host.connection(host.connect_user)
      return nil unless conn.exec("uname 2>/dev/null", raise_on_error: false).success?
      zp = conn.exec("zpool list -H -o name,size,alloc,free,cap 2>/dev/null", raise_on_error: false).stdout.strip
      return parse_zpool(zp) unless zp.empty?
      # `df -h` SANS sudo (suggestion de Philippe) — résumé par pool.
      parse_df(conn.exec("df -h 2>/dev/null", raise_on_error: false).stdout.strip)
    rescue
      nil
    end

    # Parse `zpool list -H -o name,size,alloc,free,cap` → une ligne par pool.
    def self.parse_zpool(output : String) : Array(UsageRow)
      output.each_line.compact_map do |l|
        f = l.split
        f.size >= 5 ? UsageRow.new(f[0], f[1], f[2], f[3], f[4]) : nil
      end.to_a
    end

    # Parse `df -h` → utilisation par POOL : un dataset ZFS (`zroot/...`, `zdata`)
    # est regroupé sous son pool (segment avant le 1er `/`), en gardant le montage
    # le plus court (racine du pool) ; un device classique (UFS/ext4) = son montage.
    # Pseudo-FS (devfs/tmpfs/proc…) filtrés. Fonction PURE (sans sudo côté hôte).
    def self.parse_df(output : String) : Array(UsageRow)
      skip = {"devfs", "tmpfs", "procfs", "fdescfs", "linprocfs", "none", "run", "udev", "overlay"}
      best = {} of String => {mnt: String, row: UsageRow}
      order = [] of String
      output.split('\n')[1..].each do |l|
        f = l.split
        next if f.size < 6
        fs = f[0]
        mnt = f[5..].join(" ")
        next if skip.includes?(fs) || !mnt.starts_with?("/")
        next if {"/dev", "/proc", "/sys", "/run"}.any? { |p| mnt == p || mnt.starts_with?("#{p}/") }
        # Dataset ZFS (ne commence PAS par `/`, ex. `zroot/...` ou `zdata`) →
        # regroupé par pool ; device classique (`/dev/...`) → par montage.
        key = fs.starts_with?('/') ? mnt : fs.split('/').first
        cur = best[key]?
        if cur.nil? || mnt.size < cur[:mnt].size
          order << key unless best.has_key?(key)
          best[key] = {mnt: mnt, row: UsageRow.new(key, f[1], f[2], f[3], f[4])}
        end
      end
      order.map { |k| best[k][:row] }
    end

    # Collecte l'usage de chaque host (pour `--adoc --usage`). Progrès sur STDERR
    # (stdout = le document). nil = host injoignable.
    private def self.gather_usage_map(hosts : Array(Beryl::Config::ResolvedHost)) : Hash(String, Array(UsageRow)?)
      map = {} of String => Array(UsageRow)?
      hosts.each do |h|
        STDERR.puts "  usage #{h.short_name}…"
        map[h.fqdn] = gather_usage(h)
      end
      map
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

    # Document AsciiDoc récapitulatif : synthèse + matériel + réseau vRack +
    # (si `usage` fourni) utilisation disque LIVE. Régénérable :
    # `beryl info --adoc [--usage] <périmètre> > inventaire.adoc`.
    def self.build_adoc(
      hosts : Array(Beryl::Config::ResolvedHost),
      scope : String?,
      usage : Hash(String, Array(UsageRow)?)? = nil,
    ) : String
      esc = ->(s : String) { s.gsub("|", "\\|") }
      String.build do |io|
        io << "= Inventaire des serveurs"
        io << " — " << scope if scope
        io << "\n:toc:\n:toclevels: 2\n"
        # Rendu PDF en PAYSAGE (asciidoctor-pdf) : tables larges lisibles.
        io << ":pdf-page-layout: landscape\n:pdf-page-size: A4\n"
        io << ":generated: " << Beryl.format_timestamp(Time.local) << "\n\n"

        cores = hosts.sum { |h| h.hardware.try(&.cores) || 0 }
        ram = hosts.sum { |h| h.hardware.try(&.ram_gb) || 0 }
        price = hosts.sum { |h| h.ovh_price.try(&.to_f?) || 0.0 }
        io << "== Synthèse\n\n[horizontal]\n"
        io << "Serveurs:: #{hosts.size}\n"
        io << "Cœurs (vCPU):: #{cores}\n"
        io << "RAM totale:: #{ram} Go\n"
        io << "Coût mensuel:: #{"%.2f" % price} € _(prix connus)_\n\n"

        io << "== Matériel\n\n"
        io << "[options=\"header\",cols=\"2,3,3,1,4,2\"]\n|===\n"
        io << "| Host | Gamme | CPU | RAM | Disques | Prix/mois\n\n"
        hosts.each do |h|
          hw = h.hardware
          cells = [
            h.short_name,
            h.ovh_commercial_name || "—",
            hw ? "#{hw.cpu} (#{hw.cores}c/#{hw.threads}t)" : "—",
            hw ? "#{hw.ram_gb} Go" : "—",
            (hw && !hw.disks.empty?) ? hw.disks.join(", ") : "—",
            h.ovh_price ? "#{h.ovh_price} €" : "—",
          ]
          io << "| " << cells.map { |c| esc.call(c) }.join(" | ") << '\n'
        end
        io << "|===\n\n"

        vrack_hosts = hosts.select(&.vrack_ip)
        unless vrack_hosts.empty?
          io << "== Réseau vRack\n\n[options=\"header\",cols=\"2,2,3\"]\n|===\n"
          io << "| Host | IP vRack | Rôle\n\n"
          vrack_hosts.each do |h|
            io << "| #{h.short_name} | #{h.vrack_ip} | #{esc.call(adoc_role(h))}\n"
          end
          io << "|===\n\n"
        end

        if usage
          io << "== Utilisation disque _(live)_\n\n"
          io << "[options=\"header\",cols=\"2,3,1,1,1,1\"]\n|===\n"
          io << "| Host | Volume | Taille | Utilisé | Libre | %\n\n"
          hosts.each do |h|
            rows = usage[h.fqdn]?
            if rows.nil?
              io << "| #{h.short_name} | _injoignable_ | — | — | — | —\n"
            elsif rows.empty?
              io << "| #{h.short_name} | _aucun volume_ | — | — | — | —\n"
            else
              rows.each_with_index do |r, i|
                io << "| #{i.zero? ? h.short_name : ""} | #{esc.call(r.label)} | #{r.size} | #{r.used} | #{r.free} | #{r.pct}\n"
              end
            end
          end
          io << "|===\n\n"
        end
      end
    end

    # Rôle réseau lisible : bastion / caché (via <z>) / public.
    private def self.adoc_role(h : Beryl::Config::ResolvedHost) : String
      return "bastion" if h.bastion?
      if pj = h.proxy_jump(h.connect_user)
        return "caché (via #{pj.split('@').last.split('.').first})"
      end
      "public"
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
