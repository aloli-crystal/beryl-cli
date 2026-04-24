require "option_parser"
require "socket"
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "../config"
require "../providers"
require "ssh"
require "./account_utils"
require "./credentials"

# Sous-commande `beryl rescue <host> [options]` : bascule un hôte en
# rescue via l'API de l'hébergeur (OVH ou Scaleway) puis attend le
# retour SSH.
module Beryl::CLI::Rescue
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

  DEFAULT_SSH_WAIT_TIMEOUT = 10.minutes
  TASK_POLL_INTERVAL       = 10.seconds
  SSH_POLL_INTERVAL        = 15.seconds
  # Temps max d'attente pour que la task `hardReboot` OVH atteigne son
  # état terminal (done | ovhError | cancelled). Un reboot OVH standard
  # aboutit en 2-3 min côté task (le serveur met ensuite 2-4 min à
  # répondre SSH).
  TASK_WAIT_TIMEOUT = 5.minutes

  alias OvhClientFactory = -> OvhApi::Client
  alias ScalewayClientFactory = -> ScalewayApi::Client
  alias DediboxClientFactory = -> DediboxApi::Client

  class DnsResolutionFailed < Exception
  end

  class MissingProviderConfig < Exception
  end

  class TaskFailed < Exception
  end

  def self.run(
    config_root : String,
    args : Array(String),
    ovh_client_factory : OvhClientFactory = -> { Beryl::CLI::Credentials.ovh_client },
    scaleway_client_factory : ScalewayClientFactory = -> { Beryl::CLI::Credentials.scaleway_client },
    dedibox_client_factory : DediboxClientFactory = -> { Beryl::CLI::Credentials.dedibox_client },
    wait_for_ssh : Proc(String, Int32, String, Time::Span, Time::Span, Bool) = ->default_wait_for_ssh(String, Int32, String, Time::Span, Time::Span),
    dns_resolver : Proc(String, Bool) = ->default_dns_resolve(String),
  ) : Int32
    wait = true
    timeout = DEFAULT_SSH_WAIT_TIMEOUT
    account_hint : String? = nil
    domain_hint : String? = nil
    provider_override : String? = nil
    server_id_flag : String? = nil
    dry_run = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl rescue <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë entre sociétés)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine (sinon déduit du FQDN)") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: ovh, scaleway, dedibox)") { |v| provider_override = v }
      p.on("-I ID", "--server-id=ID", "ID serveur côté hébergeur (Dedibox entier, Scaleway UUID). Inutile pour OVH") { |v| server_id_flag = v }
      p.on("-n", "--dry-run", "Affiche l'appel API sans le déclencher") { dry_run = true }
      p.on("-W", "--no-wait", "Ne pas attendre le retour SSH après l'appel API") { wait = false }
      p.on("-t MIN", "--timeout=MIN", "Timeout SSH en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") { |v| timeout = v.to_i.minutes }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl rescue <host>"
      return EXIT_USAGE
    end

    # Parse forme path-like `<société>/<host>` ou
    # `<société>/<domaine>/<host>`. Les flags `-a` / `-d`, s'ils sont
    # fournis, priment sur les valeurs extraites du chemin.
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    unless dns_resolver.call(host.ssh_host)
      STDERR.puts "beryl : #{Beryl.format_ssh_target(host)} ne résout pas en DNS."
      return EXIT_DNS
    end

    # Résolution du provider : --provider CLI gagne, sinon celui du merge.
    provider = provider_override || host.provider
    case provider
    when "ovh"
      # Validation précoce avant le cleanup known_hosts
      service_name = host.ovh_service_name || raise MissingProviderConfig.new(
        "champ `ovh.service_name` manquant pour #{host.fqdn}"
      )
      if dry_run
        log "DRY-RUN : OVHcloud → prepare_rescue(#{service_name}, ssh_key=#{host.ovh_ssh_key_name || "<auto>"})"
        log "DRY-RUN : puis wait_for_ssh(#{host.ssh_host}:#{host.port} as root, timeout #{timeout.total_minutes.to_i}m)" if wait
        log "Pour exécuter : #{Beryl.rerun_hint("rescue", args, replace_host: {raw, "#{host.account_name}/#{host.fqdn}"})}"
        return EXIT_OK
      end
      task = trigger_ovh(host, ovh_client_factory)
      # Poll la task jusqu'à son état terminal avant de tester SSH.
      # Sinon on capture potentiellement l'ancien contexte (FreeBSD de
      # prod ou ancien rescue) au lieu du nouveau rescue.
      wait_ovh_task_done(host, task, ovh_client_factory) if wait
    when "scaleway"
      server_id = host.scaleway_server_id || raise MissingProviderConfig.new(
        "champ `scaleway.server_id` manquant pour #{host.fqdn}"
      )
      if dry_run
        log "DRY-RUN : Scaleway → reboot(#{server_id}, boot_type=Rescue)"
        log "DRY-RUN : puis wait_for_ssh(#{host.ssh_host}:#{host.port} as root, timeout #{timeout.total_minutes.to_i}m)" if wait
        log "Pour exécuter : #{Beryl.rerun_hint("rescue", args, replace_host: {raw, "#{host.account_name}/#{host.fqdn}"})}"
        return EXIT_OK
      end
      trigger_scaleway(host, scaleway_client_factory)
    when "dedibox"
      # Priorité : --server-id CLI > dedibox.server_id du merge.
      # Permet un rescue sans YAML host pré-existant (provisionning
      # initial d'un serveur Dedibox non encore déclaré).
      server_id = server_id_flag || host.dedibox_server_id || raise MissingProviderConfig.new(
        "server_id Dedibox manquant : ni --server-id, ni `dedibox.server_id` dans le merge pour #{host.fqdn}"
      )
      if dry_run
        log "DRY-RUN : Dedibox → prepare_rescue(#{server_id}, image=debian-12_amd64)"
        log "DRY-RUN : puis reboot(#{server_id}, reason=\"beryl rescue\")"
        log "DRY-RUN : puis wait_for_ssh(#{host.ssh_host}:#{host.port} as root, timeout #{timeout.total_minutes.to_i}m)" if wait
        log "Pour exécuter : #{Beryl.rerun_hint("rescue", args, replace_host: {raw, "#{host.account_name}/#{host.fqdn}"})}"
        return EXIT_OK
      end
      trigger_dedibox(host, dedibox_client_factory, server_id)
    when nil
      report_provider_unresolved(host)
      return EXIT_BAD_PROVIDER
    else
      known = Beryl::Providers.all.map(&.name).sort
      STDERR.puts "beryl : provider « #{provider} » inconnu (attendu : #{known.join(", ")})"
      return EXIT_BAD_PROVIDER
    end

    if wait
      target = Beryl.format_ssh_target(host)
      ssh_ok = Beryl.log_step(
        "beryl rescue",
        "attente SSH sur #{target} (port #{host.port}, user root, timeout #{timeout.total_minutes.to_i} min)",
      ) { wait_for_ssh.call(host.ssh_host, host.port, "root", timeout, SSH_POLL_INTERVAL) }
      if ssh_ok
        EXIT_OK
      else
        STDERR.puts "beryl : timeout SSH sur #{target}"
        EXIT_SSH_FAILED
      end
    else
      log "commande rescue envoyée à l'API ; attente SSH désactivée (--no-wait)"
      EXIT_OK
    end
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
  rescue ex : MissingProviderConfig
    STDERR.puts "beryl : #{ex.message}"
    EXIT_MISSING_CONFIG
  rescue ex : TaskFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_TASK_FAILED
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

  private def self.trigger_ovh(host : Beryl::Config::ResolvedHost, factory : OvhClientFactory) : OvhApi::Endpoints::Task
    service_name = host.ovh_service_name || raise MissingProviderConfig.new(
      "champ `ovh.service_name` manquant pour #{host.fqdn}"
    )
    client = factory.call
    ssh_key_name = host.ovh_ssh_key_name || auto_select_ovh_ssh_key(client, host)
    log "OVH : prepare_rescue pour #{service_name} (clé : #{ssh_key_name})"
    client.dedicated_servers.prepare_rescue(service_name: service_name, ssh_key_name: ssh_key_name)
  end

  # Poll la task hardReboot OVH jusqu'à son état terminal. Sans ce poll,
  # beryl testait SSH juste après `prepare_rescue` — il capturait donc
  # potentiellement l'ancien contexte (FreeBSD de prod ou ancien rescue)
  # parce que le reboot n'avait pas encore eu lieu.
  #
  # États OVH connus : `init` → `todo` → `doing` → `done`. Erreurs :
  # `ovhError`, `customerError`, `cancelled`. Timeout côté OVH rare
  # (5 min de marge large), mais on garde une limite pour ne pas rester
  # bloqué indéfiniment si l'API boucle.
  # Poll la task hardReboot OVH jusqu'à son état terminal. Une ligne
  # `log_step` par état (init, todo, doing, done) avec compteur vivant
  # `[NNNs]` : on break quand l'état change, log_step fige la ligne
  # avec le temps final passé DANS cet état. L'opérateur voit
  # immédiatement combien chaque transition a pris.
  private def self.wait_ovh_task_done(
    host : Beryl::Config::ResolvedHost,
    task : OvhApi::Endpoints::Task,
    factory : OvhClientFactory,
  ) : Nil
    service_name = host.ovh_service_name.not_nil!
    client = factory.call
    deadline = Time.instant + TASK_WAIT_TIMEOUT
    current = task
    while Time.instant < deadline
      return if current.success?
      if current.failed? || current.status == "cancelled"
        raise TaskFailed.new(
          "tâche OVH ##{current.id} (#{current.function}) terminée en #{current.status} — #{current.comment}"
        )
      end
      current_status = current.status
      Beryl.log_step("beryl rescue", "OVH : tâche ##{task.id} en #{current_status}") do
        while Time.instant < deadline
          sleep TASK_POLL_INTERVAL
          current = client.dedicated_servers.task(service_name, task.id)
          break if current.status != current_status
        end
      end
    end
    raise TaskFailed.new(
      "tâche OVH ##{task.id} (#{task.function}) non aboutie après #{TASK_WAIT_TIMEOUT.total_minutes.to_i} min (dernier état : #{current.status})"
    )
  end

  private def self.auto_select_ovh_ssh_key(client : OvhApi::Client, host : Beryl::Config::ResolvedHost) : String
    names = client.ssh_keys.list
    raise MissingProviderConfig.new("aucune clé SSH OVH dans le compte (configurez `ovh.ssh_key_name` dans #{host.domain.source_path})") if names.empty?
    if names.size == 1
      log "OVH : clé SSH auto-sélectionnée (seule du compte) : #{names.first}"
      names.first
    else
      log "OVH : plusieurs clés SSH, utilise #{names.first} (pour choisir explicitement, déclarez `ovh.ssh_key_name`)"
      names.first
    end
  end

  private def self.trigger_scaleway(host : Beryl::Config::ResolvedHost, factory : ScalewayClientFactory) : Nil
    server_id = host.scaleway_server_id || raise MissingProviderConfig.new(
      "champ `scaleway.server_id` manquant pour #{host.fqdn}"
    )
    zone = host.scaleway_zone
    log "Scaleway : reboot(Rescue) sur #{server_id}#{zone ? " (zone #{zone})" : ""}"
    client = factory.call
    server = client.baremetal.servers.reboot(
      server_id: server_id,
      zone: zone,
      boot_type: ScalewayApi::Endpoints::Baremetal::BootType::Rescue,
    )
    log "Scaleway : serveur #{server.id} passé en status = #{server.status}"
  end

  # Flow Dedibox (4 étapes numérotées dans les logs pour clarté) :
  #
  #   0/4 idempotence — si root@host répond déjà avec la clé IAM,
  #       tout est prêt, on sort (skip complet). Relancer `beryl rescue`
  #       quand le serveur est déjà dans l'état attendu ne casse rien.
  #   1/4 prepare_rescue (API Dedibox) — pose `boot_mode=rescue` et
  #       retourne un password temporaire pour `sudo -S`.
  #   2/4 reboot (API Dedibox) — redémarre le hardware.
  #   3/4 attente SSH sd-<id> (rescue Debian booté, clé IAM injectée).
  #   4/4 promote root — copie la clé IAM dans /root/.ssh/authorized_keys
  #       et active PermitRootLogin pour que le reste du flow beryl
  #       (bootstrap, scan…) fonctionne avec `ssh root@host`.
  private def self.trigger_dedibox(host : Beryl::Config::ResolvedHost, factory : DediboxClientFactory, server_id_str : String) : Nil
    server_id = server_id_str.to_i? || raise MissingProviderConfig.new(
      "`dedibox.server_id` doit être un entier pour #{host.fqdn} (reçu : #{server_id_str.inspect})"
    )

    # 0/4 — idempotence : root répond déjà → rien à faire.
    if dedibox_root_ready?(host)
      log "Dedibox 0/4 : root@#{host.ssh_host} répond déjà avec la clé IAM. " \
          "Le serveur est déjà en rescue avec promote fait — skip complet."
      return
    end

    image = host.provider_field("dedibox", "rescue_image") ||
            Beryl::Providers::Dedibox::DEFAULT_RESCUE_IMAGE
    client = factory.call

    log "Dedibox 1/4 : prepare_rescue(server_id=#{server_id}, image=#{image})"
    creds = client.servers.prepare_rescue(server_id, image)
    log "Dedibox 1/4 : credentials rescue — login=#{creds.login} (password généré par l'API, clé SSH IAM auto-injectée par Dedibox)"

    log "Dedibox 2/4 : reboot(server_id=#{server_id}, reason=\"beryl rescue\")"
    unless client.servers.reboot(server_id, reason: "beryl rescue")
      raise TaskFailed.new("Dedibox a refusé le reboot pour #{server_id}")
    end

    promote_dedibox_rescue_to_root(host, server_id, creds)
  end

  # Teste rapidement si `root@host` répond à un `uname -s`. Utilisé
  # pour l'idempotence de `trigger_dedibox` : si root est déjà là
  # (promote fait par un run précédent), inutile de refaire un
  # rescue complet. Timeout court pour ne pas traîner.
  private def self.dedibox_root_ready?(host : Beryl::Config::ResolvedHost) : Bool
    key = host.identity_file
    return false unless key
    conn = SSH::Connection.new(
      host: host.ssh_host,
      user: "root",
      port: host.port,
      identity_file: key,
    )
    result = conn.exec("uname -s", raise_on_error: false)
    result.success? && result.stdout.strip == "Linux"
  rescue
    false
  end

  # Attend que sd-<id> réponde en SSH (avec la clé IAM Dedibox qui
  # a été injectée automatiquement par le rescue), puis exécute en
  # sudo un petit script qui copie la clé dans /root/.ssh et active
  # PermitRootLogin yes. Le password sudo est celui renvoyé par
  # prepare_rescue (transporté sur stdin, pas exposé dans la ligne
  # de commande).
  private def self.promote_dedibox_rescue_to_root(
    host : Beryl::Config::ResolvedHost,
    server_id : Int32,
    creds : DediboxApi::Endpoints::RescueCredentials,
  ) : Nil
    sd_user = "sd-#{server_id}"
    key = host.identity_file || raise MissingProviderConfig.new(
      "identity_file non résolu pour #{host.fqdn} — déclarez `ovh.ssh_key_name` dans le domaine " \
      "(pour que beryl trouve la clé locale à passer à `-i`)"
    )

    # 3/4 — attente que sd-<id> réponde (rescue Debian prêt).
    sd_conn = SSH::Connection.new(
      host: host.ssh_host, user: sd_user, port: host.port, identity_file: key,
    )
    deadline = Time.instant + DEFAULT_SSH_WAIT_TIMEOUT
    Beryl.log_step(
      "beryl rescue",
      "Dedibox 3/4 : attente SSH #{sd_user}@#{host.ssh_host} (rescue Debian prêt)",
    ) do
      attempt = 0
      loop do
        raise TaskFailed.new("timeout : rescue Dedibox n'a pas démarré en #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i} min") if Time.instant >= deadline
        attempt += 1
        begin
          result = sd_conn.exec("uname -s", raise_on_error: false)
          if result.success? && result.stdout.strip == "Linux"
            break
          end
          # Log chaque tentative échouée pour qu'on voie pourquoi
          # ça traîne (ConnectTimeout=10 déjà posé par le shard ssh).
          STDERR.puts "\n  [tentative #{attempt}] exit=#{result.exit_code} stderr=#{result.stderr.strip.inspect[0, 120]}"
        rescue ex
          STDERR.puts "\n  [tentative #{attempt}] exception: #{ex.class} #{ex.message}"
        end
        sleep SSH_POLL_INTERVAL
      end
    end

    # 4/4 — promote : copie clé + PermitRootLogin yes via sudo -S.
    script = <<-BASH
      set -e
      mkdir -p /root/.ssh
      cp /home/#{sd_user}/.ssh/authorized_keys /root/.ssh/authorized_keys
      chown root:root /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      mkdir -p /etc/ssh/sshd_config.d
      echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/beryl.conf
      (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload) >/dev/null 2>&1
    BASH
    log "Dedibox 4/4 : promote #{sd_user} → root (copie clé IAM + PermitRootLogin yes via sudo -S)"
    sd_conn.exec(
      "sudo -S -p '' bash -s",
      stdin: creds.password + "\n" + script,
    )
    log "Dedibox 4/4 : root@#{host.ssh_host} prêt (le wait_for_ssh principal prend le relais)"
  end

  # Par défaut, résolution DNS via `Socket::Addrinfo.resolve`.
  def self.default_dns_resolve(host : String) : Bool
    Socket::Addrinfo.resolve(host, 22, type: Socket::Type::STREAM) { |_| true }
    true
  rescue
    false
  end

  # Par défaut, attente SSH par TCP connect + polling.
  def self.default_wait_for_ssh(host : String, port : Int32, user : String, timeout : Time::Span, poll : Time::Span) : Bool
    deadline = Time.instant + timeout
    while Time.instant < deadline
      begin
        TCPSocket.new(host, port, connect_timeout: 5.seconds).close
        return true
      rescue
        sleep poll
      end
    end
    false
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl rescue] #{message}"
  end

  # Message d'erreur pour quand `provider:` n'est pas résolu. Liste les
  # providers compilés dans ce build de beryl, ainsi que les blocs
  # providers déjà présents dans la config mergée — ça aide à voir
  # « j'ai un bloc `ovh:` mais pas de `provider:` ».
  private def self.report_provider_unresolved(host : Beryl::Config::ResolvedHost) : Nil
    known = Beryl::Providers.all.map(&.name).sort
    blocks = host.present_provider_blocks
    STDERR.puts "beryl : provider non résolu pour #{host.fqdn}."
    STDERR.puts "  Déclarez `provider: <nom>` dans #{host.domain.source_path} (défaut du domaine),"
    STDERR.puts "  ou dans le fichier host, ou passez `--provider=<nom>` sur la ligne de commande."
    STDERR.puts "  Providers compilés dans ce build : #{known.join(", ")}."
    if blocks.empty?
      STDERR.puts "  Aucun bloc provider trouvé dans la config mergée."
    else
      STDERR.puts "  Blocs providers présents dans la config mergée : #{blocks.join(", ")}."
    end
  end
end
