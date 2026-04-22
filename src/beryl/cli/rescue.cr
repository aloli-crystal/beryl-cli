require "option_parser"
require "socket"
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "../inventory"
require "../ssh"
require "./credentials"
require "./host_resolver"

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
    provider_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl rescue <host> [options]\n\n" \
                 "Bascule un hôte en mode rescue via l'API de l'hébergeur\n" \
                 "(OVH ou Scaleway) puis attend le retour de SSH sur le rescue.\n" \
                 "Accepte un nom d'inventaire OU un service_name/ID hébergeur nu\n" \
                 "(ex: ns3156789.ip-51-83-6.eu, avec --provider pour lever l'ambiguïté)."
      p.on("-p NAME", "--provider=NAME", "Provider (ovh|scaleway) pour un host hors inventaire") { |v| provider_hint = v }
      p.on("-n", "--no-wait", "Ne pas attendre le retour SSH (retour immédiat après l'appel API)") { wait = false }
      p.on("-t MIN", "--timeout=MIN", "Délai d'attente maximum en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") do |v|
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

    host = Beryl::CLI::HostResolver.resolve(inventory_path, host_name, provider_hint)

    # Garde-fou DNS : on teste le nom effectivement utilisé pour SSH
    # (= ssh_host : FQDN OVH pour un host OVH avec service_name,
    # sinon nom logique). Inutile de bloquer sur un DNS custom qui
    # n'existe pas encore si on peut se rabattre sur le FQDN OVH.
    unless dns_resolver.call(host.ssh_host)
      raise DnsResolutionFailed.new(
        "#{Beryl.format_ssh_target(host)} ne résout pas en DNS. Vérifiez l'orthographe (typo .fr vs .net ?) et votre résolveur."
      )
    end

    # Purge ~/.ssh/known_hosts pour les deux noms (logique + OVH) : on
    # va changer la clé d'hôte (production → rescue Linux ou rescue →
    # autre rescue). Évite un futur « REMOTE HOST IDENTIFICATION HAS
    # CHANGED » côté utilisateur, quel que soit le nom qu'il utilise.
    Beryl.clean_known_hosts_for(host)

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
      target_for_log = Beryl.format_ssh_target(host)
      ssh_ok = log_step("attente SSH sur #{target_for_log} (port #{host.port}, user root, timeout #{timeout.total_minutes.to_i} min)") do
        wait_for_ssh.call(host.ssh_host, host.port, "root", timeout, SSH_POLL_INTERVAL)
      end
      if ssh_ok
        EXIT_OK
      else
        STDERR.puts "beryl : timeout — SSH n'a pas répondu sur #{target_for_log} au bout de #{timeout.total_minutes.to_i} min"
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

    client = ovh_client_factory.call
    ssh_key_name = host.ovh_ssh_key_name || auto_select_ovh_ssh_key(client, host)

    log "OVH : prepare_rescue pour #{service_name} (clé : #{ssh_key_name})"
    task = client.dedicated_servers.prepare_rescue(
      service_name: service_name,
      ssh_key_name: ssh_key_name,
    )
    log "OVH : tâche ##{task.id} (#{task.function}) en #{task.status}"
    task
  end

  # Fallback quand le host n'a pas de `ovh.ssh_key_name` (cas d'un
  # Host virtuel créé depuis un service_name nu) : on interroge
  # l'API pour récupérer les clés du compte.
  # 1 clé → on l'utilise. 2+ → on prend la première avec log (le cas
  # déterministe, évite un prompt dans des commandes non interactives).
  # 0 → erreur explicite.
  private def self.auto_select_ovh_ssh_key(client : OvhApi::Client, host : Beryl::Host) : String
    names = client.ssh_keys.list
    case names.size
    when 0
      raise MissingProviderConfig.new(
        "champ `ovh.ssh_key_name` manquant pour #{host.name} et aucune clé " \
        "SSH dans le compte OVH. Créez-en une (panel → Compte → Mes clés SSH) " \
        "ou déclarez-la dans un groupe zone de l'inventaire."
      )
    when 1
      log "OVH : clé SSH auto-sélectionnée (seule du compte) : #{names.first}"
      names.first
    else
      log "OVH : plusieurs clés SSH dans le compte (#{names.join(", ")}), utilisation de #{names.first}"
      log "      pour choisir explicitement, ajoutez `ovh.ssh_key_name` dans un groupe de l'inventaire"
      names.first
    end
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
    current = task
    while Time.instant < deadline
      return if current.success?
      if current.failed? || current.status == "cancelled"
        raise TaskFailed.new(
          "tâche OVH ##{current.id} (#{current.function}) terminée en #{current.status} — #{current.comment}"
        )
      end

      # Une ligne frozen par état (init, todo, doing, …) : le log_step
      # tient la ligne jusqu'au prochain changement d'état et fige le
      # temps passé en _cet_ état. L'opérateur voit clairement où on est
      # et combien chaque transition a pris.
      current_status = current.status
      log_step("OVH : tâche ##{task.id} en #{current_status}") do
        while Time.instant < deadline
          sleep poll_interval
          current = client.dedicated_servers.task(service_name, task.id)
          break if current.status != current_status
        end
      end
    end

    raise TaskFailed.new(
      "tâche OVH ##{task.id} (#{task.function}) non aboutie après #{TASK_WAIT_TIMEOUT.total_minutes.to_i} min (dernier état : #{current.status})"
    )
  end

  # Fonction d'attente SSH par défaut : poll un `ssh user@host uname -s`
  # toutes les *poll* secondes jusqu'à obtenir un succès ou dépasser
  # *timeout*. Renvoie true si SSH a répondu, false si timeout.
  #
  # Progression : une ligne unique rafraîchie en place (retour chariot `\r`)
  # avec le temps écoulé. Motif déjà éprouvé dans crystal-deploy, pas de
  # scrolling, pas de bruit.
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
    deadline = Time.instant + timeout
    while Time.instant < deadline
      begin
        result = conn.exec("uname -s", raise_on_error: false)
        return true if result.success?
      rescue
        # silencieux : rescue pas encore debout, retente au prochain tour
      end
      sleep poll
    end
    false
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{timestamp}] [beryl rescue] #{message}"
  end

  # Horodatage sensible à la locale (voir `Beryl.format_timestamp`).
  private def self.timestamp : String
    Beryl.format_timestamp(Time.local)
  end

  # Exécute un bloc en affichant le préfixe + un compteur de temps inline,
  # rafraîchi en place (`\r`), qui fige à sa valeur finale avec un `\n`
  # quand le bloc sort. Ligne horodatée : « DD-MM-YYYY HHhMMmSS
  # [beryl rescue] <label>  [NNs] ».
  private def self.log_step(label : String, & : -> T) : T forall T
    line = "[#{timestamp}] [beryl rescue] #{label}"
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
