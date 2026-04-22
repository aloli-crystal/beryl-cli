require "option_parser"
require "ovh-api/ovh_api"
require "../config"
require "../ssh"
require "./credentials"
require "./rescue"

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

  DEFAULT_SSH_WAIT_TIMEOUT = 10.minutes

  alias OvhClientFactory = -> OvhApi::Client

  def self.run(
    config_root : String,
    args : Array(String),
    ovh_client_factory : OvhClientFactory = -> { Beryl::CLI::Credentials.ovh_client },
    wait_for_ssh : Proc(String, Int32, String, Time::Span, Time::Span, Bool) = ->Beryl::CLI::Rescue.default_wait_for_ssh(String, Int32, String, Time::Span, Time::Span),
  ) : Int32
    wait = true
    user = "admin"
    timeout = DEFAULT_SSH_WAIT_TIMEOUT
    domain_hint : String? = nil
    provider_override : String? = nil
    dry_run = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl boot-hd <host> [options]"
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (boot-hd n'est câblé que pour ovh)") { |v| provider_override = v }
      p.on("-n", "--dry-run", "Affiche l'appel API sans le déclencher") { dry_run = true }
      p.on("--no-wait", "Ne pas attendre le retour SSH") { wait = false }
      p.on("-u USER", "--user=USER", "User pour le test SSH (défaut : admin)") { |v| user = v }
      p.on("-t MIN", "--timeout=MIN", "Timeout SSH en minutes (défaut : #{DEFAULT_SSH_WAIT_TIMEOUT.total_minutes.to_i})") { |v| timeout = v.to_i.minutes }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl boot-hd <host>"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, domain_hint: domain_hint)
    root.env_file.apply_to_env(host.domain_name)

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
      return EXIT_OK
    end

    Beryl.clean_known_hosts_for(host)

    client = ovh_client_factory.call
    log "OVH : boot_from_disk pour #{service_name}"
    task = client.dedicated_servers.boot_from_disk(service_name)
    log "OVH : tâche ##{task.id} (#{task.function}) en #{task.status}"

    if wait
      target = Beryl.format_ssh_target(host)
      log "attente SSH sur #{target} (port #{host.port}, user #{user}, timeout #{timeout.total_minutes.to_i} min)"
      if wait_for_ssh.call(host.ssh_host, host.port, user, timeout, 15.seconds)
        log "SSH répond sur #{target} en #{user}"
        EXIT_OK
      else
        STDERR.puts "beryl : timeout SSH sur #{target}"
        EXIT_SSH_FAILED
      end
    else
      log "commande boot-hd envoyée ; attente SSH désactivée (--no-wait)"
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
  rescue ex : OvhApi::Error
    STDERR.puts "beryl : erreur API OVH — #{ex.message}"
    EXIT_API_ERROR
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl boot-hd] #{message}"
  end
end
