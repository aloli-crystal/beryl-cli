require "option_parser"
require "json"
require "ssh"
require "../config"
require "./account_utils"

# Sous-commande `beryl headscale-authkey <serveur>` — génère une PRE-AUTH KEY
# sur le serveur Headscale (le bastion qui héberge le control plane), à injecter
# ensuite dans un node via `HEADSCALE_AUTHKEY` (recette `headscale-node` →
# primitive `headscale-join`). Ferme le trou opérationnel n°1 : avant, l'opérateur
# devait SSH à la main sur le serveur et lancer `headscale preauthkeys create`.
#
# Flux : SSH root sur le serveur → `headscale preauthkeys create --user <u>
# --expiration <e> [--ephemeral] [--reusable]` → extrait la clé (sortie JSON).
#
# Exemples :
#   beryl headscale-authkey z.aloli.net                 # clé 1h, user = société
#   beryl headscale-authkey z --user aloli --create-user
#   beryl headscale-authkey z --ephemeral --reusable --expiration 720h   # CI
#   AUTHKEY=$(beryl headscale-authkey z -q) ; ...        # -q = clé seule (pipe)
#
# Commandes distantes csh-safe (root FreeBSD = csh) : pas de redirection Bourne.
module Beryl::CLI::HeadscaleAuthkey
  EXIT_OK          = 0
  EXIT_USAGE       = 1
  EXIT_SSH_FAILED  = 2
  EXIT_UNEXPECTED  = 3
  EXIT_NO_BINARY   = 5
  EXIT_GEN_FAILED  = 6
  EXIT_PARSE_ERROR = 7

  HEADSCALE_BINARY = "headscale"
  DEFAULT_CONFIG   = "/usr/local/etc/headscale/config.yaml"

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    user : String? = nil
    expiration = "1h"
    config_path = DEFAULT_CONFIG
    ephemeral = false
    reusable = false
    create_user = false
    quiet = false
    dry_run = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl headscale-authkey <serveur> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-u NAME", "--user=NAME", "User Headscale (défaut : société du host)") { |v| user = v }
      p.on("-e DUR", "--expiration=DUR", "Durée de validité (défaut : 1h ; ex. 720h)") { |v| expiration = v }
      p.on("--config=PATH", "Chemin config Headscale côté serveur (défaut : #{DEFAULT_CONFIG})") { |v| config_path = v }
      p.on("--ephemeral", "Clé éphémère (node retiré à la déconnexion — CI runners)") { ephemeral = true }
      p.on("--reusable", "Clé réutilisable (plusieurs nodes — sinon usage unique)") { reusable = true }
      p.on("--create-user", "Crée le user Headscale d'abord (idempotent)") { create_user = true }
      p.on("-q", "--quiet", "N'affiche QUE la clé (pour pipe/script)") { quiet = true }
      p.on("-n", "--dry-run", "Affiche la commande sans l'exécuter") { dry_run = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : serveur Headscale non précisé. USAGE : beryl headscale-authkey <serveur>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

    # Défaut du user Headscale = société du host (mesh d'une société).
    hs_user = user || host.account_name
    if hs_user.nil? || hs_user.empty?
      STDERR.puts "beryl : user Headscale indéterminé (ni --user ni société du host) — précisez --user NAME"
      return EXIT_USAGE
    end
    target = Beryl.format_ssh_target(host)

    create_cmd = "#{Process.quote(HEADSCALE_BINARY)} --config #{Process.quote(config_path)} " \
                 "preauthkeys create --user #{Process.quote(hs_user)} " \
                 "--expiration #{Process.quote(expiration)}"
    create_cmd += " --ephemeral" if ephemeral
    create_cmd += " --reusable" if reusable
    create_cmd += " --output json"

    flags = [] of String
    flags << "ephemeral" if ephemeral
    flags << "reusable" if reusable
    flags_label = flags.empty? ? "" : " [#{flags.join(", ")}]"

    if dry_run
      log "DRY-RUN : SSH root@#{host.ssh_host}:#{host.port}" unless quiet
      log "DRY-RUN :   headscale users create #{hs_user}" if create_user && !quiet
      log "DRY-RUN :   #{create_cmd}" unless quiet
      puts create_cmd if quiet
      return EXIT_OK
    end

    conn = host.connection

    # Pre-flight : binaire présent ? (sinon erreur claire avant tout).
    probe = conn.exec("command -v #{Process.quote(HEADSCALE_BINARY)}", raise_on_error: false)
    unless probe.success?
      STDERR.puts "beryl : binaire `#{HEADSCALE_BINARY}` introuvable sur #{target}"
      STDERR.puts "        Ce host est-il bien le serveur Headscale ? (recette `headscale-server`)"
      return EXIT_NO_BINARY
    end

    if create_user
      log "headscale users create #{hs_user} (sur #{target})" unless quiet
      uc = conn.exec(
        "#{Process.quote(HEADSCALE_BINARY)} --config #{Process.quote(config_path)} users create #{Process.quote(hs_user)}",
        raise_on_error: false,
      )
      # Idempotent : « already exists » n'est pas une erreur.
      if !uc.success? && !(uc.stderr + uc.stdout).downcase.includes?("already")
        STDERR.puts "beryl : `headscale users create #{hs_user}` a échoué : " \
                    "exit=#{uc.exit_code} stderr=#{uc.stderr.strip.inspect}"
        return EXIT_GEN_FAILED
      end
    end

    log "headscale preauthkeys create --user #{hs_user} --expiration #{expiration}#{flags_label} (sur #{target})" unless quiet
    result = conn.exec(create_cmd, raise_on_error: false)
    unless result.success?
      STDERR.puts "beryl : génération de la pre-auth key a échoué sur #{target} : " \
                  "exit=#{result.exit_code} stderr=#{result.stderr.strip.inspect}"
      STDERR.puts "        Le user `#{hs_user}` existe-t-il ? (relancez avec `--create-user`)"
      return EXIT_GEN_FAILED
    end

    key = extract_key(result.stdout)
    unless key
      STDERR.puts "beryl : clé introuvable dans la sortie de headscale (format JSON inattendu) :"
      STDERR.puts result.stdout
      return EXIT_PARSE_ERROR
    end

    if quiet
      puts key
    else
      log "pre-auth key générée pour le user `#{hs_user}` (expire dans #{expiration})"
      puts ""
      puts key
      puts ""
      puts "À injecter dans le node (recette headscale-node) :"
      puts "  export HEADSCALE_AUTHKEY=#{key}"
      puts "  beryl apply <node> --transport=public   # ou via le coffre .env"
    end
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
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : SSH a échoué — #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Extrait le champ `key` de la sortie `headscale preauthkeys create -o json`.
  # La sortie peut contenir des lignes de log avant le JSON → on isole le bloc
  # JSON (de la 1ʳᵉ `{` à la dernière `}`). Renvoie nil si introuvable.
  # Non-`private` : exposé pour les specs (parsing = partie sensible).
  def self.extract_key(stdout : String) : String?
    open_idx = stdout.index('{')
    close_idx = stdout.rindex('}')
    return nil unless open_idx && close_idx && close_idx > open_idx
    json = stdout[open_idx..close_idx]
    parsed = JSON.parse(json)
    k = parsed["key"]?
    key = k.try(&.as_s?)
    return nil if key.nil? || key.empty?
    key
  rescue JSON::ParseException
    nil
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl headscale-authkey] #{message}"
  end
end
