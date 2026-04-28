require "option_parser"
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "ssh"
require "../config"
require "./account_utils"
require "./credentials"
require "./rescue"
require "./unlock"

# Sous-commande `beryl reboot <host> [--soft|--hard]` (étape H3) :
# redémarre un host puis (optionnellement) déverrouille les pools
# chiffrés et relance les services applicatifs.
#
# Deux modes :
#
#   --soft (défaut) : `shutdown -r now` via SSH. Sécurise (le serveur
#     synchronise ses disques, ferme proprement les services). Échoue
#     si SSH ne répond pas.
#   --hard          : power cycle via API hébergeur (équivalent bouton
#     power physique). Marche TOUJOURS, ne dépend pas de l'état du
#     système. Indispensable quand sshd ne répond plus (kernel panic,
#     freeze) et qu'on n'a pas d'IPMI/KVM.
#
# Après reboot, attend le retour SSH puis (si pools chiffrés déclarés)
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
    dry_run = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl reboot <host> [--soft|--hard] [options]"
      p.on("--soft", "Reboot via SSH (shutdown -r now). Défaut.") { mode = :soft }
      p.on("--hard", "Reboot via API hébergeur (power cycle). Marche même si sshd ne répond plus.") { mode = :hard }
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (utilisé pour --hard)") { |v| provider_override = v }
      p.on("-n", "--dry-run", "Affiche les actions sans les exécuter") { dry_run = true }
      p.on("-W", "--no-wait", "Ne pas attendre le retour SSH") { wait = false }
      p.on("-U", "--no-unlock", "Ne pas tenter de déverrouiller les pools chiffrés après reboot") { skip_unlock = true }
      p.on("-t MIN", "--timeout=MIN", "Timeout SSH en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") { |v| timeout = v.to_i.minutes }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

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
    host.apply_all_credentials_to_env!

    target = Beryl.format_ssh_target(host)
    encrypted_pools = host.data_zpools.select(&.encrypted?)
    has_encrypted = !encrypted_pools.empty?

    log "H3 reboot #{target} mode=#{mode}#{has_encrypted ? " (#{encrypted_pools.size} pool(s) chiffré(s) à rouvrir)" : ""}"

    if dry_run
      case mode
      when :soft
        log "H3 DRY-RUN : ssh root@#{host.ssh_host}:#{host.port} 'shutdown -r now'"
      when :hard
        log "H3 DRY-RUN : API #{host.provider || "?"} → power cycle (équivalent bouton physique)"
      end
      log "H3 DRY-RUN : attente retour SSH (timeout #{timeout.total_minutes.to_i}m)" if wait
      if has_encrypted && !skip_unlock
        log "H3 DRY-RUN : puis beryl unlock #{host.account_name}/#{host.fqdn}"
      end
      return EXIT_OK
    end

    case mode
    when :soft
      return EXIT_REBOOT_FAILED unless trigger_soft_reboot(host)
    when :hard
      effective_provider = provider_override || host.provider
      return EXIT_BAD_PROVIDER unless effective_provider
      ok = trigger_hard_reboot(host, effective_provider)
      return EXIT_REBOOT_FAILED unless ok
    end

    return EXIT_OK unless wait

    # Attente que sshd retombe (preuve que le reboot a effectivement
    # été pris en compte côté hardware), puis qu'il remonte.
    log "H3.1 attente de la chute de sshd (preuve que le reboot a démarré)"
    wait_for_ssh_drop(host)

    log "H3.2 attente retour SSH sur #{target} (timeout #{timeout.total_minutes.to_i} min)"
    ssh_ok = Beryl::CLI::Rescue.default_wait_for_ssh(
      host.ssh_host, host.port, host.user, timeout, SSH_POLL_INTERVAL,
    )
    unless ssh_ok
      STDERR.puts "beryl : timeout SSH après reboot sur #{target}"
      return EXIT_SSH_FAILED
    end

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

  # Reboot soft : SSH `shutdown -r now`. Renvoie false si SSH refuse.
  # Utilise `nohup` + `&` + redirect pour qu'un éventuel hang sur
  # le close de la session ne bloque pas le caller.
  private def self.trigger_soft_reboot(host : Beryl::Config::ResolvedHost) : Bool
    log "H3.0 SSH #{host.user}@#{host.ssh_host}:#{host.port} → shutdown -r now"
    conn = host.connection
    begin
      # `shutdown -r now` ferme la session SSH avant de retourner
      # un exit code propre — on ignore l'erreur de connexion.
      conn.exec("nohup shutdown -r now >/dev/null 2>&1 &", raise_on_error: false)
      sleep REBOOT_GRACE_PERIOD
      true
    rescue ex
      STDERR.puts "beryl : SSH a échoué pour le reboot soft — #{ex.class}: #{ex.message}"
      STDERR.puts "        Si le serveur est freezé, utilisez `--hard` pour forcer un power cycle via l'API hébergeur."
      false
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

  # Attend que le port SSH cesse de répondre (preuve que le reboot a
  # effectivement démarré côté hardware). Timeout court : si sshd
  # tient bon plus de 90s, c'est suspicieux mais on continue — le
  # `wait_for_ssh` qui suit confirmera ou infirmera.
  private def self.wait_for_ssh_drop(host : Beryl::Config::ResolvedHost) : Nil
    deadline = Time.instant + 90.seconds
    loop do
      break if Time.instant >= deadline
      begin
        TCPSocket.new(host.ssh_host, host.port, connect_timeout: 3.seconds).close
        sleep 3.seconds
      rescue
        return
      end
    end
    log "H3.1 sshd répond toujours après 90s — on continue (le reboot peut être lent ou se faire avec sshd qui tient longtemps)"
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl reboot] #{message}"
  end
end
