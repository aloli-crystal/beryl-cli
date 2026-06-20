require "option_parser"
require "ssh"
require "../config"
require "./account_utils"

# Sous-commande `beryl lock <host>` — symétrique INVERSE de `beryl unlock`.
# Verrouille les pools data chiffrés : `zpool export` démonte les datasets,
# décharge la clé (la rend indisponible) et retire le pool du système. Après
# `lock`, `beryl status` montre le pool ABSENT (chiffré, clé non chargée).
#
# ⚠️ ÉVOLUTION PRÉVUE (2ᵉ temps, Philippe 20 juin 2026) — COMMANDE PANIQUE :
# `beryl lock` doit verrouiller TOUTE l'architecture d'un coup, pas que les pools
# data : aussi les DATASETS zroot chiffrés (`zfs unmount` + `zfs unload-key` sur
# `zroot/zhome`,`zroot/zopt`,`zroot/zusrlocaletc`), après avoir arrêté les services
# qui les utilisent (`requires_dataset:`). Usage = bouton panique incident sécu.
# La version actuelle ne couvre QUE l'export des pools data — l'extension datasets
# zroot viendra avec le chantier chiffrement C+ (cf. zpool-encryption-architecture
# § Amendement 20 juin).
#
# Mode-agnostique : que le pool soit en `ssh_unlock` ou `tang`, le verrouillage
# est identique (export). AUCUNE clé n'est nécessaire côté opérateur (≠ unlock).
#
# Idempotent : un pool déjà exporté (non importé) → no-op.
#
# Commandes distantes csh-safe (root FreeBSD = csh par défaut) : pas de
# redirection Bourne `2>` — `SSH::Connection` capture stderr séparément.
module Beryl::CLI::Lock
  EXIT_OK            = 0
  EXIT_USAGE         = 1
  EXIT_SSH_FAILED    = 2
  EXIT_UNEXPECTED    = 3
  EXIT_NO_DATA_POOLS = 5
  EXIT_LOCK_FAILED   = 6

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    dry_run = false
    force = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl lock <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche les commandes sans les exécuter") { dry_run = true }
      p.on("-f", "--force", "Force l'export même si des datasets sont occupés (zpool export -f)") { force = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl lock <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

    encrypted_pools = host.data_zpools.select(&.encrypted?)
    if encrypted_pools.empty?
      STDERR.puts "beryl : aucun pool data avec `encryption: ...` déclaré pour #{host.fqdn}"
      STDERR.puts "        (pools data trouvés : #{host.data_zpools.map(&.name).join(", ")})"
      return EXIT_NO_DATA_POOLS
    end

    target = Beryl.format_ssh_target(host)
    summary = encrypted_pools.map(&.name).join(", ")
    log "lock #{target} : #{encrypted_pools.size} pool(s) chiffré(s) à verrouiller (#{summary})"

    if dry_run
      log "DRY-RUN : SSH root@#{host.ssh_host}:#{host.port}"
      encrypted_pools.each do |pool|
        log "DRY-RUN :   zpool export #{force ? "-f " : ""}#{pool.name}"
      end
      return EXIT_OK
    end

    conn = host.connection
    failures = 0
    encrypted_pools.each do |pool|
      begin
        lock_one(conn, pool, force)
      rescue ex
        STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl lock] " \
                    "ÉCHEC pool #{pool.name} : #{ex.class}: #{ex.message}"
        failures += 1
      end
    end

    if failures > 0
      STDERR.puts "beryl : #{failures}/#{encrypted_pools.size} pool(s) non verrouillé(s)"
      return EXIT_LOCK_FAILED
    end

    log "lock #{target} : terminé (#{encrypted_pools.size} pool(s) verrouillé(s) + exporté(s))"
    EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : SSH a échoué — #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Verrouille un pool : `zpool export` (démonte datasets + décharge la clé +
  # retire le pool). Idempotent : pool non importé → no-op.
  private def self.lock_one(conn : SSH::Connection, pool : Beryl::Config::Pool, force : Bool) : Nil
    pool_name = pool.name
    target = "#{conn.user}@#{conn.host}"

    listed = conn.exec("zpool list -H -o name #{Process.quote(pool_name)}", raise_on_error: false)
    imported = listed.success? && listed.stdout.strip == pool_name
    unless imported
      log "  pool #{pool_name} déjà verrouillé (non importé) sur #{target}"
      return
    end

    flag = force ? "-f " : ""
    log "  zpool export #{flag}#{pool_name} (sur #{target})"
    result = conn.exec("zpool export #{flag}#{Process.quote(pool_name)}", raise_on_error: false)
    unless result.success?
      hint = (result.stderr.includes?("busy") || result.stderr.downcase.includes?("occup")) ? " — datasets occupés (arrêtez les services, ou relancez avec `-f`)" : ""
      raise "zpool export #{pool_name} a échoué : exit=#{result.exit_code} " \
            "stderr=#{result.stderr.strip.inspect}#{hint}"
    end
    log "  pool #{pool_name} verrouillé (clé déchargée, pool exporté)"
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl lock] #{message}"
  end
end
