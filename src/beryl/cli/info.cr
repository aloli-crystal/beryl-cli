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
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl info [host] [--usage]"
        p.on("--usage", "Utilisation LIVE (zpool/df/uptime via SSH)") { usage = true }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
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
