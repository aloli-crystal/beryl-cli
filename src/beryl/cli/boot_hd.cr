require "option_parser"
require "ovh-api/ovh_api"
require "../inventory"
require "./credentials"
require "./rescue"

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
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl boot-hd <host> [options]\n\n" \
                 "Bascule le netboot sur le disque via l'API OVH et déclenche un\n" \
                 "reboot. Attend ensuite que l'OS installé réponde en SSH."
      p.on("--no-wait", "Ne pas attendre le retour SSH") { wait = false }
      p.on("--user=USER", "User pour le test SSH post-reboot (défaut : admin)") { |v| user = v }
      p.on("--timeout=MIN", "Délai d'attente maximum en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") do |v|
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

    inventory = Beryl::Inventory.load(inventory_path)
    host = inventory.find(host_name)

    unless host.provider == "ovh"
      STDERR.puts "beryl : boot-hd n'est implémenté que pour provider `ovh` (hôte #{host.name} : #{host.provider || "inconnu"})."
      return EXIT_BAD_PROVIDER
    end

    service_name = host.ovh_service_name
    unless service_name
      STDERR.puts "beryl : champ `ovh.service_name` manquant pour #{host.name} dans l'inventaire."
      return EXIT_MISSING_CONFIG
    end

    # Purge ~/.ssh/known_hosts : on change la clé d'hôte (rescue Linux
    # → FreeBSD installée). Évite un futur « REMOTE HOST IDENTIFICATION
    # HAS CHANGED » côté utilisateur.
    Beryl.clean_known_hosts(host.name, host.port)

    log "OVH : boot_from_disk pour #{service_name}"
    client = ovh_client_factory.call
    task = client.dedicated_servers.boot_from_disk(service_name)
    log "OVH : tâche ##{task.id} (#{task.function}) en #{task.status}"

    if wait
      wait_ovh_task_done(client, service_name, task, task_poll_interval)
      log "attente du retour SSH sur #{host.name} (port #{host.port}, user #{user}, timeout #{timeout.total_minutes.to_i} min)"
      if wait_for_ssh.call(host.name, host.port, user, timeout, Beryl::CLI::Rescue::SSH_POLL_INTERVAL)
        log "ready : SSH répond sur #{host.name} en #{user}"
        EXIT_OK
      else
        STDERR.puts "beryl : timeout — SSH n'a pas répondu sur #{host.name} au bout de #{timeout.total_minutes.to_i} min"
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
end
