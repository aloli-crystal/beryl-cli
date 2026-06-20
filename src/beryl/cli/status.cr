require "option_parser"
require "ssh"
require "../config"
require "./account_utils"

# Sous-commande `beryl status <host>` (étape H5) : affiche un état
# bref des pools ZFS et des services sshd / cron / pf sur un host.
# Utile principalement après un reboot pour voir d'un coup d'œil ce
# qui demande un `beryl unlock`.
#
# Sortie typique :
#
#   Pools :
#     zroot   ONLINE   monté
#     zsave   ABSENT   (pool non importé — chiffré, clé non chargée)
#
#   Services :
#     sshd         : up
#     cron         : up
#     pf           : up
module Beryl::CLI::Status
  EXIT_OK         = 0
  EXIT_USAGE      = 1
  EXIT_SSH_FAILED = 2
  EXIT_UNEXPECTED = 3

  # Services standard remontés par défaut. Une recette `apply` future
  # pourra étendre via `requires_dataset` (cf. apply-recipes-architecture.adoc).
  DEFAULT_SERVICES = %w[sshd cron]

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    extra_services = [] of String
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl status <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-S NAME", "--service=NAME", "Service supplémentaire à interroger (peut être répété)") { |v| extra_services << v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl status <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

    target = Beryl.format_ssh_target(host)
    log "H5 status #{target}"

    services = DEFAULT_SERVICES + extra_services
    declared_pools = host.zpools

    conn = host.connection

    # --- Pools ---
    puts ""
    puts "Pools :"
    declared_pools.each do |pool|
      info = pool_status(conn, pool)
      puts "  #{pool.name.ljust(8)} #{info[:state].ljust(8)} #{info[:detail]}"
    end

    # --- Datasets zroot chiffrés (profil Option I) ---
    # L'encryptionroot `zroot/encrypted` est un DATASET enfant du pool boot,
    # pas un pool : son état de verrou n'apparaît pas dans la liste des pools
    # ci-dessus (le pool zroot lui-même reste clair/ONLINE). `find(&.boot)`
    # renvoie nil si pas de pool boot (config data-only) → section sautée.
    if er = declared_pools.find(&.boot).try(&.encryption_root)
      puts ""
      puts "Datasets zroot chiffrés :"
      info = encryption_root_status(conn, er)
      puts "  #{er.ljust(16)} #{info[:state].ljust(8)} #{info[:detail]}"
    end

    # --- Services ---
    puts ""
    puts "Services :"
    services.each do |svc|
      state = service_status(conn, svc)
      puts "  #{svc.ljust(12)} : #{state}"
    end
    puts ""

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

  # Statut d'un pool. États possibles dans la sortie :
  #
  #   ONLINE   : pool importé, datasets accessibles
  #   ABSENT   : pool non importé (chiffré, clé non chargée, ou non créé)
  #   LOCKED   : pool importé mais clé non chargée (cas chiffré pas-encore-unlock)
  #   DEGRADED : pool importé mais en état dégradé (un disque tombé)
  #   FAULTED  : pool importé mais en panne complète
  private def self.pool_status(conn : SSH::Connection, pool : Beryl::Config::Pool) : NamedTuple(state: String, detail: String)
    listed = conn.exec("zpool list -H -o health #{Process.quote(pool.name)}", raise_on_error: false)
    unless listed.success? && !listed.stdout.strip.empty?
      detail = pool.encrypted? ? "(pool non importé — chiffré, clé non chargée)" : "(pool absent)"
      return {state: "ABSENT", detail: detail}
    end

    health = listed.stdout.strip

    # Statut de la clé (datasets chiffrés). Si keystatus = unavailable,
    # le pool est importé mais on ne peut pas lire les données → LOCKED.
    if pool.encrypted?
      keystatus = conn.exec("zfs get -H -o value keystatus #{Process.quote(pool.name)}", raise_on_error: false)
      if keystatus.success?
        ks = keystatus.stdout.strip
        if ks == "unavailable"
          return {state: "LOCKED", detail: "(importé mais clé non chargée — beryl unlock)"}
        end
      end
    end

    # Liste des datasets montés du pool — donne un aperçu vivant.
    mounted = conn.exec(
      "zfs list -H -o name,mounted -r #{Process.quote(pool.name)}",
      raise_on_error: false,
    )
    mount_summary = "monté"
    if mounted.success?
      total = 0
      yes = 0
      mounted.stdout.lines.each do |line|
        next if line.strip.empty?
        total += 1
        yes += 1 if line.includes?("\tyes") || line.includes?(" yes")
      end
      mount_summary = "#{yes}/#{total} datasets montés"
    end

    case health
    when "ONLINE"   then {state: "ONLINE", detail: mount_summary}
    when "DEGRADED" then {state: "DEGRADED", detail: "(un ou plusieurs disques en défaut)"}
    when "FAULTED"  then {state: "FAULTED", detail: "(pool en panne)"}
    else                 {state: health, detail: ""}
    end
  end

  # Statut de l'encryptionroot zroot (profil Option I). Ce n'est pas un pool
  # mais un dataset chiffré (`canmount=off`) dont les enfants sont /home, /opt,
  # /usr/local/etc. États :
  #
  #   UNLOCKED : clé chargée (keystatus=available) — enfants montables/montés
  #   LOCKED   : clé non chargée → `beryl unlock`
  #   ABSENT   : dataset inexistant (host pas bootstrappé en profil Option I)
  private def self.encryption_root_status(conn : SSH::Connection, enc_root : String) : NamedTuple(state: String, detail: String)
    keystatus = conn.exec("zfs get -H -o value keystatus #{Process.quote(enc_root)}", raise_on_error: false)
    unless keystatus.success? && !keystatus.stdout.strip.empty? && keystatus.stdout.strip != "-"
      return {state: "ABSENT", detail: "(dataset chiffré absent — host pas en profil Option I ?)"}
    end

    ks = keystatus.stdout.strip
    if ks != "available"
      return {state: "LOCKED", detail: "(clé non chargée — beryl unlock)"}
    end

    # Compte les datasets ENFANTS montés (on ignore l'encryptionroot lui-même,
    # qui est canmount=off donc jamais monté).
    mounted = conn.exec(
      "zfs list -H -o name,mounted -r #{Process.quote(enc_root)}",
      raise_on_error: false,
    )
    detail = "déverrouillé"
    if mounted.success?
      total = 0
      yes = 0
      mounted.stdout.lines.each do |line|
        next if line.strip.empty?
        next if line.split(/\s+/).first? == enc_root
        total += 1
        yes += 1 if line.includes?("\tyes") || line.includes?(" yes")
      end
      detail = "déverrouillé (#{yes}/#{total} datasets montés)"
    end
    {state: "UNLOCKED", detail: detail}
  end

  # Statut FreeBSD d'un service via `service <name> status`. Retourne
  # `up`, `down`, ou un état brut. La commande FreeBSD retourne 0 si
  # le service tourne, !=0 sinon.
  private def self.service_status(conn : SSH::Connection, name : String) : String
    # PAS de `2>&1` : sous csh (login shell de root sur FreeBSD) cette syntaxe
    # Bourne casse (le `2` devient un argument). On lit stdout ET stderr du
    # `SSH::Result` à la place — `service status` écrit son diagnostic sur l'un
    # ou l'autre selon les rc.d.
    result = conn.exec("service #{Process.quote(name)} status", raise_on_error: false)
    if result.success?
      "up"
    else
      out = "#{result.stdout.strip}\n#{result.stderr.strip}"
      if out.includes?("not running")
        "down"
      elsif out.includes?("does not exist") || out.empty?
        "absent"
      else
        "?"
      end
    end
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl status] #{message}"
  end
end
