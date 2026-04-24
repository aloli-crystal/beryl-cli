require "option_parser"
require "scaleway-api/scaleway_api"
require "../config"
require "./account_utils"
require "./credentials"
require "./provider_shortcut"

# Sous-commande `beryl scaleway-reinstall <host>` : force un
# nouvel install Scaleway Elastic Metal avec la liste à jour des
# clés SSH du projet.
#
# **À quoi ça sert :** Scaleway injecte dans le rescue UNIQUEMENT
# les clés posées lors de l'install initial du serveur (champ
# `install.ssh_key_ids`). Une clé ajoutée au projet Scaleway après
# création du serveur n'est PAS propagée au rescue — ni par reboot,
# ni par un autre appel API. Le seul moyen officiel de resynchroniser
# est de refaire un `install`, ce qui est destructif pour l'OS.
#
# Source : https://www.scaleway.com/en/docs/bare-metal/elastic-metal/how-to/use-rescue-mode/
#
# **Quand l'utiliser :** en amont du flow beryl, sur un serveur
# Elastic Metal dont l'OS n'est pas précieux (serveur neuf, serveur
# de test, serveur qu'on va réinstaller sous FreeBSD de toute façon
# via `beryl bootstrap`).
#
# **Ce qui se passe :**
#   1. Récupère le serveur via l'API (`get` ou `find_any_zone`).
#   2. Liste toutes les clés SSH du projet courant.
#   3. Affiche le plan (OS, hostname, clés injectées) et demande
#      confirmation.
#   4. Appelle `POST /servers/{id}/install` avec la liste des clés
#      du projet.
#   5. Bascule immédiatement en rescue pour que le flow beryl
#      puisse reprendre (le bootstrap FreeBSD réécrit les disques).
module Beryl::CLI::ScalewayReinstall
  EXIT_OK             = 0
  EXIT_USAGE          = 1
  EXIT_ABORTED        = 2
  EXIT_API_ERROR      = 3
  EXIT_MISSING_CONFIG = 4
  EXIT_BAD_CREDS      = 5

  # OS par défaut pour la réinstall si l'install.os_id précédent
  # n'est pas connu. Ubuntu 24.04 est une image stable supportée
  # sur toutes les offres Elastic Metal Scaleway à fin 2026, et
  # dont le rescue image (Ubuntu-based) est compatible avec le
  # flow beryl.
  DEFAULT_OS_PREFIX = "ubuntu_24"

  class Aborted < Exception
  end

  class MissingProviderConfig < Exception
  end

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    os_prefix : String? = nil
    non_interactive = false
    dry_run = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl scaleway-reinstall <host> [options]\n" \
                 "\nRé-installe un serveur Elastic Metal Scaleway avec les clés\n" \
                 "SSH actuellement déclarées dans le projet. DESTRUCTIF : l'OS\n" \
                 "installé sur le disque est écrasé. À n'utiliser que sur un\n" \
                 "serveur neuf ou dont le contenu peut être perdu."
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("--os-prefix=PREFIX", "Slug OS Scaleway à installer (défaut : #{DEFAULT_OS_PREFIX})") { |v| os_prefix = v }
      p.on("-N", "--non-interactive", "Pas de prompt de confirmation (à combiner avec --yes)") { non_interactive = true }
      p.on("-n", "--dry-run", "Affiche le plan sans rien installer") { dry_run = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl scaleway-reinstall <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)

    # UX path-like : `aloli/<UUID>` pour resolve d'un serveur non
    # encore déclaré dans le YAML.
    # On capture aussi `server_id` + `zone` retournés par le shortcut :
    # quand on démarre d'un UUID sans YAML host, `host.scaleway_*` est
    # nil, seul le shortcut connaît l'UUID et la zone.
    server_id_from_shortcut : String? = nil
    zone_from_shortcut : String? = nil
    if acct = account_hint
      root.env_file.apply_all_to_env(acct, overwrite: true)
      resolved = Beryl::CLI::ProviderShortcut.resolve(
        host_name, "scaleway",
        scaleway_factory: -> { Beryl::CLI::Credentials.scaleway_client },
      )
      if resolved
        log "id=#{host_name} → IP #{resolved[:ip]}" \
            "#{resolved[:zone] ? " (zone #{resolved[:zone]})" : ""} (résolu via API)"
        host_name = resolved[:ip]
        server_id_from_shortcut = resolved[:server_id]
        zone_from_shortcut = resolved[:zone]
      end
    end

    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    server_id = server_id_from_shortcut || host.scaleway_server_id || raise MissingProviderConfig.new(
      "scaleway-reinstall nécessite un server_id Scaleway (UUID). " \
      "Déclarez `scaleway.server_id` dans le YAML ou utilisez le chemin " \
      "path-like `<account>/<UUID>`."
    )

    client = Beryl::CLI::Credentials.scaleway_client
    zone = zone_from_shortcut || host.scaleway_zone
    server = zone ? client.baremetal.servers.get(server_id, zone: zone) : (client.baremetal.servers.find_any_zone(server_id) ||
                                                                           raise MissingProviderConfig.new("UUID #{server_id} introuvable dans les zones connues"))
    resolved_zone = server.zone || raise MissingProviderConfig.new(
      "zone indéterminée pour #{server_id}"
    )

    # Recompose la liste d'install actuelle pour garder une trace
    # (ce qui change après appel).
    install_hash = server.raw["install"]?.try(&.as_h?)
    previous_os_id = install_hash.try(&.[JSON::Any.new("os_id")]?).try(&.as_s?)
    previous_keys_ids = install_hash.try(&.[JSON::Any.new("ssh_key_ids")]?).try(&.as_a?).try(&.map(&.as_s)) ||
                        [] of String
    previous_hostname = install_hash.try(&.[JSON::Any.new("hostname")]?).try(&.as_s?)

    # OS à installer : prefix CLI > OS précédent > cascade de défauts.
    # Si rien ne matche, on affiche la liste des OS disponibles dans
    # la zone pour que l'opérateur choisisse avec --os-prefix=NAME
    # au prochain run.
    target_os = if explicit = os_prefix
                  client.baremetal.oses.find_by_name_prefix(explicit, zone: resolved_zone) ||
                    raise_no_os(explicit, resolved_zone, client)
                elsif prev_id = previous_os_id
                  client.baremetal.oses.get(prev_id, zone: resolved_zone)
                else
                  find_default_os(client, resolved_zone)
                end

    # Toutes les clés SSH actuellement dans le projet. C'est bien
    # ce qu'on veut : Scaleway n'expose pas de mécanisme pour dire
    # « ajoute cette clé à l'install existant », il faut repasser la
    # liste complète.
    project_keys = client.ssh_keys.list
    if project_keys.empty?
      raise MissingProviderConfig.new(
        "aucune clé SSH dans le projet Scaleway. Ajoutez-en une avant de " \
        "lancer reinstall, sinon le rescue ne sera accessible que par password."
      )
    end

    hostname = previous_hostname || host.short_name

    STDERR.puts
    STDERR.puts "Plan reinstall Scaleway :"
    STDERR.puts "  Serveur   : #{server.id} (name=#{server.name || "(aucun)"}, zone=#{resolved_zone})"
    STDERR.puts "  OS cible  : #{target_os.name}#{target_os.version ? " #{target_os.version}" : ""} (os_id=#{target_os.id})"
    STDERR.puts "  Hostname  : #{hostname}"
    STDERR.puts "  Clés SSH  : #{project_keys.size} clé(s) du projet"
    project_keys.each { |k| STDERR.puts "              - #{k.name} (id=#{k.id})" }
    STDERR.puts
    STDERR.puts "  Install précédente :"
    STDERR.puts "    - os_id       : #{previous_os_id || "(aucun)"}"
    STDERR.puts "    - hostname    : #{previous_hostname || "(aucun)"}"
    STDERR.puts "    - ssh_key_ids : #{previous_keys_ids.empty? ? "(aucune)" : previous_keys_ids.join(", ")}"
    STDERR.puts
    STDERR.puts "ATTENTION : le disque va être entièrement ÉCRASÉ par l'install Scaleway."

    if dry_run
      log "DRY-RUN : aucun appel API effectué"
      return EXIT_OK
    end

    unless non_interactive
      STDERR.print "\nExécuter l'install ? Tapez `REINSTALL` pour confirmer : "
      STDERR.flush
      line = STDIN.gets
      raise Aborted.new if line.nil? || line.strip != "REINSTALL"
    end

    install = ScalewayApi::Endpoints::Baremetal::Install.new(
      os_id: target_os.id,
      hostname: hostname,
      ssh_key_ids: project_keys.map(&.id),
    )

    log "POST /servers/#{server.id}/install (zone #{resolved_zone})"
    updated = client.baremetal.servers.install(
      server_id: server.id,
      install: install,
      zone: resolved_zone,
    )
    log "install lancé, status=#{updated.status}"
    log "l'installation Scaleway prend typiquement 10-15 minutes avant que le rescue puisse être réactivé."
    log "prochaine étape : attendez que `beryl scaleway-reinstall` soit terminé côté Scaleway, puis relancez `beryl rescue #{host.account_name}/#{host.fqdn} --provider=scaleway`"

    EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::CLI::Credentials::MissingCredentials
    STDERR.puts "beryl : #{ex.message}"
    EXIT_BAD_CREDS
  rescue ex : MissingProviderConfig
    STDERR.puts "beryl : #{ex.message}"
    EXIT_MISSING_CONFIG
  rescue ex : Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  rescue ex : ScalewayApi::Error
    STDERR.puts "beryl : erreur API Scaleway — #{ex.message}"
    EXIT_API_ERROR
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_API_ERROR
  end

  # Cascade de défauts pour l'OS à installer : on essaye des
  # prefixes communs dans l'ordre (Ubuntu LTS puis Debian stable).
  # Les slugs Scaleway Elastic Metal changent dans le temps (ex:
  # `ubuntu_noble`, `ubuntu_jammy`, `ubuntu_focal`), et varient
  # par zone — on teste par prefix pour rester agnostique.
  private def self.find_default_os(client, zone) : ScalewayApi::Endpoints::Baremetal::Os
    %w[ubuntu debian].each do |prefix|
      if os = client.baremetal.oses.find_by_name_prefix(prefix, zone: zone)
        return os
      end
    end
    raise_no_os("(cascade ubuntu/debian)", zone, client)
  end

  # Affiche la liste complète des OS disponibles dans la zone pour
  # que l'opérateur puisse relancer avec `--os-prefix=<slug>`.
  private def self.raise_no_os(attempted, zone, client) : NoReturn
    available = client.baremetal.oses.list(zone: zone).map(&.name)
    STDERR.puts
    STDERR.puts "beryl : aucun OS Scaleway ne commence par #{attempted.inspect} en zone #{zone}."
    STDERR.puts
    if available.empty?
      STDERR.puts "  Aucun OS listé par l'API dans cette zone (réponse vide)."
    else
      STDERR.puts "  OS disponibles dans #{zone} :"
      available.sort.each { |name| STDERR.puts "    - #{name}" }
      STDERR.puts
      STDERR.puts "  Relancez avec --os-prefix=<prefix>, par exemple :"
      STDERR.puts "    beryl scaleway-reinstall <host> --os-prefix=#{available.first}"
    end
    raise MissingProviderConfig.new("aucun OS Scaleway ne commence par #{attempted.inspect} en zone #{zone} — voir liste ci-dessus")
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl scaleway-reinstall] #{message}"
  end
end
