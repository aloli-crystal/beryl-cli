require "../providers"
require "../config"

# Helpers partagés entre `beryl init`, `beryl add-provider`, `beryl
# add-domain` pour (a) résoudre la société courante depuis un
# argument CLI (forme path-like `société/objet` ou flag `--account`)
# et (b) choisir la société par défaut quand il n'y en a qu'une.
module Beryl::CLI::AccountUtils
  # Sépare un argument `<société>/<objet>` en {account, object}.
  # Retourne `{nil, raw}` si aucun `/` n'est présent.
  def self.split_account_path(raw : String) : NamedTuple(account: String?, object: String)
    if idx = raw.index('/')
      {account: raw[0...idx], object: raw[(idx + 1)..]}
    else
      {account: nil.as(String?), object: raw}
    end
  end

  # Résolution de la société à utiliser pour une commande :
  #
  #   - priorité 1 : path-like (si l'argument contient un `/`)
  #   - priorité 2 : flag explicite `--account=`
  #   - priorité 3 : auto-détection si une seule société existe
  #   - sinon : nil (erreur côté appelant)
  def self.resolve_account(
    config_root : String,
    path_account : String?,
    account_flag : String?,
  ) : String?
    return path_account if path_account && !path_account.empty?
    return account_flag if account_flag && !account_flag.empty?

    # Auto-détection si une seule société existe.
    root = Beryl::Config::Root.load(config_root)
    return nil if root.accounts.empty?
    return root.account_names.first if root.accounts.size == 1

    # Plusieurs sociétés et aucun hint : on rend nil, le caller
    # explique à l'utilisateur (liste des accounts + flag à utiliser).
    nil
  end

  # Liste des fournisseurs implémentés dans ce build de beryl.
  # Utilisé par `beryl init` et `add-provider` pour guider le prompt.
  def self.implemented_providers : Array(Beryl::Provider)
    Beryl::Providers.all.select(&.implemented?)
  end

  # Liste des fournisseurs configurés pour une société (présents
  # dans `.env.yml[account]`). Lecture seule, pour l'affichage.
  def self.providers_of(config_root : String, account : String) : Array(String)
    env = Beryl::Config::EnvFile.load(File.join(config_root, ".env.yml"))
    env.providers_for(account)
  end

  # Prompt simple avec défaut. `default` affiché entre crochets si
  # non vide. Ctrl-D ou EOF → lève `Aborted`.
  def self.ask(prompt : String, default : String = "") : String
    full_prompt = default.empty? ? prompt : "#{prompt} [#{default}] "
    STDERR.print full_prompt
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    answer = line.chomp.strip
    answer.empty? ? default : answer
  end

  def self.ask_yes_no(prompt : String, default_yes : Bool = true) : Bool
    hint = default_yes ? "[O/n]" : "[o/N]"
    full = "#{prompt} #{hint} "
    STDERR.print full
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    a = line.chomp.strip.downcase
    return default_yes if a.empty?
    a.starts_with?("o") || a.starts_with?("y")
  end

  # Masque un secret pour l'affichage : 4 premiers + *** + 4 derniers
  # si la valeur est assez longue, `***` sinon.
  def self.mask_secret(value : String) : String
    return "***" if value.size < 12
    "#{value[0, 4]}#{"*" * (value.size - 8)}#{value[-4, 4]}"
  end

  # Exception de sortie utilisateur (Ctrl-D, Ctrl-C logique).
  class Aborted < Exception
  end

  # Rassemble les credentials déjà en mémoire pour un provider dans
  # une société. Sources inspectées :
  #   1. le fichier `.env.yml[<account>][<provider>]` (passé en arg)
  #   2. les variables d'environnement du shell courant
  # Factorisé ici pour que tous les flux credentials (OVH, Scaleway,
  # Gandi…) partagent le même mécanisme.
  def self.collect_pre_existing(provider : Beryl::Provider, current_file : Hash(String, String)) : Hash(String, String)
    result = {} of String => String
    provider.credentials_env_vars.each do |var|
      if current_file.has_key?(var.name) && !current_file[var.name].empty?
        result[var.name] = current_file[var.name]
      elsif (shell_val = ENV[var.name]?) && !shell_val.empty?
        result[var.name] = shell_val
      end
    end
    result
  end

  # Flux générique de récupération des credentials d'un provider
  # pour une société. Utilisé par `beryl add-provider` et indirectement
  # par `beryl init` (qui enchaîne add-provider). Applicable à
  # n'importe quel provider : la sémantique vient de
  # `provider.credentials_env_vars` + du hook
  # `provider.bootstrap_credentials_if_needed`.
  #
  # Étapes :
  #   0. Détecter les credentials déjà en mémoire (fichier + shell).
  #      Si présents et interactif, demander à l'utilisateur s'il
  #      veut les réutiliser ou en générer/saisir de nouveaux.
  #   1-4. Récupération classique (fichier → shell → défaut → prompt).
  #   5. Hook `bootstrap_credentials_if_needed` (OVH : génère la CK).
  #   6. Vérif des vars requises.
  #   7. Persist .env.yml + apply to ENV.
  #
  # Retourne true si tout s'est bien passé, false sinon (avec message
  # d'erreur déjà émis sur STDERR).
  def self.ensure_credentials(
    provider : Beryl::Provider,
    account : String,
    env_file : Beryl::Config::EnvFile,
    env_path : String,
    non_interactive : Bool,
    regen_credentials : Bool,
  ) : Bool
    required = provider.credentials_env_vars.reject(&.optional)
    current = env_file.for_account_provider(account, provider.name).dup
    regen = regen_credentials
    picked_up_from_shell = [] of String
    prompted = [] of String
    kept_from_file = [] of String

    # Étape 0 : détecter pré-existants, demander si utiliser/regen.
    pre_existing = collect_pre_existing(provider, current)
    if !pre_existing.empty? && !non_interactive && !regen
      STDERR.puts "[beryl] J'ai trouvé des credentials existants pour `#{provider.name}` dans la société `#{account}` :"
      provider.credentials_env_vars.each do |var|
        next unless pre_existing.has_key?(var.name)
        value = pre_existing[var.name]
        display = var.secret ? mask_secret(value) : value
        source = if current.has_key?(var.name) && !current[var.name].empty?
                   "fichier #{env_path}"
                 else
                   "variable d'environnement du shell courant"
                 end
        STDERR.puts "       #{var.name.ljust(22)} = #{display}"
        STDERR.puts "       #{" " * 22}   ↪ source : #{source}"
      end
      if ask_yes_no(
           "Voulez-vous les utiliser, ou en générer/saisir de nouveaux ? (O = utiliser, n = régénérer)",
           default_yes: true,
         )
        # Conserve tout.
      else
        STDERR.puts "[beryl] Les credentials existants sont ignorés ; nouvelle saisie/génération."
        current = {} of String => String
        regen = true
      end
    end

    # Étapes 1-4 : fichier → shell → défaut → prompt.
    provider.credentials_env_vars.each do |var|
      if current.has_key?(var.name) && !current[var.name].empty?
        kept_from_file << var.name
        next
      end
      unless regen
        if (shell_val = ENV[var.name]?) && !shell_val.empty?
          current[var.name] = shell_val
          picked_up_from_shell << var.name
          next
        end
      end
      if var.optional && (d = var.default) && !d.empty?
        current[var.name] = d
        next
      end
      next if non_interactive
      if prompted.empty? && picked_up_from_shell.empty?
        STDERR.puts "       Aide : #{provider.credentials_help_url}"
        if details = provider.credentials_help_details
          details.each_line { |line| STDERR.puts "       #{line}" }
        end
      end
      prompt = "  #{var.name}"
      prompt += " (optionnel)" if var.optional
      prompt += " : "
      STDERR.print prompt
      STDERR.flush
      line = STDIN.gets
      raise Aborted.new if line.nil?
      input = line.chomp.strip
      next if input.empty? && var.optional
      current[var.name] = input unless input.empty?
      prompted << var.name
    end

    unless kept_from_file.empty?
      STDERR.puts "[beryl] Variables conservées :"
      provider.credentials_env_vars.each do |var|
        next unless kept_from_file.includes?(var.name)
        value = current[var.name]
        display = var.secret ? mask_secret(value) : value
        STDERR.puts "       #{var.name.ljust(22)} = #{display}"
      end
    end

    # Étape 5 : hook provider (génération auto, ex: OVH CK).
    begin
      current = provider.bootstrap_credentials_if_needed(
        current,
        force_regen: regen,
        interactive: !non_interactive,
      )
    rescue ex
      STDERR.puts "beryl : échec de la génération automatique des credentials #{provider.display_name} — #{ex.message}"
      return false
    end

    # Étape 6 : vérif requises.
    missing = required.map(&.name).reject { |n| current.has_key?(n) && !current[n].empty? }
    unless missing.empty?
      STDERR.puts "beryl : variables requises non fournies pour #{provider.display_name} : #{missing.join(", ")}"
      return false
    end

    # Étape 7 : persist + apply ENV.
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
