require "option_parser"
require "../config"
require "../providers"
require "./account_utils"

# Sous-commande `beryl add-provider` : ajoute un fournisseur à une
# société (ADR-014). Credentials stockés dans `.env.yml[account][provider]`.
#
# Formes équivalentes :
#
#   beryl add-provider aloli/ovh
#   beryl add-provider ovh --account=aloli
#
# Si une seule société existe dans `~/.beryl/`, `--account` peut être
# omis : beryl auto-détecte.
#
# Pour OVH, beryl déclenche le hook `bootstrap_credentials_if_needed`
# qui génère une consumer key avec les access rules exactes via
# `POST /auth/credential`. Pour Scaleway (pas d'auto-gen côté API),
# beryl affiche la liste des permissions IAM à cocher dans la console.
module Beryl::CLI::AddProvider
  EXIT_OK      = 0
  EXIT_USAGE   = 1
  EXIT_ABORTED = 2

  def self.run(config_root : String, args : Array(String)) : Int32
    account_flag : String? = nil
    regen_credentials = false
    non_interactive = false
    dry_run = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE :\n" \
                 "  beryl add-provider <société>/<provider>\n" \
                 "  beryl add-provider <provider> [--account=NAME]\n\n" \
                 "Ajoute un fournisseur à une société et stocke ses credentials\n" \
                 "dans ~/.beryl/.env.yml[<société>][<provider>]."
      p.on("-a NAME", "--account=NAME", "Société cible (si ambiguë)") { |v| account_flag = v }
      p.on("-n", "--dry-run", "Affiche ce qui serait fait sans écrire ni appeler d'API") { dry_run = true }
      p.on("-r", "--regen-credentials", "Force la régénération des credentials dérivés (ex: OVH consumer key)") { regen_credentials = true }
      p.on("-N", "--non-interactive", "Refuse tout prompt") { non_interactive = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : provider non précisé. USAGE : beryl add-provider <société>/<provider>"
      return EXIT_USAGE
    end

    # Parse forme path-like
    parsed = Beryl::CLI::AccountUtils.split_account_path(raw)
    provider_name = parsed[:object]
    path_account = parsed[:account]

    # Résout la société effective
    account = Beryl::CLI::AccountUtils.resolve_account(config_root, path_account, account_flag)
    unless account
      STDERR.puts "beryl : impossible de déterminer la société. Utilisez :"
      STDERR.puts "  - la forme `beryl add-provider <société>/#{provider_name}`"
      STDERR.puts "  - ou le flag `--account=<société>`"
      accounts = Beryl::Config::Root.load(config_root).account_names
      STDERR.puts "  Sociétés existantes : #{accounts.empty? ? "(aucune)" : accounts.join(", ")}"
      return EXIT_USAGE
    end

    # Résout le provider dans le catalogue
    provider = Beryl::Providers.find(provider_name)
    unless provider
      known = Beryl::CLI::AccountUtils.implemented_providers.map(&.name).sort
      STDERR.puts "beryl : provider « #{provider_name} » inconnu dans ce build."
      STDERR.puts "        Providers disponibles : #{known.join(", ")}."
      return EXIT_USAGE
    end

    account_dir = File.join(config_root, account)
    env_path = File.join(config_root, ".env.yml")

    if dry_run
      env_file_stub = Beryl::Config::EnvFile.load(env_path)
      pre_existing = Beryl::CLI::AccountUtils.collect_pre_existing(
        provider,
        env_file_stub.for_account_provider(account, provider.name).dup,
      )
      STDERR.puts
      STDERR.puts "DRY-RUN : actions `beryl add-provider #{account}/#{provider.name}` prévues :"
      STDERR.puts "  - Création dossier société (si absent) : #{account_dir}"
      STDERR.puts "  - Demande des variables requises : #{provider.credentials_env_vars.reject(&.optional).map(&.name).join(", ")}"
      unless pre_existing.empty?
        STDERR.puts "  - Note : credentials pré-existants détectés (#{pre_existing.keys.join(", ")})"
        STDERR.puts "           → beryl demanderait confirmation avant de les réutiliser"
      end
      if provider.name == "ovh"
        STDERR.puts "  - Hook OVH : appel `POST /auth/credential` avec #{provider.as(Beryl::Providers::Ovh).required_access_rules.size} access rules"
        STDERR.puts "              → URL de validation à ouvrir dans le navigateur"
      end
      STDERR.puts "  - Écriture : #{env_path}[#{account}][#{provider.name}]"
      STDERR.puts
      STDERR.puts "DRY-RUN : aucune action exécutée."
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("add-provider", args)}"
      return EXIT_OK
    end

    Dir.mkdir_p(account_dir)
    env_file = Beryl::Config::EnvFile.load(env_path)

    STDERR.puts "[beryl add-provider] 2 Ajout de #{provider.display_name} pour la société `#{account}`"
    success = Beryl::CLI::AccountUtils.ensure_credentials(
      provider: provider,
      account: account,
      env_file: env_file,
      env_path: env_path,
      non_interactive: non_interactive,
      regen_credentials: regen_credentials,
    )
    return EXIT_ABORTED unless success

    STDERR.puts "[beryl add-provider] 2 Credentials posés dans #{env_path}[#{account}][#{provider.name}]."
    EXIT_OK
  rescue ex : Beryl::CLI::AccountUtils::Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  end
end
