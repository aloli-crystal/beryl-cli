require "option_parser"
require "api-scaleway/scaleway_api"
require "../config"
require "../providers"
require "./account_utils"
require "./config_git"

# Sous-commande `beryl add-provider` : ajoute un fournisseur à une
# société (ADR-014). Credentials stockés dans `.env.yml[account][provider]`.
#
# Formes équivalentes :
#
#   beryl add-provider acme/ovh
#   beryl add-provider ovh --account=acme
#
# Si une seule société existe dans `~/.config/beryl/`, `--account` peut être
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
    no_commit = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE :\n" \
                 "  beryl add-provider <société>/<provider>\n" \
                 "  beryl add-provider <provider> [--account=NAME]\n\n" \
                 "Ajoute un fournisseur à une société et stocke ses credentials\n" \
                 "dans ~/.config/beryl/.env.yml[<société>][<provider>]."
      p.on("-a NAME", "--account=NAME", "Société cible (si ambiguë)") { |v| account_flag = v }
      p.on("-n", "--dry-run", "Affiche ce qui serait fait sans écrire ni appeler d'API") { dry_run = true }
      p.on("-r", "--regen-credentials", "Force la régénération des credentials dérivés (ex: OVH consumer key)") { regen_credentials = true }
      p.on("-N", "--non-interactive", "Refuse tout prompt") { non_interactive = true }
      p.on("--no-commit", "N'auto-commite pas le coffre chiffré dans le dépôt git de config") { no_commit = true }
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

    # Coffre chiffré présent → on régénère/écrit DANS le coffre
    # `.env.toml.age` (cette société n'utilise plus `.env.yml`). Sans ça,
    # add-provider ne voit pas l'app key (prompt) et écrirait la nouvelle
    # clé au mauvais endroit (donc inutilisée).
    vault_path = File.join(account_dir, Beryl::Config::EnvFile::VAULT_FILENAME)
    if File.exists?(vault_path) && regen_credentials
      return regen_in_vault(vault_path, account, provider, non_interactive, no_commit, dry_run)
    end

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

    # Hook Scaleway : auto-découverte du `SCW_DEFAULT_PROJECT_ID` via
    # l'API à partir de `SCW_SECRET_KEY` + `SCW_DEFAULT_ORGANIZATION_ID`
    # collectés ci-dessus. Évite à l'opérateur d'aller fouiller la
    # console pour le copier-coller.
    if provider.name == "scaleway"
      autodiscover_scaleway_project_id(account, env_file, env_path, non_interactive)
    end

    STDERR.puts "[beryl add-provider] 2 Credentials posés dans #{env_path}[#{account}][#{provider.name}]."
    # Auto-commit défensif : `.env.yml` est en clair et gitignore dans le
    # dépôt de config (un `.gitignore` défensif existe côté acme/beryl-config).
    # `ConfigGit.commit` ne force jamais `git add -f` : le fichier ignoré
    # n'est donc pas stagé → commit no-op (« rien à committer »), aucun
    # secret en clair versionné. Si l'opérateur migre vers le coffre
    # chiffré (`beryl env migrate`), c'est `.env.toml.age` (commitable)
    # qui sera versionné par `env migrate`/`env edit`.
    Beryl::CLI::ConfigGit.commit(
      [env_path],
      "add-provider : #{account}/#{provider.name}",
      no_commit,
    )
    EXIT_OK
  rescue ex : Beryl::CLI::AccountUtils::Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  end

  # Régénère/écrit les credentials d'un provider DANS le coffre chiffré
  # `.env.toml.age` de la société. Lit l'app key existante du coffre (donc
  # PAS de prompt), appelle le hook de génération du provider (OVH :
  # nouvelle consumer key via `/auth/credential`, avec les access rules à
  # jour — dont `/vrack`), puis réécrit le coffre chiffré.
  private def self.regen_in_vault(
    vault_path : String,
    account : String,
    provider : Beryl::Provider,
    non_interactive : Bool,
    no_commit : Bool,
    dry_run : Bool,
  ) : Int32
    providers = Beryl::Config::EnvFile.load_vault(vault_path)
    current = providers[provider.name]?.try(&.dup) || {} of String => String

    if dry_run
      STDERR.puts "[beryl add-provider] DRY-RUN : régénérerait les credentials #{provider.display_name} dans le coffre #{vault_path}."
      return EXIT_OK
    end

    STDERR.puts "[beryl add-provider] coffre chiffré détecté → régénération dans #{vault_path}"
    updated = provider.bootstrap_credentials_if_needed(
      current,
      force_regen: true,
      interactive: !non_interactive,
    )
    providers[provider.name] = updated
    Beryl::Config::EnvFile.write_vault(vault_path, providers)
    STDERR.puts "[beryl add-provider] credentials #{provider.display_name} régénérés dans le coffre #{vault_path}."
    Beryl::CLI::ConfigGit.commit(
      [vault_path],
      "add-provider regen : #{account}/#{provider.name}",
      no_commit,
    )
    EXIT_OK
  rescue ex
    STDERR.puts "beryl : échec de la régénération dans le coffre — #{ex.message}"
    STDERR.puts "  (l'app key/secret doivent déjà être dans le coffre ; sinon `beryl env edit #{account}`.)"
    EXIT_ABORTED
  end

  # Auto-découverte du `SCW_DEFAULT_PROJECT_ID` à partir de
  # `SCW_SECRET_KEY` + `SCW_DEFAULT_ORGANIZATION_ID` collectés.
  # Appelle `client.projects.list(organization_id)` :
  #
  #   - 1 seul projet (cas commun, projet `default` à l'inscription)
  #     → auto-sélectionné, l'opérateur ne tape rien.
  #   - Plusieurs projets → prompt interactif (ou skip en
  #     `--non-interactive`, l'opérateur devra l'ajouter manuellement
  #     plus tard).
  #
  # Si la découverte échoue (réseau, mauvais credentials, etc.),
  # warning seulement : on n'invalide pas l'add-provider entier
  # parce que les autres credentials sont OK et l'opérateur peut
  # toujours ajouter `SCW_DEFAULT_PROJECT_ID` à la main dans
  # `.env.yml`.
  private def self.autodiscover_scaleway_project_id(
    account : String,
    env_file : Beryl::Config::EnvFile,
    env_path : String,
    non_interactive : Bool,
  ) : Nil
    creds = env_file.for_account_provider(account, "scaleway")
    secret_key = creds["SCW_SECRET_KEY"]?
    org_id = creds["SCW_DEFAULT_ORGANIZATION_ID"]?
    existing_pid = creds["SCW_DEFAULT_PROJECT_ID"]?

    return unless secret_key && org_id
    return if existing_pid && !existing_pid.empty?

    STDERR.puts "[beryl add-provider] 2 Scaleway : auto-découverte du project_id via API (organization_id=#{org_id})..."
    client = ScalewayApi::Client.new(secret_key: secret_key)
    projects = begin
      client.projects.list(organization_id: org_id)
    rescue ex
      STDERR.puts "[beryl add-provider] 2 Scaleway : auto-découverte échouée (#{ex.class.name}: #{ex.message.try(&.[0, 120])})"
      STDERR.puts "[beryl add-provider] 2 Scaleway : ajoutez SCW_DEFAULT_PROJECT_ID manuellement dans #{env_path} sous [#{account}][scaleway]."
      return
    end

    if projects.empty?
      STDERR.puts "[beryl add-provider] 2 Scaleway : aucun projet trouvé pour cette organisation (étrange — vérifiez SCW_DEFAULT_ORGANIZATION_ID)."
      return
    end

    chosen = if projects.size == 1
               proj = projects.first
               STDERR.puts "[beryl add-provider] 2 Scaleway : 1 seul projet, auto-sélectionné : #{proj.name} (#{proj.id})"
               proj
             elsif non_interactive
               STDERR.puts "[beryl add-provider] 2 Scaleway : #{projects.size} projets disponibles, mais --non-interactive → ajoutez SCW_DEFAULT_PROJECT_ID manuellement dans .env.yml :"
               projects.each { |p| STDERR.puts "  - #{p.name.ljust(20)} #{p.id}#{p.default? ? " (default)" : ""}" }
               return
             else
               STDERR.puts "[beryl add-provider] 2 Scaleway : #{projects.size} projets disponibles :"
               projects.each_with_index do |p, i|
                 STDERR.puts "  #{i + 1}. #{p.name.ljust(20)} #{p.id}#{p.default? ? " (default)" : ""}"
               end
               loop do
                 ans = Beryl::CLI::AccountUtils.ask("Lequel utiliser ? (numéro ou ID) :", "1")
                 idx = ans.to_i?
                 if idx && idx >= 1 && idx <= projects.size
                   break projects[idx - 1]
                 end
                 by_id = projects.find { |p| p.id == ans }
                 break by_id if by_id
                 STDERR.puts "  réponse invalide, recommencez."
               end
             end

    return unless chosen.is_a?(ScalewayApi::Endpoints::Project)
    creds["SCW_DEFAULT_PROJECT_ID"] = chosen.id
    env_file.set_account_provider(account, "scaleway", creds)
    env_file.save
    STDERR.puts "[beryl add-provider] 2 Scaleway : SCW_DEFAULT_PROJECT_ID=#{chosen.id} ajouté à #{env_path}."
  end
end
