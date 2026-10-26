require "option_parser"
require "./option_errors"
require "api-ovh/ovh_api"
require "../config"
require "ssh"
require "./account_utils"
require "./credentials"
require "./rescue"
require "./host_keys"
require "./machine_kind"
require "./ovh_task_wait"
require "./ovh_monitoring"

# Sous-commande `beryl boot-hd <host>` : bascule OVH sur le boot
# disque (inverse de rescue) et attend le retour SSH de l'OS installé.
# Pas implémenté pour Scaleway (leur bascule passe par servers.reboot
# avec un BootType différent, sémantique couverte par leur rescue).
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

  alias OvhClientFactory = -> OvhApi::Client

  # Levée quand la tâche OVH atteint un état terminal différent de `done`
  # (ovhError, customerError, cancelled) ou dépasse son timeout.
  class TaskFailed < Exception
  end

  def self.run(
    config_root : String,
    args : Array(String),
    ovh_client_factory : OvhClientFactory = -> { Beryl::CLI::Credentials.ovh_client },
    wait_for_ssh : Proc(String, Int32, String, Time::Span, Time::Span, Bool) = ->Beryl::CLI::Rescue.default_wait_for_ssh(String, Int32, String, Time::Span, Time::Span),
  ) : Int32
    wait = true
    monitoring = true
    user = "admin"
    timeout = DEFAULT_SSH_WAIT_TIMEOUT
    account_hint : String? = nil
    domain_hint : String? = nil
    provider_override : String? = nil
    dry_run = true
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl boot-hd <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (boot-hd n'est câblé que pour ovh)") { |v| provider_override = v }
      p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
      p.on("-W", "--no-wait", "Ne pas attendre le retour SSH") { wait = false }
      p.on("--no-monitoring", "Laisser coupé le monitoring OVH (sinon remis en service une fois le serveur joignable)") { monitoring = false }
      p.on("-u USER", "--user=USER", "User pour le test SSH (défaut : admin)") { |v| user = v }
      p.on("-t MIN", "--timeout=MIN", "Timeout SSH en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") { |v| timeout = v.to_i.minutes }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl boot-hd <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    return EXIT_BAD_PROVIDER if Beryl::CLI::MachineKind.refuse_vps(host, "boot-hd")
    host.apply_all_credentials_to_env!

    # Résolution du provider : --provider CLI gagne, sinon celui du merge.
    effective_provider = provider_override || host.provider
    unless effective_provider == "ovh"
      STDERR.puts "beryl : boot-hd n'est implémenté que pour provider `ovh` (#{host.fqdn} : #{effective_provider || "inconnu"})"
      return EXIT_BAD_PROVIDER
    end

    service_name = host.ovh_service_name
    unless service_name
      STDERR.puts "beryl : champ `ovh.service_name` manquant pour #{host.fqdn}"
      return EXIT_MISSING_CONFIG
    end

    if dry_run
      log "DRY-RUN : OVHcloud → boot_from_disk(#{service_name})"
      log "DRY-RUN : puis wait_for_ssh(#{host.ssh_host}:#{host.port} as #{user}, timeout #{timeout.total_minutes.to_i}m)" if wait
      log "Pour exécuter : #{Beryl.rerun_hint("boot-hd", args, replace_host: {raw.not_nil!, Beryl::CLI::AccountUtils.host_ref(host)})}"
      return EXIT_OK
    end

    client = ovh_client_factory.call
    log "1 OVH : boot_from_disk pour #{service_name}"
    task = begin
      client.dedicated_servers.boot_from_disk(service_name)
    rescue ex : OvhApi::Error
      # Commande relancée pendant qu'un redémarrage est encore en cours chez
      # OVH. Ce redémarrage peut être celui d'un rescue (netboot lu avant
      # notre changement) : on attend qu'il finisse, puis on redemande le
      # démarrage sur disque.
      raise ex unless Beryl::CLI::OvhTaskWait.already_requested?(ex)
      pending = Beryl::CLI::OvhTaskWait.pending_reboot(client, service_name) || raise ex
      log "1 OVH : redémarrage déjà demandé — attente de la tâche ##{pending.id} (#{pending.status}), puis nouvelle demande"
      wait_ovh_task_done(service_name, pending, client)
      client.dedicated_servers.boot_from_disk(service_name)
    end
    # Le système installé reprend ses propres clés d'hôte (celles du rescue
    # partent).
    Beryl::CLI::HostKeys.forget(host, "boot-hd")

    if wait
      # Poll la task jusqu'à son état terminal avant de tester SSH.
      # Sinon on capture l'ancien contexte (rescue Linux) au lieu de
      # l'OS installé qu'on voulait démarrer.
      wait_ovh_task_done(service_name, task, client)
      target = Beryl.format_ssh_target(host)
      ssh_ok = Beryl.log_step(
        "beryl boot-hd",
        "2 attente SSH sur #{target} (port #{host.port}, user #{user}, timeout #{timeout.total_minutes.to_i} min)",
      ) { wait_for_ssh.call(host.ssh_host, host.port, user, timeout, 15.seconds) }
      if ssh_ok
        resume_ovh_monitoring(service_name, client, monitoring)
        EXIT_OK
      else
        STDERR.puts "beryl : timeout SSH sur #{target}"
        EXIT_SSH_FAILED
      end
    else
      log "1 commande boot-hd envoyée ; attente SSH désactivée (--no-wait)"
      log "3 monitoring OVH laissé tel quel (remis en service seulement après un démarrage vérifié : relancez sans --no-wait)"
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
  rescue ex : TaskFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_TASK_FAILED
  rescue ex : OvhApi::Error
    STDERR.puts "beryl : erreur API OVH — #{ex.message}"
    EXIT_API_ERROR
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Attend la tâche `reboot` OVH jusqu'à son état terminal (même attente que
  # rescue, cf. `Beryl::CLI::OvhTaskWait`).
  private def self.wait_ovh_task_done(
    service_name : String,
    task : OvhApi::Endpoints::Task,
    client : OvhApi::Client,
  ) : Nil
    if error = Beryl::CLI::OvhTaskWait.wait("beryl boot-hd", client, service_name, task)
      raise TaskFailed.new(error)
    end
  end

  # Remet en service le monitoring OVH (coupé par `beryl rescue`), une fois
  # le système installé joignable — sauf `--no-monitoring` (cf.
  # `OvhMonitoring`). Un échec est signalé sans faire échouer boot-hd.
  private def self.resume_ovh_monitoring(service_name : String, client : OvhApi::Client, monitoring : Bool) : Nil
    return log("3 OVH : monitoring OVH laissé coupé (--no-monitoring)") unless monitoring
    log "3 OVH : #{Beryl::CLI::OvhMonitoring.resume(client, service_name)}"
  rescue ex : OvhApi::Error
    log "3 OVH : ⚠ monitoring OVH non rétabli (#{ex.message}) — à réactiver dans l'espace client OVH"
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl boot-hd] #{Beryl.format_step(message)}"
  end
end
