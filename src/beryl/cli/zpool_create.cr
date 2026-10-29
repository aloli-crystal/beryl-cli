require "option_parser"
require "./option_errors"
require "ssh"
require "./root_conn"
require "./account_utils"
require "../config"
require "../encryption"
require "./key_store"

# Sous-commande `beryl zpool-create <host>` : crée les pools data déclarés
# (`freebsd.zfs.<nom>`) qui n'existent pas encore sur un serveur DÉJÀ
# installé. `bootstrap` ne les crée qu'à l'installation ; ici, cas d'un
# disque ajouté après coup ou d'une VM FreeBSD invitée (recette
# `kvm-freebsd-guest`), installée depuis une image et jamais bootstrapée.
#
# Mêmes règles que bootstrap : une partition GPT alignée 1 Mio par disque,
# labellisée `<pool><i>` (pool sur /dev/gpt/…), ashift 12, chiffrement ZFS
# natif avec la clé 256 bits du poste (`~/.config/beryl/<société>/<domaine>/
# <host>.key`, générée si absente, et rangée dans le coffre `[tang]` de la
# société, cf. `Beryl::ZfsKeys`). La clé voyage sur stdin, jamais en
# argument ni sur le disque du serveur. Pool chiffré exclu du cache : au
# démarrage, il attend `beryl unlock` ou clevis-zfs (mode tang, après
# `beryl tang-enroll`).
#
# Garde-fous : pool déjà présent (importé ou importable) → sauté ; disque
# absent ou NON VIERGE (table de partitions, système de fichiers, label
# ZFS) → refus, rien n'est effacé. DRY-RUN par défaut (sondes en lecture
# seule), `--apply` pour créer.
module Beryl::CLI::ZpoolCreate
  EXIT_OK          = 0
  EXIT_USAGE       = 1
  EXIT_SSH_FAILED  = 2
  EXIT_UNEXPECTED  = 3
  EXIT_NO_POOLS    = 5
  EXIT_DISK_REFUSE = 6

  # Plancher de bootstrap (`Bootstrap::MIN_ASHIFT`) : 4 K, valable pour un
  # disque virtuel qui annonce 512 octets comme pour un disque 4Kn.
  ASHIFT = 12

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    dry_run = true
    no_commit = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl zpool-create <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("--apply", "Crée réellement les pools (sinon : dry-run, sondes en lecture seule)") { dry_run = false }
      p.on("--no-commit", "Ne commite pas le coffre de la société après y avoir rangé la clé") { no_commit = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl zpool-create <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(parsed[:host], account_hint: account_hint, domain_hint: domain_hint)
    pools = host.data_zpools
    if pools.empty?
      STDERR.puts "beryl : aucun pool data déclaré pour #{host.fqdn} (freebsd.zfs.<nom>, hors pool boot)"
      return EXIT_NO_POOLS
    end

    conn = Beryl::CLI::RootConn.new(host.connection)
    target = "#{conn.user}@#{conn.host}"
    key_path = Beryl::Encryption.key_path(config_root, host.account_name, host.domain_name, host.short_name)
    refused = 0

    pools.each do |pool|
      if present?(conn, pool.name)
        log "#{pool.name} : déjà présent sur #{target} — sauté"
        next
      end
      mp = pool.mountpoint
      if mp.nil? || mp.empty?
        STDERR.puts "beryl : pool #{pool.name} sans mountpoint (ajoutez `mountpoint: /xxx`)"
        refused += 1
        next
      end
      devices = pool.disks.map(&.lchop("/dev/"))
      if (reason = devices.compact_map { |d| refusal(conn, d) }.first?)
        STDERR.puts "beryl : #{pool.name} : #{reason} — rien n'est créé"
        refused += 1
        next
      end
      begin
        Beryl::Config::Zpool.validate!(pool.raid, devices.size)
      rescue ex : ArgumentError
        STDERR.puts "beryl : #{pool.name} : #{ex.message}"
        refused += 1
        next
      end

      script = create_script(pool.name, pool.raid, devices, mp, pool.encrypted?)
      if dry_run
        log "DRY-RUN : #{pool.name} sur #{target} (#{devices.join(", ")}, #{pool.encrypted? ? "chiffré, clé #{key_path}" : "clair"})"
        script.each_line { |l| log "DRY-RUN :   #{l}" }
        next
      end

      key_hex = nil
      if pool.encrypted?
        key_hex, created = Beryl::CLI::KeyStore.obtain_or_create(config_root, host)
        if created
          log "#{pool.name} : clé générée (#{key_path}, 0400) — à mettre sous séquestre (`beryl keys paper`) : la perdre = perdre les données"
        else
          log "#{pool.name} : clé existante réutilisée"
        end
        # Rangée dans le coffre AVANT de chiffrer quoi que ce soit avec.
        Beryl::CLI::KeyStore.ensure_in_vault(host, key_hex, no_commit) { |m| log m }
      end
      result = conn.exec(script, stdin: key_hex, raise_on_error: false)
      unless result.success?
        STDERR.puts "beryl : #{pool.name} : création échouée (exit=#{result.exit_code}) : #{result.stderr.strip}"
        refused += 1
        next
      end
      log "#{pool.name} : créé et monté sur #{mp}#{pool.encrypted? ? " (chiffré ; au redémarrage : beryl unlock, ou Tang après tang-enroll)" : ""}"
    end

    refused > 0 ? EXIT_DISK_REFUSE : EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Encryption::Error
    STDERR.puts "beryl : #{ex.message}"
    EXIT_UNEXPECTED
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : SSH a échoué — #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Script de création (un `sh -c` côté serveur). Pool chiffré : la clé hex
  # arrive sur stdin (`keylocation=prompt`) et `cachefile=none` le garde hors
  # de l'import automatique du démarrage. Pur.
  def self.create_script(name : String, raid : Int32, devices : Array(String), mountpoint : String, encrypted : Bool) : String
    lines = ["set -e"]
    labels = devices.map_with_index do |dev, i|
      label = "#{name}#{i}"
      lines << "gpart create -s gpt #{dev}"
      lines << "gpart add -t freebsd-zfs -a 1m -l #{label} #{dev}"
      "/dev/gpt/#{label}"
    end
    opts = "-o ashift=#{ASHIFT}"
    opts += " -o cachefile=none -O encryption=on -O keyformat=hex -O keylocation=prompt" if encrypted
    lines << "zpool create #{opts} -m #{mountpoint} #{name} #{vdev(raid, labels)}"
    lines.join("\n")
  end

  # Fragment vdev d'un `zpool create` (même convention que bootstrap). Pur.
  def self.vdev(raid : Int32, devices : Array(String)) : String
    case raid
    when  0 then devices.join(" ")
    when  1 then "mirror #{devices.join(" ")}"
    when  5 then "raidz #{devices.join(" ")}"
    when  6 then "raidz2 #{devices.join(" ")}"
    when  7 then "raidz3 #{devices.join(" ")}"
    when 10 then devices.each_slice(2).map { |pair| "mirror #{pair.join(" ")}" }.join(" ")
    else         raise ArgumentError.new("raid #{raid} non supporté pour un pool data")
    end
  end

  # Pool importé, ou importable (`zpool import` le liste) ?
  private def self.present?(conn : Beryl::CLI::RootConn, name : String) : Bool
    return true if conn.exec("zpool list -H -o name #{Process.quote(name)}", raise_on_error: false).success?
    listing = conn.exec("zpool import 2>/dev/null", raise_on_error: false).stdout
    listing.lines.any? { |l| l.strip == "pool: #{name}" }
  end

  # Raison de refuser un disque (absent, déjà partitionné, système de
  # fichiers ou label ZFS), nil s'il est vierge.
  private def self.refusal(conn : Beryl::CLI::RootConn, dev : String) : String?
    path = Process.quote("/dev/#{dev}")
    return "disque /dev/#{dev} absent" unless conn.exec("test -c #{path}", raise_on_error: false).success?
    return "disque /dev/#{dev} déjà partitionné (gpart show)" if conn.exec("gpart show #{Process.quote(dev)}", raise_on_error: false).success?
    return "disque /dev/#{dev} porte un système de fichiers (fstyp)" if conn.exec("fstyp #{path}", raise_on_error: false).success?
    return "disque /dev/#{dev} porte un label ZFS (zdb -l)" if conn.exec("zdb -l #{path}", raise_on_error: false).success?
    nil
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl zpool-create] #{message}"
  end
end
