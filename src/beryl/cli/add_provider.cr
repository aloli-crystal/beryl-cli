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
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE :\n" \
                 "  beryl add-provider <société>/<provider>\n" \
                 "  beryl add-provider <provider> [--account=NAME]\n\n" \
                 "Ajoute un fournisseur à une société et stocke ses credentials\n" \
                 "dans ~/.beryl/.env.yml[<société>][<provider>]."
      p.on("-a NAME", "--account=NAME", "Société cible (si ambiguë)") { |v| account_flag = v }
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
    Dir.mkdir_p(account_dir)

    env_path = File.join(config_root, ".env.yml")
    env_file = Beryl::Config::EnvFile.load(env_path)

    STDERR.puts "[beryl add-provider] Ajout de #{provider.display_name} pour la société `#{account}`"
    success = populate_credentials(
      provider: provider,
      account: account,
      env_file: env_file,
      env_path: env_path,
      non_interactive: non_interactive,
      regen_credentials: regen_credentials,
    )
    return EXIT_ABORTED unless success

    STDERR.puts "[beryl add-provider] Credentials posés dans #{env_path}[#{account}][#{provider.name}]."
    EXIT_OK
  rescue ex : Beryl::CLI::AccountUtils::Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  end

  # Flux credentials adapté ADR-014 : on ne gère que les vars du
  # provider concerné, stockées dans .env.yml[account][provider].
  private def self.populate_credentials(
    provider : Beryl::Provider,
    account : String,
    env_file : Beryl::Config::EnvFile,
    env_path : String,
    non_interactive : Bool,
    regen_credentials : Bool,
  ) : Bool
    required = provider.credentials_env_vars.reject(&.optional)
    current = env_file.for_account_provider(account, provider.name).dup
    picked_up_from_shell = [] of String
    prompted = [] of String
    kept_from_file = [] of String

    provider.credentials_env_vars.each do |var|
      # 1. Déjà dans le fichier → on garde
      if current.has_key?(var.name) && !current[var.name].empty?
        kept_from_file << var.name
        next
      end

      # 2. Exporté dans le shell → on prend
      if (shell_val = ENV[var.name]?) && !shell_val.empty?
        current[var.name] = shell_val
        picked_up_from_shell << var.name
        next
      end

      # 3. Défaut optionnel
      if var.optional && (d = var.default) && !d.empty?
        current[var.name] = d
        next
      end

      # 4. Prompt interactif
      next if non_interactive

      # Intro une seule fois
      if prompted.empty? && picked_up_from_shell.empty?
        STDERR.puts "             Aide : #{provider.credentials_help_url}"
        if details = provider.credentials_help_details
          details.each_line { |line| STDERR.puts "             #{line}" }
        end
      end
      prompt = "  #{var.name}"
      prompt += " (optionnel)" if var.optional
      prompt += " : "
      STDERR.print prompt
      STDERR.flush
      line = STDIN.gets
      raise Beryl::CLI::AccountUtils::Aborted.new if line.nil?
      input = line.chomp.strip
      next if input.empty? && var.optional
      current[var.name] = input unless input.empty?
      prompted << var.name
    end

    # Log les vars conservées (masquées) AVANT le hook
    unless kept_from_file.empty?
      STDERR.puts "[beryl add-provider] Variables conservées :"
      provider.credentials_env_vars.each do |var|
        next unless kept_from_file.includes?(var.name)
        value = current[var.name]
        display = var.secret ? Beryl::CLI::AccountUtils.mask_secret(value) : value
        STDERR.puts "               #{var.name} = #{display}"
      end
    end

    # Hook : génération auto de credentials dérivées (OVH CK)
    begin
      current = provider.bootstrap_credentials_if_needed(
        current,
        force_regen: regen_credentials,
        interactive: !non_interactive,
      )
    rescue ex
      STDERR.puts "beryl : échec de la génération automatique des credentials #{provider.display_name} — #{ex.message}"
      return false
    end

    # Vérifie les requises
    missing = required.map(&.name).reject { |n| current.has_key?(n) && !current[n].empty? }
    unless missing.empty?
      STDERR.puts "beryl : variables requises non fournies pour #{provider.display_name} : #{missing.join(", ")}"
      return false
    end

    # Persiste
    env_file.set_account_provider(account, provider.name, current)
    env_file.save
    env_file.apply_to_env(account, provider.name, overwrite: true)

    unless provider.available?
      STDERR.puts "beryl : credentials posés mais #{provider.display_name} se déclare indisponible. Vérifiez #{env_path}."
      return false
    end
    true
  end
end
