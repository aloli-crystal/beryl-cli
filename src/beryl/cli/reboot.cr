require "option_parser"
require "./option_errors"
require "api-ovh/ovh_api"
require "api-scaleway/scaleway_api"
require "ssh"
require "../config"
require "./account_utils"
require "./credentials"
require "./rescue"
require "./unlock"
require "./machine_kind"

# Sous-commande `beryl reboot <host> [--soft|--hard]` (étape H3) :
# redémarre un host puis (optionnellement) déverrouille les pools
# chiffrés et relance les services applicatifs.
#
# Deux modes :
#
#   --soft (défaut) : par la connexion de beryl (compte `connect_user`,
#     rebond compris), `shutdown -r now` (FreeBSD) ou `systemctl reboot`
#     (Linux), par `sudo -n` hors root. Sécurise (le serveur synchronise
#     ses disques, ferme proprement les services). Échoue si SSH ou sudo
#     refuse.
#   --hard          : power cycle via API hébergeur (équivalent bouton
#     power physique). Marche TOUJOURS, ne dépend pas de l'état du
#     système. Indispensable quand sshd ne répond plus (kernel panic,
#     freeze) et qu'on n'a pas d'IPMI/KVM.
#
# Après reboot, attend que la machine réponde avec un NOUVEL identifiant de
# démarrage (`boot_id` / `kern.boottime`, preuve d'un vrai redémarrage), puis (si pools chiffrés déclarés)
# enchaîne automatiquement avec un `beryl unlock` pour rouvrir les
# datasets et redémarrer les services.
module Beryl::CLI::Reboot
  EXIT_OK             = 0
  EXIT_USAGE          = 1
  EXIT_SSH_FAILED     = 2
  EXIT_UNEXPECTED     = 3
  EXIT_BAD_CREDS      = 4
  EXIT_BAD_PROVIDER   = 5
  EXIT_MISSING_CONFIG = 6
  EXIT_API_ERROR      = 7
  EXIT_UNLOCK_FAILED  = 8
  EXIT_REBOOT_FAILED  = 9

  DEFAULT_SSH_WAIT_TIMEOUT = 10.minutes
  SSH_POLL_INTERVAL        = 15.seconds
  REBOOT_GRACE_PERIOD      = 30.seconds

  def self.run(config_root : String, args : Array(String)) : Int32
    mode : Symbol = :soft
    wait = true
    skip_unlock = false
    timeout = DEFAULT_SSH_WAIT_TIMEOUT
    account_hint : String? = nil
    domain_hint : String? = nil
    provider_override : String? = nil
    dry_run = true
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl reboot <host> [--soft|--hard] [options]"
      p.on("--soft", "Reboot via SSH (shutdown -r now / systemctl reboot, sudo hors root). Défaut.") { mode = :soft }
      p.on("--hard", "Reboot via API hébergeur (power cycle). Marche même si sshd ne répond plus.") { mode = :hard }
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (utilisé pour --hard)") { |v| provider_override = v }
      p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
      p.on("-W", "--no-wait", "Ne pas attendre le retour SSH") { wait = false }
      p.on("-U", "--no-unlock", "Ne pas tenter de déverrouiller les pools chiffrés après reboot") { skip_unlock = true }
      p.on("-t MIN", "--timeout=MIN", "Timeout SSH en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") { |v| timeout = v.to_i.minutes }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl reboot <host> [--soft|--hard]"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    return EXIT_BAD_PROVIDER if mode == :hard && Beryl::CLI::MachineKind.refuse_vps(host, "reboot --hard")
    host.apply_all_credentials_to_env!

    target = Beryl.format_ssh_target(host)
    encrypted_pools = host.data_zpools.select(&.encrypted?)
    has_encrypted = !encrypted_pools.empty?

    log "H3 reboot #{target} mode=#{mode}#{has_encrypted ? " (#{encrypted_pools.size} pool(s) chiffré(s) à rouvrir)" : ""}"

    if dry_run
      case mode
      when :soft
        log "H3 DRY-RUN : ssh #{host.connect_user}@#{host.ssh_host} → #{host.connect_user == "root" ? "" : "sudo "}" \
            "shutdown -r now (FreeBSD) / systemctl reboot (Linux)"
      when :hard
        log "H3 DRY-RUN : API #{host.provider || "?"} → power cycle (équivalent bouton physique)"
      end
      log "H3 DRY-RUN : attente du redémarrage (preuve : l'identifiant de démarrage change), #{timeout.total_minutes.to_i} min au plus" if wait
      if has_encrypted && !skip_unlock
        log "H3 DRY-RUN : puis beryl unlock #{host.account_name}/#{host.fqdn}"
      end
      return EXIT_OK
    end

    # Connexion de beryl (compte `connect_user`, rebond `proxy_command` /
    # `proxy_jump` compris) : sert à relever l'identifiant de démarrage avant
    # et après, donc à PROUVER le redémarrage.
    conn = host.connection
    before = boot_marker(conn)

    case mode
    when :soft
      return EXIT_REBOOT_FAILED unless trigger_soft_reboot(host, conn)
    when :hard
      effective_provider = provider_override || host.provider
      return EXIT_BAD_PROVIDER unless effective_provider
      ok = trigger_hard_reboot(host, effective_provider)
      return EXIT_REBOOT_FAILED unless ok
    end

    return EXIT_OK unless wait

    log "H3.1 attente du redémarrage de #{target} (preuve : l'identifiant de démarrage change), #{timeout.total_minutes.to_i} min au plus — une ligne toutes les #{SSH_POLL_INTERVAL.total_seconds.to_i} s"
    unless wait_for_reboot(conn, before, timeout)
      STDERR.puts "beryl : #{target} n'a pas redémarré, ou ne répond plus, après #{timeout.total_minutes.to_i} min"
      return EXIT_SSH_FAILED
    end
    log "H3.2 #{target} a redémarré et répond"

    if has_encrypted && !skip_unlock
      log "H3.3 enchaînement avec beryl unlock pour les #{encrypted_pools.size} pool(s) chiffré(s)"
      # On ré-utilise la commande unlock comme une fonction.
      unlock_args = ["#{host.account_name}/#{host.fqdn}"]
      ec = Beryl::CLI::Unlock.run(config_root, unlock_args)
      if ec != Beryl::CLI::Unlock::EXIT_OK
        STDERR.puts "beryl : reboot OK mais unlock a échoué (code #{ec}). Réessayez avec : beryl unlock #{host.account_name}/#{host.fqdn}"
        return EXIT_UNLOCK_FAILED
      end
    end

    log "H3 reboot #{target} terminé"
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
  rescue ex : Beryl::CLI::Credentials::MissingCredentials
    STDERR.puts "beryl : #{ex.message}"
    EXIT_BAD_CREDS
  rescue ex : OvhApi::Error
    STDERR.puts "beryl : erreur API OVH — #{ex.message}"
    EXIT_API_ERROR
  rescue ex : ScalewayApi::Error
    STDERR.puts "beryl : erreur API Scaleway — #{ex.message}"
    EXIT_API_ERROR
  rescue ex : DediboxApi::ApiError
    STDERR.puts "beryl : erreur API Dedibox — #{ex.message}"
    EXIT_API_ERROR
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Identifiant du démarrage en cours : `boot_id` (Linux), sinon
  # `kern.boottime` (FreeBSD). Il change à chaque démarrage : c'est la
  # preuve qu'un redémarrage a VRAIMENT eu lieu (un sshd qui répond ne
  # prouve rien). Enveloppé dans `sh -c` : le shell de connexion peut être
  # csh, qui lit mal les redirections.
  BOOT_MARKER = "sh -c 'cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime'"

  # Commande qui lance le redémarrage en arrière-plan (la session SSH rend
  # la main avant que le système ne s'arrête) : `systemctl reboot` sous
  # Linux, `shutdown -r now` sur FreeBSD, par `sudo -n` hors root.
  def self.reboot_command(uname : String, root : Bool) : String
    stop = uname == "Linux" ? "systemctl reboot" : "shutdown -r now"
    sudo = root ? "" : "sudo -n "
    %(sh -c '#{sudo}nohup sh -c "sleep 2; #{stop}" >/dev/null 2>&1 &')
  end

  # Redémarré : la machine répond, avec un identifiant de démarrage
  # différent de celui relevé avant (ou, s'il était inconnu, n'importe lequel).
  def self.rebooted?(before : String?, after : String?) : Bool
    return false if after.nil? || after.empty?
    before.nil? || before.empty? || before != after
  end

  # Identifiant de démarrage lu par la connexion de beryl (rebond compris :
  # `proxy_command` / `proxy_jump`), nil si la machine ne répond pas.
  private def self.boot_marker(conn : SSH::Connection) : String?
    res = conn.exec(BOOT_MARKER, raise_on_error: false)
    res.success? ? res.stdout.strip : nil
  rescue
    nil
  end

  # Reboot soft : par la connexion de beryl (compte `connect_user`, rebond
  # compris), `sudo -n` hors root. Renvoie false si SSH ou sudo refuse —
  # jamais de faux succès.
  private def self.trigger_soft_reboot(host : Beryl::Config::ResolvedHost, conn : SSH::Connection) : Bool
    user = host.connect_user
    uname = conn.exec("uname -s", raise_on_error: false)
    unless uname.success?
      STDERR.puts "beryl : SSH #{user}@#{host.ssh_host} ne répond pas — #{uname.stderr.strip}"
      STDERR.puts "        Si le serveur est freezé, utilisez `--hard` pour forcer un power cycle via l'API hébergeur."
      return false
    end
    root = user == "root"
    if !root && !conn.exec("sudo -n true", raise_on_error: false).success?
      STDERR.puts "beryl : #{user} ne peut pas sudo sans mot de passe sur #{host.fqdn} — redémarrage impossible"
      return false
    end
    command = reboot_command(uname.stdout.strip, root)
    log "H3.0 SSH #{user}@#{host.ssh_host} → #{command}"
    conn.exec(command, raise_on_error: false)
    true
  rescue ex
    STDERR.puts "beryl : SSH a échoué pour le reboot soft — #{ex.class}: #{ex.message}"
    STDERR.puts "        Si le serveur est freezé, utilisez `--hard` pour forcer un power cycle via l'API hébergeur."
    false
  end

  # Ce que montre une tentative, pour l'affichage pendant l'attente.
  def self.poll_status(before : String?, after : String?) : String
    if after.nil? || after.empty?
      "pas de réponse (redémarrage en cours)"
    elsif rebooted?(before, after)
      "redémarrée"
    else
      "répond encore sur l'ancien démarrage"
    end
  end

  # Attend que la machine réponde avec un NOUVEL identifiant de démarrage,
  # une ligne par tentative (temps écoulé + constat).
  private def self.wait_for_reboot(conn : SSH::Connection, before : String?, timeout : Time::Span) : Bool
    start = Time.instant
    deadline = start + timeout
    sleep REBOOT_GRACE_PERIOD
    loop do
      after = boot_marker(conn)
      elapsed = (Time.instant - start).total_seconds.to_i
      log "H3.1 #{elapsed // 60} min #{(elapsed % 60).to_s.rjust(2, '0')} s : #{poll_status(before, after)}"
      return true if rebooted?(before, after)
      return false if Time.instant >= deadline
      sleep SSH_POLL_INTERVAL
    end
  end

  # Reboot hard : API hébergeur. Une branche par provider, suivant les
  # primitives déjà câblées côté `qemu_in_rescue.cr#reboot_bare_metal`.
  private def self.trigger_hard_reboot(host : Beryl::Config::ResolvedHost, provider : String) : Bool
    case provider
    when "ovh"
      service_name = host.ovh_service_name
      unless service_name
        STDERR.puts "beryl : champ `ovh.service_name` manquant pour #{host.fqdn}"
        return false
      end
      log "H3.0 OVH : boot_from_disk(#{service_name}) [équivalent power cycle hard]"
      Beryl::CLI::Credentials.ovh_client.dedicated_servers.boot_from_disk(service_name)
      sleep REBOOT_GRACE_PERIOD
      true
    when "dedibox"
      sid_str = host.dedibox_server_id
      unless sid_str
        STDERR.puts "beryl : champ `dedibox.server_id` manquant pour #{host.fqdn}"
        return false
      end
      sid = sid_str.to_i? || (STDERR.puts("beryl : dedibox.server_id non entier : #{sid_str}"); return false)
      log "H3.0 Dedibox : reboot_to_disk(#{sid})"
      Beryl::CLI::Credentials.dedibox_client.servers.reboot_to_disk(sid, reason: "beryl reboot --hard")
      sleep REBOOT_GRACE_PERIOD
      true
    when "scaleway"
      sid = host.scaleway_server_id
      unless sid
        STDERR.puts "beryl : champ `scaleway.server_id` manquant pour #{host.fqdn}"
        return false
      end
      log "H3.0 Scaleway : reboot(#{sid}, boot_type=Normal)"
      Beryl::CLI::Credentials.scaleway_client.baremetal.servers.reboot(
        server_id: sid,
        zone: host.scaleway_zone,
        boot_type: ScalewayApi::Endpoints::Baremetal::BootType::Normal,
      )
      sleep REBOOT_GRACE_PERIOD
      true
    else
      STDERR.puts "beryl : reboot --hard non implémenté pour provider #{provider} (connus : ovh, dedibox, scaleway)"
      false
    end
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl reboot] #{message}"
  end
end
