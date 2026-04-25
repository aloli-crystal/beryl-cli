require "option_parser"
require "socket"
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "../config"
require "../providers"
require "ssh"
require "./account_utils"
require "./credentials"
require "./provider_shortcut"

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
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: dedibox, ovh, scaleway)") { |v| provider_override = v }
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

    # Raccourci UX : `beryl rescue aloli/<ID> --provider=<name>`.
    # Si le host_name est un ID provider pur (entier pour Dedibox,
    # UUID pour Scaleway), beryl fetch l'IP publique via l'API et
    # l'utilise comme cible SSH. Plus besoin de connaître le reverse
    # DNS temporaire du provider ni de passer --server-id séparément.
    #
    # L'appel API a besoin des credentials — on charge en ENV les
    # variables du <société>.<provider> avant, sans passer par un
    # host résolu (on n'a pas encore le host : c'est précisément ce
    # que le shortcut construit).
    # Zone Scaleway découverte par le shortcut (scan des zones).
    # On la garde pour la passer à `trigger_scaleway` plus bas : le
    # YAML `host.scaleway_zone` n'existe pas quand on démarre d'un
    # UUID sans host déclaré, donc sans propagation on retomberait
    # sur la zone par défaut du shard (fr-par-2).
    scaleway_zone_override : String? = nil

    if (po = provider_override) && (acct = account_hint)
      root.env_file.apply_all_to_env(acct, overwrite: true)
      resolved = Beryl::CLI::ProviderShortcut.resolve(
        host_name, po,
        ovh_factory: ovh_client_factory,
        scaleway_factory: scaleway_client_factory,
        dedibox_factory: dedibox_client_factory,
      )
      if resolved
        log "provider=#{po} id=#{host_name} → IP #{resolved[:ip]}" \
            "#{resolved[:zone] ? " (zone #{resolved[:zone]})" : ""} (résolu via API)"
        host_name = resolved[:ip]
        server_id_flag ||= resolved[:server_id]
        scaleway_zone_override = resolved[:zone]
      end
    end

    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    unless dns_resolver.call(host.ssh_host)
      STDERR.puts "beryl : #{Beryl.format_ssh_target(host)} ne résout pas en DNS."
      return EXIT_DNS
    end

    # Résolution du provider : --provider CLI gagne, sinon celui du merge.
    provider = provider_override || host.provider

    # Idempotence cross-provider : si root@host répond déjà en
    # Linux via la clé locale, c'est que le rescue est déjà en
    # place — OVH Rescue64pro, Scaleway rescue Ubuntu, ou Dedibox
    # Debian post-promote exposent tous root+Linux avec la clé
    # SSH qu'on a. Relancer `beryl rescue` = no-op, on économise
    # un reboot API et 5-10 min d'attente.
    #
    # Si FreeBSD est installé, `uname -s` répond "FreeBSD" donc
    # on ne skippe pas et on relance bien le rescue.
    #
    # Skippé en --dry-run pour que l'opérateur voie quand même
    # ce qui serait appelé.
    if !dry_run && provider && ssh_root_is_linux?(host)
      log "#{provider} : root@#{host.ssh_host} répond déjà en Linux (kernel rescue) — rescue déjà en place, skip."
      return EXIT_OK
    end

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
      server_id = server_id_flag || host.scaleway_server_id || raise MissingProviderConfig.new(
        "server_id Scaleway manquant : ni --server-id, ni `scaleway.server_id` dans le merge pour #{host.fqdn}"
      )
      dry_zone = scaleway_zone_override || host.scaleway_zone
      if dry_run
        log "DRY-RUN : Scaleway → reboot(#{server_id}#{dry_zone ? ", zone=#{dry_zone}" : ""}, boot_type=Rescue)"
        log "DRY-RUN : puis wait_for_ssh(#{host.ssh_host}:#{host.port} as root, timeout #{timeout.total_minutes.to_i}m)" if wait
        log "Pour exécuter : #{Beryl.rerun_hint("rescue", args, replace_host: {raw, "#{host.account_name}/#{host.fqdn}"})}"
        return EXIT_OK
      end
      trigger_scaleway(host, scaleway_client_factory, server_id, scaleway_zone_override)
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
      log "attente SSH sur #{target} (port #{host.port}, timeout #{timeout.total_minutes.to_i} min)"
      # `default_wait_for_ssh` (qui loggue ligne par ligne chaque
      # tentative) prend le relais. Plus de ticker `log_step` ici :
      # sur chouquette terrain, il rendait la main après `[   0s]`
      # sans log final. Une ligne toutes les ~15s est moins élégant
      # mais garantit qu'on voit où la boucle s'arrête.
      # Le user est ignoré par `default_wait_for_ssh` (test TCP pur) —
      # le flow provider-specifique (promote etc.) s'occupe ensuite
      # de la couche applicative.
      ssh_ok = wait_for_ssh.call(host.ssh_host, host.port, "root", timeout, SSH_POLL_INTERVAL)
      unless ssh_ok
        STDERR.puts "beryl : timeout SSH sur #{target}"
        return EXIT_SSH_FAILED
      end

      # Scaleway : promote `rescue` → `root` après wait SSH pour que
      # le reste du flow beryl (scan, bootstrap) puisse se connecter
      # en `ssh root@host` comme pour OVH/Dedibox.
      if provider == "scaleway"
        promote_scaleway_rescue_to_root(host)
      end

      EXIT_OK
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

  # Flow Scaleway (3 étapes numérotées dans les logs pour clarté).
  # L'idempotence est gérée en amont par le check générique
  # `ssh_root_is_linux?` du dispatcher (root prête Linux = déjà OK).
  #
  #   1/3 pre-check API : lire `install.ssh_key_ids` du serveur
  #       Scaleway, récupérer chaque clé publique, comparer avec
  #       la clé locale par base64. Si absente → erreur explicite
  #       qui pointe vers `beryl scaleway-reinstall` (l'opération
  #       officielle Scaleway pour resynchroniser les clés, cf.
  #       https://www.scaleway.com/en/docs/bare-metal/elastic-metal/how-to/use-rescue-mode/).
  #       Évite de rebooter un serveur qu'on ne pourra pas
  #       atteindre ensuite en SSH par clé.
  #   2/3 reboot API en mode Rescue.
  #   3/3 le dispatcher attend SSH puis appelle `promote_scaleway_rescue_to_root`
  #       pour que la suite du flow beryl (scan, bootstrap) marche
  #       en `root@host` comme pour OVH/Dedibox.
  private def self.trigger_scaleway(
    host : Beryl::Config::ResolvedHost,
    factory : ScalewayClientFactory,
    server_id : String,
    zone_override : String? = nil,
  ) : Nil
    # La zone découverte par ProviderShortcut (scan des zones)
    # prime sur celle du YAML : quand on provisionne un serveur
    # tout neuf via `aloli/<UUID>`, le YAML n'existe pas encore
    # donc `host.scaleway_zone` est nil.
    zone = zone_override || host.scaleway_zone
    client = factory.call
    server = zone ? client.baremetal.servers.get(server_id, zone: zone) : (client.baremetal.servers.find_any_zone(server_id) ||
                                                                           raise MissingProviderConfig.new(
                                                                             "Scaleway : UUID #{server_id} introuvable dans les zones connues"
                                                                           ))
    resolved_zone = server.zone || raise MissingProviderConfig.new(
      "Scaleway : zone indéterminée pour le serveur #{server_id}"
    )

    log "Scaleway 1/3 : pre-check clé SSH (install.ssh_key_ids du serveur)"
    scaleway_precheck_ssh_key(host, server, client)

    log "Scaleway 2/3 : reboot(Rescue) sur #{server_id} (zone #{resolved_zone})"
    updated = client.baremetal.servers.reboot(
      server_id: server_id,
      zone: resolved_zone,
      boot_type: ScalewayApi::Endpoints::Baremetal::BootType::Rescue,
    )
    log "Scaleway 2/3 : serveur #{updated.id} passé en status = #{updated.status}"

    # Attente de la chute du sshd ancien : sans ça, le `wait_for_ssh`
    # principal trouve immédiatement le sshd actuel (qui répond
    # encore tant que le reboot n'a pas effectivement coupé), puis
    # le promote `rescue → root` est appliqué sur ce sshd-là, juste
    # avant qu'il tombe — résultat : la modif est perdue.
    # Pattern repris du flow Dedibox (`wait_for_ssh_drop` 2b/4).
    log "Scaleway 2b/3 : attente de la chute du sshd actuel (preuve que le hardware reboot)"
    wait_for_ssh_drop(host)
    log "Scaleway 3/3 : sshd tombé, le dispatcher va maintenant attendre SSH puis promouvra `rescue` → `root`"
  end

  # Vérifie que la clé locale (`host.identity_file`) est présente
  # dans la liste `install.ssh_key_ids` du serveur Scaleway. Sinon,
  # refuse de procéder au reboot Rescue et guide vers
  # `beryl scaleway-reinstall`.
  #
  # Cette vérification est nécessaire parce que Scaleway n'injecte
  # dans le rescue QUE les clés posées à l'install initiale : une
  # clé ajoutée au projet après coup ne sera pas dans
  # `/home/rescue/.ssh/authorized_keys` et l'accès SSH échouera.
  #
  # Comparaison par la partie base64 de la clé publique (2e champ
  # `ssh-ed25519 <b64> commentaire`) — les commentaires peuvent
  # différer, le base64 est stable et unique.
  private def self.scaleway_precheck_ssh_key(
    host : Beryl::Config::ResolvedHost,
    server : ScalewayApi::Endpoints::Baremetal::Server,
    client : ScalewayApi::Client,
  ) : Nil
    install_hash = server.raw["install"]?.try(&.as_h?)
    ssh_key_ids = install_hash.try(&.[JSON::Any.new("ssh_key_ids")]?).try(&.as_a?).try(&.map(&.as_s))
    # Suggestion path-like pour la commande de résolution. L'UUID
    # (`server.id`) est stable et réutilisable, contrairement à
    # l'IP ou au FQDN qui peuvent changer.
    suggest_path = "#{host.account_name}/#{server.id}"

    unless ssh_key_ids && !ssh_key_ids.empty?
      STDERR.puts
      STDERR.puts "beryl : le serveur Scaleway #{server.id} n'a pas de liste `install.ssh_key_ids`."
      STDERR.puts "  L'install initial n'a pas été faite avec des clés SSH."
      STDERR.puts
      STDERR.puts "Résolvez avec :"
      STDERR.puts "  beryl scaleway-reinstall #{suggest_path}"
      STDERR.puts
      STDERR.puts "  (Appelle POST /servers/{id}/install avec les clés actuelles du projet."
      STDERR.puts "   ATTENTION : réinstalle l'OS sur le disque — à ne lancer que sur un"
      STDERR.puts "   serveur neuf ou dont le contenu peut être détruit sans risque.)"
      raise MissingProviderConfig.new("Scaleway : install.ssh_key_ids absent — voir diagnostic ci-dessus")
    end

    privkey_path = host.identity_file || raise MissingProviderConfig.new(
      "identity_file non résolu pour #{host.fqdn} — déclarez `ovh.ssh_key_name` dans le domaine"
    )
    # Cherche la clé publique parmi plusieurs conventions de nommage.
    # On teste dans l'ordre et on retient le premier fichier qui existe :
    #
    #   1. Convention Aloli `.key` → `.pub` (remplacement)
    #      philippe.aloli.fr.key   → philippe.aloli.fr.pub
    #   2. Convention OpenSSH suffixe `.pub` (concaténation)
    #      id_ed25519              → id_ed25519.pub
    #      philippe_cle            → philippe_cle.pub
    #      philippe.aloli.fr.key   → philippe.aloli.fr.key.pub
    #
    # Les deux conventions coexistent chez Philippe selon l'origine
    # de la clé (Aloli vs clés importées standard).
    candidates = [] of String
    candidates << privkey_path.sub(/\.key\z/, ".pub") if privkey_path.ends_with?(".key")
    candidates << "#{privkey_path}.pub"
    pubkey_path = candidates.find { |p| File.exists?(p) } || raise MissingProviderConfig.new(
      "Scaleway pre-check : clé publique introuvable. Cherché : #{candidates.join(", ")}. " \
      "Attendue à côté de la clé privée (convention Aloli `.key` → `.pub`, " \
      "ou convention OpenSSH suffixe `.pub`)."
    )
    local_b64 = File.read(pubkey_path).strip.split(/\s+/)[1]? ||
                raise MissingProviderConfig.new(
                  "Scaleway pre-check : format clé publique invalide dans #{pubkey_path}"
                )

    keys_in_install = ssh_key_ids.map { |id| client.ssh_keys.get(id) }
    log "Scaleway 1/3 : #{ssh_key_ids.size} clé(s) dans install.ssh_key_ids (" \
        "#{keys_in_install.map(&.name).join(", ")})"

    present = keys_in_install.any? { |k| k.public_key.split(/\s+/)[1]? == local_b64 }
    return if present

    STDERR.puts
    STDERR.puts "beryl : votre clé locale (#{pubkey_path}) n'est PAS dans install.ssh_key_ids du serveur."
    STDERR.puts "  Clés présentes : #{keys_in_install.map(&.name).join(", ")}"
    STDERR.puts
    STDERR.puts "  Scaleway n'injecte dans le rescue QUE les clés posées à l'install initial."
    STDERR.puts "  Une clé ajoutée au projet ne se propage pas sans refaire un `install`."
    STDERR.puts
    STDERR.puts "Résolvez avec :"
    STDERR.puts "  beryl scaleway-reinstall #{suggest_path}"
    STDERR.puts
    STDERR.puts "  (Appelle POST /servers/{id}/install avec les clés actuelles du projet."
    STDERR.puts "   ATTENTION : réinstalle l'OS sur le disque — à ne lancer que sur un"
    STDERR.puts "   serveur neuf ou dont le contenu peut être détruit sans risque.)"
    raise MissingProviderConfig.new("Scaleway : clé locale absente de install.ssh_key_ids — voir diagnostic ci-dessus")
  end

  # Promouvoit le rescue Scaleway (user `rescue` avec clé SSH) vers
  # un accès `root` utilisable par la suite du flow beryl (scan,
  # bootstrap…). Copie `/home/rescue/.ssh/authorized_keys` dans
  # `/root/.ssh/authorized_keys` et active `PermitRootLogin yes`.
  # Équivalent du flow Dedibox (sd-<id> → root), sans le password
  # sudo puisque Scaleway expose `rescue` comme sudoer sans mot de
  # passe dans son image rescue.
  private def self.promote_scaleway_rescue_to_root(host : Beryl::Config::ResolvedHost) : Nil
    key = host.identity_file || raise MissingProviderConfig.new(
      "identity_file non résolu pour #{host.fqdn}"
    )
    rescue_conn = SSH::Connection.new(
      host: host.ssh_host, user: "rescue", port: host.port, identity_file: key,
    )
    script = <<-BASH
      set -e
      sudo mkdir -p /root/.ssh
      sudo cp /home/rescue/.ssh/authorized_keys /root/.ssh/authorized_keys
      sudo chown root:root /root/.ssh/authorized_keys
      sudo chmod 600 /root/.ssh/authorized_keys
      sudo mkdir -p /etc/ssh/sshd_config.d
      echo 'PermitRootLogin yes' | sudo tee /etc/ssh/sshd_config.d/beryl.conf >/dev/null
      (sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || sudo service ssh reload) >/dev/null 2>&1
    BASH
    log "Scaleway : promote rescue → root (copie authorized_keys + PermitRootLogin yes)"
    rescue_conn.exec("bash -s", stdin: script)
    log "Scaleway : root@#{host.ssh_host} prêt (le flow beryl continue en root)"
  end

  # Flow Dedibox (4 étapes numérotées dans les logs pour clarté).
  # L'idempotence est gérée en amont par le check générique
  # `ssh_root_is_linux?` du dispatcher.
  #
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

    # Défaut d'image rescue géré côté shard (dedibox-api 0.1.4+,
    # `DediboxApi::Endpoints::Servers::DEFAULT_RESCUE_IMAGE`). Le
    # merge YAML peut toujours surcharger via `dedibox.rescue_image`.
    image = host.provider_field("dedibox", "rescue_image") ||
            DediboxApi::Endpoints::Servers::DEFAULT_RESCUE_IMAGE
    client = factory.call

    log "Dedibox 1/4 : prepare_rescue(server_id=#{server_id}, image=#{image})"
    creds = client.servers.prepare_rescue(server_id, image)
    log "Dedibox 1/4 : credentials rescue — login=#{creds.login} (password généré par l'API, clé SSH IAM auto-injectée par Dedibox)"

    log "Dedibox 2/4 : reboot(server_id=#{server_id}, reason=\"beryl rescue\")"
    # L'API Dedibox retourne parfois `false` (« reboot refusé »)
    # alors que le reboot a bien été déclenché côté hardware
    # (constaté terrain : last_reboot côté API change malgré la
    # réponse `false`). On log en warning mais on continue — le
    # 2b/4 « attente chute sshd » confirmera ou infirmera via la
    # vraie perte de TCP. Si sshd ne tombe pas dans les 2 min, le
    # warning sera validé comme vrai refus.
    unless client.servers.reboot(server_id, reason: "beryl rescue")
      STDERR.puts "  ⚠ l'API Dedibox a retourné `false` au reboot, mais on poursuit " \
                  "(2b/4 vérifiera si le hardware a bien lâché sshd)"
    end

    # Attente « reboot effectif ». L'API Dedibox retourne en quelques
    # ms (« reboot envoyé »), mais le hardware met 10-30s à tomber
    # réellement. Pendant ces secondes, le sshd de l'ancien rescue
    # continue à répondre avec l'ancien password — si on se connecte
    # maintenant puis qu'on lance sudo -S avec le NOUVEAU password
    # (issu du prepare_rescue juste avant), sudo refuse. Ça a tourné
    # en rond sur cookie plusieurs fois.
    #
    # Parade : on attend que le TCP 22 devienne injoignable (signe
    # que le reboot a bien commencé côté hardware), puis l'attente
    # 3/4 reprendra pour le nouveau rescue.
    wait_for_ssh_drop(host)

    promote_dedibox_rescue_to_root(host, server_id, creds)
  end

  # Attend que TCP 22 cesse de répondre — preuve que le reboot est
  # effectivement en cours. Timeout court : si le hardware n'a pas
  # lâché en 2 min, c'est suspicieux (reboot refusé silencieusement
  # côté BMC ?), on continue quand même avec les étapes suivantes.
  private def self.wait_for_ssh_drop(host : Beryl::Config::ResolvedHost) : Nil
    deadline = Time.instant + 2.minutes
    Beryl.log_step(
      "beryl rescue",
      "Dedibox 2b/4 : attente de la chute de sshd (reboot hardware en cours)",
    ) do
      loop do
        if Time.instant >= deadline
          STDERR.puts "\n  sshd répond toujours après 2 min, on continue quand même (reboot suspicieux)"
          break
        end
        begin
          TCPSocket.new(host.ssh_host, host.port, connect_timeout: 3.seconds).close
          sleep 3.seconds
        rescue
          # TCP refusé / timeout → sshd tombé, reboot confirmé.
          break
        end
      end
    end
  end

  # Teste rapidement si `root@host` répond à un `uname -s` qui
  # retourne "Linux". Utilisé pour l'idempotence :
  #
  #   - Dedibox : si la promotion root a déjà été faite (run
  #     précédent), `ssh root@host uname -s` répond "Linux" → le
  #     rescue complet est inutile.
  #   - Scaleway : l'image rescue (Ubuntu) expose root directement
  #     avec la clé SSH du projet ; même test = même signal.
  #
  # Si l'hôte est en FreeBSD (système installé), `uname -s` répond
  # "FreeBSD" → on ne skippe pas, on relance le reboot Rescue.
  # Timeout court pour ne pas traîner.
  private def self.ssh_root_is_linux?(host : Beryl::Config::ResolvedHost) : Bool
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

  # Attente SSH : une ligne de log par tentative, avec raison de
  # l'échec (TCP refused / timeout / autre). Pas de ticker animé —
  # retour terrain chouquette 24 avril 2026 : le ticker du `log_step`
  # rendait la main immédiatement après `[   0s]` sans log final,
  # ce qui ressemblait à une exception silencieuse et empêchait de
  # diagnostiquer. Les lignes explicites sont plus verbeuses (une
  # toutes les ~15s) mais infaillibles côté debug.
  #
  # `user` n'est pas utilisé dans l'impl (on teste uniquement TCP),
  # mais la signature le garde pour rester injectable de la même
  # façon entre `rescue` et `boot-hd`.
  def self.default_wait_for_ssh(host : String, port : Int32, user : String, timeout : Time::Span, poll : Time::Span) : Bool
    _ = user
    start = Time.instant
    deadline = start + timeout
    attempt = 0
    while Time.instant < deadline
      attempt += 1
      elapsed = (Time.instant - start).total_seconds.to_i
      begin
        TCPSocket.new(host, port, connect_timeout: 5.seconds).close
        log "SSH répond sur #{host}:#{port} après #{elapsed}s (tentative #{attempt})"
        return true
      rescue ex
        reason = case ex
                 when Socket::ConnectError then "TCP refused"
                 when IO::TimeoutError     then "TCP timeout"
                 else                           "#{ex.class.name}: #{ex.message}"
                 end
        log "tentative #{attempt} à #{elapsed}s : #{reason}, retry dans #{poll.total_seconds.to_i}s"
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
