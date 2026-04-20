require "option_parser"
require "socket"
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "../inventory"
require "../ssh"
require "./credentials"

# Sous-commande `beryl rescue <host>` : bascule un hébergeur en mode
# rescue via son API (OVH ou Scaleway), puis attend que SSH réponde sur
# le rescue.
#
# Une fois la machine en rescue, l'opérateur peut enchaîner avec
# `beryl bootstrap <host> --disk ...` pour le flux QEMU-in-rescue
# (ADR-011).
#
# Côté testabilité, `run` expose deux *factories* injectables
# (`ovh_client_factory` / `scaleway_client_factory`). En usage normal,
# elles délèguent à `Beryl::CLI::Credentials` qui lit l'environnement.
# En test, on passe un lambda qui retourne un client configuré avec un
# transport HTTP stub.
module Beryl::CLI::Rescue
  # Temps maximum d'attente du SSH sur le rescue. Les rescues OVH et
  # Scaleway démarrent en 2-5 min ; on laisse une marge généreuse pour
  # les gammes chargées.
  DEFAULT_SSH_WAIT_TIMEOUT = 10.minutes

  # Intervalle entre deux tentatives de `ssh uname -s`. Ne pas descendre
  # en dessous sous peine de saturer le journal et d'agacer fail2ban côté
  # rescue.
  SSH_POLL_INTERVAL = 15.seconds

  # Intervalle de poll de la task OVH (reboot → done). Plus court que
  # l'attente SSH car ces tâches changent vite d'état (init → todo → doing
  # → done en ~30 s sur un reboot standard).
  TASK_POLL_INTERVAL = 10.seconds

  # Temps max d'attente pour que la task hardReboot atteigne son état
  # terminal. Les reboots OVH standards aboutissent en 2-3 min côté task
  # (le serveur met ensuite 2-4 min à démarrer SSH).
  TASK_WAIT_TIMEOUT = 5.minutes

  # Codes de retour internes (cohérents avec `cli.cr`).
  EXIT_OK             = 0
  EXIT_USAGE          = 1
  EXIT_SSH_FAILED     = 2
  EXIT_UNEXPECTED     = 3
  EXIT_BAD_CREDS      = 4
  EXIT_BAD_PROVIDER   = 5
  EXIT_MISSING_CONFIG = 6
  EXIT_API_ERROR      = 7
  EXIT_DNS            = 8
  EXIT_TASK_FAILED    = 9

  alias OvhClientFactory = -> OvhApi::Client
  alias ScalewayClientFactory = -> ScalewayApi::Client

  # Injectable pour les tests : par défaut `Socket::Addrinfo.resolve`.
  alias DnsResolver = String -> Bool

  # Levée quand le nom d'hôte n'est pas résolvable par le DNS local.
  class DnsResolutionFailed < Exception
  end

  # Levée quand la tâche OVH atteint un état terminal différent de `done`
  # (ovhError, customerError, cancelled) ou dépasse son timeout.
  class TaskFailed < Exception
  end

  # Point d'entrée principal de la sous-commande.
  #
  # Les *factories* sont injectables pour les tests : elles construisent
  # un client d'API prêt à l'emploi. En production, les valeurs par
  # défaut délèguent à `Beryl::CLI::Credentials.ovh_client` et
  # `scaleway_client` qui lisent les variables d'environnement.
  def self.run(
    inventory_path : String,
    args : Array(String),
    ovh_client_factory : OvhClientFactory = -> { Beryl::CLI::Credentials.ovh_client },
    scaleway_client_factory : ScalewayClientFactory = -> { Beryl::CLI::Credentials.scaleway_client },
    wait_for_ssh : Proc(String, Int32, String, Time::Span, Time::Span, Bool) = ->default_wait_for_ssh(String, Int32, String, Time::Span, Time::Span),
    dns_resolver : DnsResolver = ->default_dns_resolve(String),
    task_poll_interval : Time::Span = TASK_POLL_INTERVAL,
  ) : Int32
    wait = true
    timeout = DEFAULT_SSH_WAIT_TIMEOUT
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl rescue <host> [options]\n\n" \
                 "Bascule un hôte en mode rescue via l'API de l'hébergeur\n" \
                 "(OVH ou Scaleway) puis attend le retour de SSH sur le rescue."
      p.on("--no-wait", "Ne pas attendre le retour SSH (retour immédiat après l'appel API)") { wait = false }
      p.on("--timeout=MIN", "Délai d'attente maximum en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") do |v|
        timeout = v.to_i.minutes
      end
      p.on("-h", "--help", "Affiche cette aide") do
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
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl rescue <host>"
      return EXIT_USAGE
    end

    inventory = Beryl::Inventory.load(inventory_path)
    host = inventory.find(host_name)

    # Garde-fou DNS : inutile de déclencher un rescue si on ne pourra
    # jamais parler SSH au serveur après. Échoue tôt, avant l'API.
    unless dns_resolver.call(host.name)
      raise DnsResolutionFailed.new(
        "#{host.name} ne résout pas en DNS. Vérifiez l'orthographe (typo .fr vs .net ?) et votre résolveur."
      )
    end

    provider = host.provider
    case provider
    when "ovh"
      task = trigger_ovh(host, ovh_client_factory)
      wait_ovh_task_done(host, task, ovh_client_factory, task_poll_interval) if wait
    when "scaleway"
      trigger_scaleway(host, scaleway_client_factory)
    when nil
      STDERR.puts "beryl : provider non précisé pour #{host.name} (ajoutez `provider: ovh` ou `provider: scaleway` dans l'inventaire)"
      return EXIT_BAD_PROVIDER
    else
      STDERR.puts "beryl : provider « #{provider} » inconnu pour #{host.name} (attendu : ovh, scaleway)"
      return EXIT_BAD_PROVIDER
    end

    if wait
      log "attente du retour SSH sur #{host.name} (port #{host.port}, user root, timeout #{timeout.total_minutes.to_i} min)"
      if wait_for_ssh.call(host.name, host.port, "root", timeout, SSH_POLL_INTERVAL)
        log "ready : SSH répond sur #{host.name}"
        EXIT_OK
      else
        STDERR.puts "beryl : timeout — SSH n'a pas répondu sur #{host.name} au bout de #{timeout.total_minutes.to_i} min"
        EXIT_SSH_FAILED
      end
    else
      log "commande rescue envoyée à l'API ; attente SSH désactivée (--no-wait)"
      EXIT_OK
    end
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : DnsResolutionFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_DNS
  rescue ex : TaskFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_TASK_FAILED
  rescue ex : Beryl::CLI::Credentials::MissingCredentials
    STDERR.puts "beryl : #{ex.message}"
    EXIT_BAD_CREDS
  rescue ex : Beryl::CLI::Rescue::MissingProviderConfig
    STDERR.puts "beryl : #{ex.message}"
    EXIT_MISSING_CONFIG
  rescue ex : OvhApi::Error
    STDERR.puts "beryl : erreur API OVH — #{ex.message}"
    EXIT_API_ERROR
  rescue ex : ScalewayApi::Error
    STDERR.puts "beryl : erreur API Scaleway — #{ex.message}"
    EXIT_API_ERROR
  rescue ex : File::NotFoundError
    STDERR.puts "beryl : inventaire introuvable : #{inventory_path}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Levée quand un champ `ovh.service_name` ou similaire est absent.
  class MissingProviderConfig < Exception
  end

  private def self.trigger_ovh(host : Beryl::Host, ovh_client_factory : OvhClientFactory) : OvhApi::Endpoints::Task
    service_name = host.ovh_service_name || raise MissingProviderConfig.new(
      "champ `ovh.service_name` manquant pour #{host.name} dans l'inventaire"
    )
    ssh_key_name = host.ovh_ssh_key_name || raise MissingProviderConfig.new(
      "champ `ovh.ssh_key_name` manquant pour #{host.name} dans l'inventaire " \
      "(nom d'une clé déclarée dans /me/sshKey côté OVH)"
    )

    log "OVH : prepare_rescue pour #{service_name} (clé : #{ssh_key_name})"
    client = ovh_client_factory.call
    task = client.dedicated_servers.prepare_rescue(
      service_name: service_name,
      ssh_key_name: ssh_key_name,
    )
    log "OVH : tâche ##{task.id} (#{task.function}) en #{task.status}"
    task
  end

  private def self.trigger_scaleway(host : Beryl::Host, scaleway_client_factory : ScalewayClientFactory) : ScalewayApi::Endpoints::Baremetal::Server
    server_id = host.scaleway_server_id || raise MissingProviderConfig.new(
      "champ `scaleway.server_id` manquant pour #{host.name} dans l'inventaire"
    )
    zone = host.scaleway_zone

    log "Scaleway : reboot(Rescue) sur #{server_id}#{zone ? " (zone #{zone})" : ""}"
    client = scaleway_client_factory.call
    server = client.baremetal.servers.reboot(
      server_id: server_id,
      zone: zone,
      boot_type: ScalewayApi::Endpoints::Baremetal::BootType::Rescue,
    )
    log "Scaleway : serveur #{server.id} passé en status = #{server.status}"
    server
  end

  # Résolveur DNS par défaut. Retourne `true` si `host` a au moins une
  # adresse IP via `Socket::Addrinfo`, `false` sinon (NXDOMAIN, SERVFAIL,
  # erreur réseau…). On ne distingue pas le type d'échec côté API, mais
  # le message d'erreur capté est souvent suffisant pour diagnostiquer.
  def self.default_dns_resolve(host : String) : Bool
    Socket::Addrinfo.resolve(host, 22, type: Socket::Type::STREAM)
    true
  rescue Socket::Addrinfo::Error
    false
  end

  # Poll la task OVH jusqu'à son état terminal (`done`, `ovhError`,
  # `customerError`, `cancelled`) ou jusqu'au timeout. Affiche chaque
  # changement d'état. Lève `TaskFailed` si la task se termine mal ou si
  # le timeout est atteint.
  #
  # Intérêt : détecter un échec matériel de reboot (`ovhError`
  # « Server does not awake on rescue system ») sans attendre les 10 min
  # de timeout SSH, et donner un feedback métier pendant le reboot.
  private def self.wait_ovh_task_done(
    host : Beryl::Host,
    task : OvhApi::Endpoints::Task,
    ovh_client_factory : OvhClientFactory,
    poll_interval : Time::Span,
  ) : Nil
    service_name = host.ovh_service_name.not_nil!
    client = ovh_client_factory.call

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
      "tâche OVH ##{task.id} (#{task.function}) non aboutie après #{TASK_WAIT_TIMEOUT.total_minutes.to_i} min (dernier état : #{last_status})"
    )
  end

  # Fonction d'attente SSH par défaut : poll un `ssh user@host uname -s`
  # toutes les *poll* secondes jusqu'à obtenir un succès ou dépasser
  # *timeout*. Renvoie true si SSH a répondu, false si timeout.
  #
  # Progression visuelle : un `.` par tentative, un `-` toutes les 10
  # tentatives, et un jalon textuel `[MmSSs]` toutes les 10 tentatives
  # pour situer dans le temps sans mathématique mentale. À 15 s de poll,
  # 10 tentatives = 2 min 30 s, et 10 min de timeout = ~40 signes : lisible
  # sans scroller.
  def self.default_wait_for_ssh(
    host : String,
    port : Int32,
    user : String,
    timeout : Time::Span,
    poll : Time::Span,
  ) : Bool
    conn = Beryl::SSH::Connection.insecure_bootstrap(
      host: host,
      user: user,
      port: port,
    )
    start = Time.instant
    deadline = start + timeout
    attempt = 0
    STDERR.print "[beryl rescue] "
    STDERR.flush
    while Time.instant < deadline
      attempt += 1
      begin
        result = conn.exec("uname -s", raise_on_error: false)
        if result.success?
          STDERR.puts " OK"
          return true
        end
      rescue
        # silencieux : rescue pas encore debout, retente au prochain tour
      end
      if attempt % 10 == 0
        elapsed = (Time.instant - start).total_seconds.to_i
        STDERR.printf("- [%dmn%02ds] ", elapsed // 60, elapsed % 60)
      else
        STDERR.print "."
      end
      STDERR.flush
      sleep poll
    end
    STDERR.puts
    false
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[beryl rescue] #{message}"
  end
end
