require "option_parser"
require "ovh-api/ovh_api"
require "../inventory"
require "./credentials"
require "./rescue"
require "./host_resolver"

# Sous-commande `beryl boot-hd <host>` : bascule un serveur OVH en
# netboot `harddisk` via l'API et déclenche un reboot. Inverse de
# `beryl rescue`. Pratique après bootstrap ou pour sortir manuellement
# d'un mode rescue sans passer par le panel web.
#
# Pour Scaleway, non implémenté ici : la bascule rescue/production passe
# par `servers.reboot(boot_type:)` qui a sa propre sémantique.
#
# Contrairement à `beryl rescue`, pas d'injection de clé SSH (on revient
# sur la FreeBSD installée, sa propre clé d'hôte s'applique).
module Beryl::CLI::BootHd
  EXIT_OK             = 0
  EXIT_USAGE          = 1
  EXIT_SSH_FAILED     = 2
  EXIT_UNEXPECTED     = 3
  EXIT_BAD_CREDS      = 4
  EXIT_BAD_PROVIDER   = 5
  EXIT_MISSING_CONFIG = 6
  EXIT_API_ERROR      = 7
  EXIT_TASK_FAILED    = 9

  DEFAULT_SSH_WAIT_TIMEOUT = 10.minutes
  TASK_WAIT_TIMEOUT        = 5.minutes
  TASK_POLL_INTERVAL       = 10.seconds

  alias OvhClientFactory = -> OvhApi::Client

  def self.run(
    inventory_path : String,
    args : Array(String),
    ovh_client_factory : OvhClientFactory = -> { Beryl::CLI::Credentials.ovh_client },
    wait_for_ssh : Proc(String, Int32, String, Time::Span, Time::Span, Bool) = ->Beryl::CLI::Rescue.default_wait_for_ssh(String, Int32, String, Time::Span, Time::Span),
    task_poll_interval : Time::Span = TASK_POLL_INTERVAL,
  ) : Int32
    wait = true
    user = "admin"
    timeout = DEFAULT_SSH_WAIT_TIMEOUT
    provider_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl boot-hd <host> [options]\n\n" \
                 "Bascule le netboot sur le disque via l'API OVH et déclenche un\n" \
                 "reboot. Attend ensuite que l'OS installé réponde en SSH.\n" \
                 "Accepte un nom d'inventaire OU un service_name OVH nu."
      p.on("-p NAME", "--provider=NAME", "Provider (ovh) pour un host hors inventaire") { |v| provider_hint = v }
      p.on("-n", "--no-wait", "Ne pas attendre le retour SSH") { wait = false }
      p.on("-u USER", "--user=USER", "User pour le test SSH post-reboot (défaut : admin)") { |v| user = v }
      p.on("-t MIN", "--timeout=MIN", "Délai d'attente maximum en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") do |v|
        timeout = v.to_i.minutes
      end
      p.on("-h", "--help", "Aide") do
        puts p
        exit 0
      end
      p.unknown_args do |rest, _|
        positional = rest
      end
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl boot-hd <host>"
      return EXIT_USAGE
    end

    host = Beryl::CLI::HostResolver.resolve(inventory_path, host_name, provider_hint)

    unless host.provider == "ovh"
      STDERR.puts "beryl : boot-hd n'est implémenté que pour provider `ovh` (hôte #{host.name} : #{host.provider || "inconnu"})."
      return EXIT_BAD_PROVIDER
    end

    service_name = host.ovh_service_name
    unless service_name
      STDERR.puts "beryl : champ `ovh.service_name` manquant pour #{host.name} dans l'inventaire."
      return EXIT_MISSING_CONFIG
    end

    # Purge ~/.ssh/known_hosts pour les deux noms potentiels : on
    # change la clé d'hôte (rescue Linux → FreeBSD installée). Évite
    # un futur « REMOTE HOST IDENTIFICATION HAS CHANGED » que
    # l'utilisateur se connecte par le nom logique ou par le FQDN OVH.
    Beryl.clean_known_hosts_for(host)

    client = ovh_client_factory.call
    task = log_step("OVH : boot_from_disk pour #{service_name}") do
      client.dedicated_servers.boot_from_disk(service_name)
    end
    log "OVH : tâche ##{task.id} (#{task.function}) en #{task.status}"

    if wait
      log_step("OVH : attente fin de tâche hardReboot") do
        wait_ovh_task_done(client, service_name, task, task_poll_interval)
      end
      target_for_log = Beryl.format_ssh_target(host)
      ssh_ok = log_step("attente SSH sur #{target_for_log} (port #{host.port}, user #{user}, timeout #{timeout.total_minutes.to_i} min)") do
        wait_for_ssh.call(host.ssh_host, host.port, user, timeout, Beryl::CLI::Rescue::SSH_POLL_INTERVAL)
      end
      if ssh_ok
        log "ready : SSH répond sur #{target_for_log} en #{user}"
        EXIT_OK
      else
        STDERR.puts "beryl : timeout — SSH n'a pas répondu sur #{target_for_log} au bout de #{timeout.total_minutes.to_i} min"
        EXIT_SSH_FAILED
      end
    else
      log "commande boot-hd envoyée à l'API ; attente SSH désactivée (--no-wait)"
      EXIT_OK
    end
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : TaskFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_TASK_FAILED
  rescue ex : Beryl::CLI::Credentials::MissingCredentials
    STDERR.puts "beryl : #{ex.message}"
    EXIT_BAD_CREDS
  rescue ex : OvhApi::Error
    STDERR.puts "beryl : erreur API OVH — #{ex.message}"
    EXIT_API_ERROR
  rescue ex : File::NotFoundError
    STDERR.puts "beryl : inventaire introuvable : #{inventory_path}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  class TaskFailed < Exception
  end

  # Poll la task OVH jusqu'à `done` (ou terminale différente de done).
  # Même logique que dans beryl rescue : évite de polle SSH avant que
  # le reboot soit effectif (sinon on tombe sur l'ancien OS qui répond).
  private def self.wait_ovh_task_done(
    client : OvhApi::Client,
    service_name : String,
    task : OvhApi::Endpoints::Task,
    poll_interval : Time::Span,
  ) : Nil
    deadline = Time.instant + TASK_WAIT_TIMEOUT
    last_status = task.status
    current = task
    while Time.instant < deadline
      return if current.success?
      if current.failed? || current.status == "cancelled"
        raise TaskFailed.new(
          "tâche OVH ##{current.id} (#{current.function}) terminée en #{current.status} — #{current.comment}"
        )
      end
      sleep poll_interval
      current = client.dedicated_servers.task(service_name, task.id)
      if current.status != last_status
        log "OVH : tâche ##{current.id} → #{current.status}"
        last_status = current.status
      end
    end
    raise TaskFailed.new(
      "tâche OVH ##{task.id} (#{task.function}) non aboutie après #{TASK_WAIT_TIMEOUT.total_minutes.to_i} min"
    )
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl boot-hd] #{message}"
  end

  # Même pattern que Rescue.log_step : affiche la ligne, spawn un fiber
  # qui tick le compteur [NNNs] toutes les secondes, et fige le compteur
  # sur un retour chariot quand le bloc termine.
  private def self.log_step(label : String, & : -> T) : T forall T
    line = "[#{Beryl.format_timestamp(Time.local)}] [beryl boot-hd] #{label}"
    pad = Beryl.pad_to(line)
    STDERR.print "#{line}#{pad}  [   0s]"
    STDERR.flush
    start = Time.instant
    done = Channel(Nil).new
    spawn do
      loop do
        select
        when done.receive?
          break
        when timeout(1.second)
          elapsed = (Time.instant - start).total_seconds.to_i
          STDERR.printf("\r%s%s  [%4ds]", line, pad, elapsed)
          STDERR.flush
        end
      end
    end
    success = false
    begin
      result = yield
      success = true
      elapsed = (Time.instant - start).total_seconds.to_i
      STDERR.printf("\r%s%s  [%4ds]\n", line, pad, elapsed)
      result
    ensure
      done.send(nil)
      unless success
        elapsed = (Time.instant - start).total_seconds.to_i
        STDERR.printf("\r%s%s  [%4ds] ✗\n", line, pad, elapsed)
      end
    end
  end
end
