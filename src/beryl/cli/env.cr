require "./option_errors"
require "option_parser"
require "secrets"
require "toml"
require "../config"
require "../xdg"
require "./config_git"
require "./scope"
require "./vault_sort"

# `beryl env` — gestion des credentials chiffrés par société.
#
# Trois sous-commandes :
#
#   migrate [<société>,…]  Convertit `.env.yml[société]` en
#                           `<société>/.env.toml.age` chiffré.
#   edit <société>          Ouvre le coffre dans $EDITOR, re-chiffre.
#   show <société>          Affiche le plaintext (debug, hors prod).
#
# Le coffre est chiffré au roster global `secrets`
# (`~/.config/secrets/recipients.toml`) — un roster par société
# viendra quand `Secrets::Recipients` acceptera un path optionnel.
module Beryl::CLI::Env
  extend self

  # Préfixe des lignes de NOTE injectées dans l'éditeur quand le TOML est
  # invalide (boucle d'édition de `env edit`). Retirées avant tout
  # chiffrement → jamais sauvegardées dans le coffre.
  ERR_MARKER = "#!ERR"

  USAGE = <<-USAGE
    USAGE : beryl env <SOUS-COMMANDE> [args]

    SOUS-COMMANDES :
      migrate [<société>,…]      Migre .env.yml[société] vers <société>/.env.toml.age
      edit <société>            Édite le coffre d'une société dans $EDITOR
      show <société> [SECTION [VAR]]
                                    Affiche le coffre en clair, ou une section, ou une variable
      fmt <société>                 Trie le coffre (sections, variables), commentaires gardés — alias : sort
      list <société> [SECTION]      Liste les sections et variables (NOMS seulement, jamais les valeurs)
      set <société> <SECTION> <VAR> [--replace]
                                    Pose une variable : saisie MASQUÉE au clavier (deux fois), ou
                                    lue sur l'entrée (tube, multi-ligne). Existante → --replace
      unset <société> <SECTION> <VAR>
                                    Retire une variable (les commentaires du coffre restent)
      get <société> <SECTION> <VAR>
                                    Écrit une variable sur la sortie (pour un tube : empreinte…)

    <SECTION> <VAR> s'écrit aussi <SECTION.VAR> (ex. `mail SMTP_RELAY_USER` ou
    `mail.SMTP_RELAY_USER`).

    Le coffre est chiffré au roster `secrets` global. Lancer
    `secrets init` une fois sur ce poste si ce n'est pas déjà fait.
    USAGE

  # Point d'entrée appelé par `cli.cr`.
  def run(config_root : String, argv : Array(String)) : Int32
    if argv.empty? || argv.first == "--help" || argv.first == "-h" || argv.first == "help"
      STDOUT.puts USAGE
      return 0
    end

    sub = argv.first
    rest = argv[1..-1]
    case sub
    when "migrate"     then cmd_migrate(config_root, rest)
    when "edit"        then cmd_edit(config_root, rest)
    when "show"        then cmd_show(config_root, rest)
    when "fmt", "sort" then cmd_fmt(config_root, rest)
    when "list"        then cmd_list(config_root, rest)
    when "set"         then cmd_set(config_root, rest)
    when "unset"       then cmd_unset(config_root, rest)
    when "get"         then cmd_get(config_root, rest)
    else
      STDERR.puts "beryl env : sous-commande inconnue : #{sub}"
      STDERR.puts USAGE
      64
    end
  end

  # ─────────────────────────────────────────────────────────────
  # migrate
  # ─────────────────────────────────────────────────────────────

  private def self.cmd_migrate(config_root : String, argv : Array(String)) : Int32
    force = false
    purge = false
    no_commit = false
    OptionParser.parse(argv.dup) do |parser|
      Beryl::CLI.handle_option_errors(parser)
      parser.banner = "USAGE : beryl env migrate [--force] [--purge-yaml] [<société>,…]"
      parser.on("-f", "--force", "Écrase un coffre destination déjà présent (DANGEREUX)") { force = true }
      parser.on("-p", "--purge-yaml", "Supprime la section migrée de .env.yml après écriture du coffre") { purge = true }
      parser.on("--no-commit", "N'auto-commite pas le coffre chiffré dans le dépôt git de config") { no_commit = true }
      parser.on("-h", "--help", "Affiche cette aide") { puts parser; exit 0 }
    end
    list, _ = Beryl::CLI::Scope.args("env migrate", argv.reject(&.starts_with?("-"))) || return 64
    only = list ? Beryl::CLI::Scope.parts(list) : [] of String

    env_yml_path = File.join(config_root, ".env.yml")
    unless File.exists?(env_yml_path)
      STDERR.puts "beryl env migrate : aucun #{env_yml_path} à migrer."
      return 1
    end

    env_file = Beryl::Config::EnvFile.load(env_yml_path)
    if (unknown = only - env_file.accounts).present?
      STDERR.puts "beryl env migrate : société(s) absente(s) de .env.yml : #{unknown.join(", ")} — rien n'est lancé."
      return 1
    end
    accounts_to_migrate = only.empty? ? env_file.accounts : only
    if accounts_to_migrate.empty?
      STDERR.puts "beryl env migrate : aucune société à migrer (le .env.yml est vide)."
      return 0
    end

    migrated = [] of String
    skipped = [] of String
    failed = [] of String

    accounts_to_migrate.each do |account|
      providers = env_file.for_account(account)
      if providers.empty?
        STDERR.puts "[#{account}] aucune section dans .env.yml — ignorée."
        skipped << account
        next
      end

      account_dir = File.join(config_root, account)
      unless File.directory?(account_dir)
        STDERR.puts "[#{account}] le dossier #{account_dir} n'existe pas. Créez-le d'abord (`beryl add-domain #{account}/<domaine>`)."
        failed << account
        next
      end

      vault_path = File.join(account_dir, Beryl::Config::EnvFile::VAULT_FILENAME)
      if File.exists?(vault_path) && !force
        STDERR.puts "[#{account}] #{vault_path} existe déjà — passez `--force` pour écraser."
        skipped << account
        next
      end

      begin
        Beryl::Config::EnvFile.write_vault(vault_path, providers)
      rescue ex
        STDERR.puts "[#{account}] échec de l'écriture du coffre : #{ex.message}"
        failed << account
        next
      end

      migrated << account
      STDOUT.puts "[#{account}] #{providers.size} provider(s) → #{vault_path}"

      # Le coffre `.env.toml.age` est chiffré → commitable. Auto-commit
      # dans le dépôt de config société (un par société, chacun dans son
      # propre dépôt).
      Beryl::CLI::ConfigGit.commit(
        [vault_path],
        "env : coffre #{account} mis à jour (migrate)",
        no_commit,
      )

      if purge
        env_file.clear_account(account)
      end
    end

    if purge && !migrated.empty?
      env_file.save
      STDOUT.puts "[migrate] sections migrées supprimées de #{env_yml_path}"
    end

    STDOUT.puts
    STDOUT.puts "[migrate] #{migrated.size} migré(s), #{skipped.size} ignoré(s), #{failed.size} en échec"
    if !migrated.empty? && !purge
      STDOUT.puts "[migrate] note : .env.yml n'a pas été modifié. Relancez avec `--purge-yaml` pour"
      STDOUT.puts "                supprimer les sections migrées (le coffre fait autorité au load)."
    end

    failed.empty? ? 0 : 1
  end

  # ─────────────────────────────────────────────────────────────
  # edit
  # ─────────────────────────────────────────────────────────────

  private def self.cmd_edit(config_root : String, argv : Array(String)) : Int32
    account = ""
    create = false
    no_commit = false
    OptionParser.parse(argv.dup) do |parser|
      Beryl::CLI.handle_option_errors(parser)
      parser.banner = "USAGE : beryl env edit [--create] <société>"
      parser.on("-c", "--create", "Crée un coffre vide si absent") { create = true }
      parser.on("--no-commit", "N'auto-commite pas le coffre chiffré dans le dépôt git de config") { no_commit = true }
      parser.on("-h", "--help", "Affiche cette aide") { puts parser; exit 0 }
    end
    positional = argv.reject(&.starts_with?("-"))
    if positional.size > 1
      STDERR.puts "beryl env : argument(s) en trop : #{positional[1..].join(" ")} — une seule société."
      return 64
    end
    account = positional.first if positional.size >= 1

    if account.empty?
      STDERR.puts "beryl env edit : argument <société> manquant."
      return 64
    end

    account_dir = File.join(config_root, account)
    unless File.directory?(account_dir)
      STDERR.puts "beryl env edit : la société `#{account}` n'a pas de dossier (#{account_dir} absent)."
      return 1
    end

    vault_path = File.join(account_dir, Beryl::Config::EnvFile::VAULT_FILENAME)
    plaintext_before = if File.exists?(vault_path)
                         identity = Secrets::MasterKey.read.identity
                         Secrets::Vault.decrypt(File.read(vault_path), identity)
                       elsif create
                         "# beryl credentials — créez vos sections [provider] ci-dessous.\n\n[ovh]\n# OVH_APPLICATION_KEY = \"\"\n"
                       else
                         STDERR.puts "beryl env edit : #{vault_path} n'existe pas. Passez `--create` pour le créer vide."
                         return 1
                       end

    # Boucle d'édition : si le contenu n'est pas du TOML valide, on RÉ-OUVRE
    # l'éditeur avec ce contenu (cassé) pour le corriger — on ne perd JAMAIS
    # les éditions. Abandon : re-sauver le même contenu invalide, ou revenir
    # au contenu d'origine.
    plaintext_after = plaintext_before
    last_invalid = nil
    loop do
      edited = strip_error_notes(Secrets::Editor.edit(plaintext_after, suffix: ".toml"))

      if edited == plaintext_before
        STDOUT.puts "[edit] aucune modification, coffre intact."
        return 0
      end

      # Validation TOML avant de chiffrer pour ne pas écrire un coffre cassé.
      begin
        ::TOML.parse(edited)
        plaintext_after = edited
        break
      rescue ex
        if edited == last_invalid
          STDERR.puts "beryl env edit : TOML toujours invalide et inchangé — abandon."
          STDERR.puts "                 le coffre n'a PAS été modifié."
          return 1
        end
        last_invalid = edited
        STDERR.puts "beryl env edit : TOML invalide — #{ex.message}"
        STDERR.puts "                 ré-ouverture de l'éditeur pour corriger (vos éditions sont conservées)…"
        plaintext_after = "#{ERR_MARKER} TOML invalide : #{ex.message}\n" \
                          "#{ERR_MARKER} Corrigez puis sauvez. Re-sauvez tel quel pour abandonner.\n" + edited
      end
    end

    Dir.mkdir_p(account_dir)
    File.chmod(account_dir, 0o700)
    write_vault(vault_path, plaintext_after)

    STDOUT.puts "[edit] #{vault_path} mis à jour."
    # Coffre chiffré → commitable. Auto-commit dans le dépôt de config.
    Beryl::CLI::ConfigGit.commit(
      [vault_path],
      "env : coffre #{account} mis à jour (edit)",
      no_commit,
    )
    0
  rescue Secrets::NotInitializedError
    STDERR.puts "beryl env edit : aucune master key de chiffrement disponible."
    STDERR.puts "                 Lancez `secrets init` une première fois sur ce poste."
    1
  rescue ex
    STDERR.puts "beryl env edit : échec — #{ex.message}"
    1
  end

  # ─────────────────────────────────────────────────────────────
  # show
  # ─────────────────────────────────────────────────────────────

  # `beryl env set <société> <SECTION.VAR> [--replace]` : pose UNE variable,
  # jamais en argument (historique du shell), jamais affichée. Au clavier :
  # saisie MASQUÉE, deux fois (une ligne). En tube : `… | beryl env set …`
  # (multi-ligne accepté : clé PEM). Insertion CIBLÉE dans le texte
  # déchiffré : les commentaires du coffre sont conservés. Variable déjà
  # présente : refusée sans `--replace` (pas d'écrasement silencieux).
  # Relecture vérifiée avant chiffrement.
  private def self.cmd_set(config_root : String, argv : Array(String)) : Int32
    no_commit = argv.includes?("--no-commit")
    replace = argv.includes?("--replace")
    unknown = argv.select(&.starts_with?("-")) - ["--no-commit", "--replace"]
    positional = argv.reject(&.starts_with?("-"))
    t = target(positional)
    unless unknown.empty? && t && (section = t[1]) && (var = t[2])
      STDERR.puts "USAGE : beryl env set <société> <SECTION> <VAR> [--replace] [--no-commit]"
      STDERR.puts "        (valeur saisie masquée au clavier, ou lue sur l'entrée : `… | beryl env set …`)"
      return 64
    end
    account = t[0]
    path = "#{section}.#{var}"
    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    unless File.exists?(vault_path)
      STDERR.puts "beryl env set : #{vault_path} n'existe pas (`beryl env edit --create #{account}`)."
      return 1
    end
    plaintext = Secrets::Vault.decrypt(File.read(vault_path), Secrets::MasterKey.read.identity)
    present = Beryl::Config::EnvFile.parse_vault_toml(plaintext)[section]?.try(&.has_key?(var)) || false
    # Refus AVANT la saisie : inutile de taper un mot de passe pour rien.
    if present && !replace
      STDERR.puts "beryl env set : #{path} existe déjà dans le coffre #{account} — ajoutez --replace pour le remplacer."
      return 1
    end
    value = STDIN.tty? ? prompt_value(path) : STDIN.gets_to_end
    return 1 unless value
    if value.strip.empty?
      STDERR.puts "beryl env set : valeur vide — rien n'est écrit."
      return 1
    end
    base = present ? remove_var(plaintext, section, var) : plaintext
    updated = base.try { |b| insert_var(b, section, var, value) }
    unless updated
      STDERR.puts "beryl env set : #{path} : remplacement impossible sans risque — rien n'est écrit (`beryl env edit #{account}`)."
      return 1
    end
    begin
      after = Beryl::Config::EnvFile.parse_vault_toml(updated)
      raise "relecture différente de la valeur reçue" unless after[section]?.try(&.[var]?) == value
      raise "autres variables modifiées" unless same_except?(Beryl::Config::EnvFile.parse_vault_toml(plaintext), after, section, var)
    rescue ex
      STDERR.puts "beryl env set : coffre résultant invalide (#{ex.message}) — rien n'est écrit."
      return 1
    end
    write_vault(vault_path, updated)
    verb = present ? "remplacé" : "posé"
    STDOUT.puts "[set] #{path} #{verb} dans #{vault_path} (#{value.lines.size} ligne(s), valeur non affichée)."
    Beryl::CLI::ConfigGit.commit([vault_path], "env : #{account} #{section}.#{var} #{verb} (set)", no_commit)
    0
  rescue ex
    STDERR.puts "beryl env set : #{ex.message}"
    1
  end

  # Saisie masquée, deux fois ; nil (message déjà affiché) si elles diffèrent
  # ou si l'entrée est fermée.
  private def self.prompt_value(path : String) : String?
    STDERR.print "#{path} (saisie masquée) : "
    first = STDIN.noecho { STDIN.gets.try(&.chomp) }
    STDERR.puts
    STDERR.print "#{path} (confirmation) : "
    second = STDIN.noecho { STDIN.gets.try(&.chomp) }
    STDERR.puts
    if first.nil? || second.nil?
      STDERR.puts "beryl env set : saisie interrompue — rien n'est écrit."
      return
    end
    unless first == second
      STDERR.puts "beryl env set : les deux saisies diffèrent — rien n'est écrit."
      return
    end
    first
  end

  # `beryl env unset <société> <SECTION.VAR>` : retire UNE variable. Les
  # commentaires et les autres variables restent ; relecture vérifiée.
  private def self.cmd_unset(config_root : String, argv : Array(String)) : Int32
    no_commit = argv.includes?("--no-commit")
    unknown = argv.select(&.starts_with?("-")) - ["--no-commit"]
    positional = argv.reject(&.starts_with?("-"))
    t = target(positional)
    unless unknown.empty? && t && (section = t[1]) && (var = t[2])
      STDERR.puts "USAGE : beryl env unset <société> <SECTION> <VAR> [--no-commit]"
      return 64
    end
    account = t[0]
    path = "#{section}.#{var}"
    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    unless File.exists?(vault_path)
      STDERR.puts "beryl env unset : #{vault_path} n'existe pas."
      return 1
    end
    plaintext = Secrets::Vault.decrypt(File.read(vault_path), Secrets::MasterKey.read.identity)
    before = Beryl::Config::EnvFile.parse_vault_toml(plaintext)
    unless before[section]?.try(&.has_key?(var))
      STDERR.puts "beryl env unset : #{path} absent du coffre #{account}."
      return 1
    end
    updated = remove_var(plaintext, section, var)
    after = updated.try { |u| Beryl::Config::EnvFile.parse_vault_toml(u) rescue nil }
    unless updated && after && !after[section]?.try(&.has_key?(var)) && same_except?(before, after, section, var)
      STDERR.puts "beryl env unset : #{path} : retrait impossible sans risque — rien n'est écrit (`beryl env edit #{account}`)."
      return 1
    end
    write_vault(vault_path, updated)
    STDOUT.puts "[unset] #{path} retiré de #{vault_path}."
    Beryl::CLI::ConfigGit.commit([vault_path], "env : #{account} #{section}.#{var} retiré (unset)", no_commit)
    0
  rescue ex
    STDERR.puts "beryl env unset : #{ex.message}"
    1
  end

  # `beryl env fmt <société>` : trie le coffre existant (sections puis
  # variables par ordre alphabétique, commentaires gardés). `set`, `unset` et
  # `edit` l'écrivent déjà trié ; ceci range un coffre plus ancien.
  private def self.cmd_fmt(config_root : String, argv : Array(String)) : Int32
    no_commit = argv.includes?("--no-commit")
    unknown = argv.select(&.starts_with?("-")) - ["--no-commit"]
    positional = argv.reject(&.starts_with?("-"))
    account = positional.first?
    unless account && positional.size == 1 && unknown.empty?
      STDERR.puts "USAGE : beryl env fmt <société> [--no-commit]"
      return 64
    end
    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    unless File.exists?(vault_path)
      STDERR.puts "beryl env fmt : #{vault_path} n'existe pas."
      return 1
    end
    plaintext = Secrets::Vault.decrypt(File.read(vault_path), Secrets::MasterKey.read.identity)
    if Beryl::CLI::VaultSort.sort(plaintext) == plaintext
      STDOUT.puts "[fmt] #{vault_path} déjà trié."
      return 0
    end
    write_vault(vault_path, plaintext)
    STDOUT.puts "[fmt] #{vault_path} trié (sections, variables ; commentaires gardés)."
    Beryl::CLI::ConfigGit.commit([vault_path], "env : coffre #{account} trié (fmt)", no_commit)
    0
  rescue ex
    STDERR.puts "beryl env fmt : #{ex.message}"
    1
  end

  # `beryl env list <société>` : sections et NOMS de variables, triés ; jamais
  # les valeurs (seulement leur nombre de lignes pour les multi-lignes).
  private def self.cmd_list(config_root : String, argv : Array(String)) : Int32
    t = target(argv.reject(&.starts_with?("-")))
    unless t && t[2].nil? && argv.none?(&.starts_with?("-"))
      STDERR.puts "USAGE : beryl env list <société> [SECTION]"
      return 64
    end
    account, section, _ = t
    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    unless File.exists?(vault_path)
      STDERR.puts "beryl env list : #{vault_path} n'existe pas."
      return 1
    end
    vault = Beryl::Config::EnvFile.load_vault(vault_path)
    if section
      unless vault.has_key?(section)
        STDERR.puts "beryl env list : section [#{section}] absente du coffre #{account}."
        return 1
      end
      vault = vault.select(section)
    end
    STDOUT.print list_text(vault)
    0
  rescue ex
    STDERR.puts "beryl env list : #{ex.message}"
    1
  end

  # Rendu de `env list` : `[section]` puis une variable par ligne. Pur.
  def self.list_text(vault : Hash(String, Hash(String, String))) : String
    String.build do |s|
      vault.keys.sort.each_with_index do |section, i|
        s << "\n" if i > 0
        s << "[#{section}]\n"
        vault[section].keys.sort.each do |var|
          n = vault[section][var].lines.size
          s << "  #{var}#{n > 1 ? " (#{n} lignes)" : ""}\n"
        end
      end
    end
  end

  # Retire l'affectation `var = …` de `[section]` (chaîne multi-ligne
  # `'''…'''` / `"""…"""` comprise), sans toucher au reste ni aux
  # commentaires. nil si la variable est introuvable dans le texte. Pur.
  def self.remove_var(plaintext : String, section : String, var : String) : String?
    lines = plaintext.lines(chomp: false)
    current = nil
    i = 0
    while i < lines.size
      line = lines[i]
      if m = line.match(/\A\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?\z/)
        current = m[1].strip
      elsif current == section && (m = line.match(/\A\s*#{Regex.escape(var)}\s*=\s*(.*)\z/m))
        stop = i
        rest = m[1]
        if (delim = {"'''", "\"\"\""}.find { |d| rest.starts_with?(d) }) && !rest[3..].includes?(delim)
          stop += 1
          until stop >= lines.size || lines[stop].includes?(delim)
            stop += 1
          end
          return if stop >= lines.size
        end
        return (lines[0...i] + lines[(stop + 1)..]).join
      end
      i += 1
    end
    nil
  end

  # Mêmes sections et valeurs dans `a` et `b`, hors `section.var`. Pur.
  def self.same_except?(a, b, section : String, var : String) : Bool
    strip = ->(h : Hash(String, Hash(String, String))) do
      h.to_h { |s, vars| {s, s == section ? vars.reject(var) : vars} }.reject { |_, v| v.empty? }
    end
    strip.call(a) == strip.call(b)
  end

  # Chiffre et écrit le coffre, TOUJOURS trié (sections puis variables par
  # ordre alphabétique, commentaires gardés — cf. VaultSort).
  private def self.write_vault(vault_path : String, plaintext : String) : Nil
    File.write(vault_path, Secrets::Vault.encrypt(Beryl::CLI::VaultSort.sort(plaintext), Secrets::Recipients.encryption_keys))
    File.chmod(vault_path, 0o600)
  end

  # `beryl env get <société> <SECTION.VAR>` : valeur brute sur la sortie, pour
  # un tube (vérification d'empreinte…). Rien d'autre n'est écrit sur stdout.
  private def self.cmd_get(config_root : String, argv : Array(String)) : Int32
    t = target(argv)
    unless t && (section = t[1]) && (var = t[2])
      STDERR.puts "USAGE : beryl env get <société> <SECTION> <VAR>"
      return 64
    end
    account = t[0]
    path = "#{section}.#{var}"
    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    value = Beryl::Config::EnvFile.load_vault(vault_path)[section]?.try(&.[var]?)
    unless value
      STDERR.puts "beryl env get : #{path} absent du coffre #{account}."
      return 1
    end
    STDOUT.print value
    0
  rescue ex
    STDERR.puts "beryl env get : #{ex.message}"
    1
  end

  # Arguments positionnels → {société, section?, VAR?}. Formes acceptées :
  # `aloli`, `aloli mail`, `aloli mail SMTP_RELAY_USER`,
  # `aloli mail.SMTP_RELAY_USER`. nil si la forme est invalide. Pur.
  def self.target(positional : Array(String)) : {String, String?, String?}?
    account = positional[0]? || return
    return if account.empty?
    case positional.size
    when 1 then {account, nil, nil}
    when 2
      arg = positional[1]
      if sv = split_var(arg)
        {account, sv[0], sv[1]}
      elsif arg.matches?(SECTION_NAME)
        {account, arg, nil}
      end
    when 3
      return unless positional[1].matches?(SECTION_NAME) && positional[2].matches?(VAR_NAME)
      {account, positional[1], positional[2]}
    end
  end

  SECTION_NAME = /\A[A-Za-z0-9_-]+\z/
  VAR_NAME     = /\A[A-Za-z0-9_]+\z/

  # « section.VAR » → {section, VAR} ; noms simples seulement. Pur.
  def self.split_var(path : String) : {String, String}?
    m = path.match(/\A([A-Za-z0-9_-]+)\.([A-Za-z0-9_]+)\z/) || return
    {m[1], m[2]}
  end

  # Insère `var = value` dans la section `[section]` du TOML `plaintext`
  # (créée à la fin si absente), sans toucher au reste ni aux commentaires.
  # nil si la variable existe déjà dans la section. Pur.
  def self.insert_var(plaintext : String, section : String, var : String, value : String) : String?
    existing = Beryl::Config::EnvFile.parse_vault_toml(plaintext)[section]?
    return if existing && existing.has_key?(var)
    line = toml_assign(var, value)
    lines = plaintext.lines(chomp: false)
    if idx = lines.index { |l| l.strip == "[#{section}]" }
      lines.insert(idx + 1, line)
      lines.join
    else
      base = plaintext.ends_with?('\n') || plaintext.empty? ? plaintext : plaintext + "\n"
      "#{base}\n[#{section}]\n#{line}"
    end
  end

  # Affectation TOML : littérale multi-ligne (`'''…'''`, sans échappement)
  # pour une valeur à retours à la ligne, chaîne basique échappée sinon.
  private def self.toml_assign(var : String, value : String) : String
    if value.includes?('\n')
      raise "valeur contenant ''' : non représentable en chaîne littérale" if value.includes?("'''")
      "#{var} = '''\n#{value}'''\n"
    else
      escaped = value.gsub('\\', "\\\\").gsub('"', "\\\"")
      "#{var} = \"#{escaped}\"\n"
    end
  end

  private def self.cmd_show(config_root : String, argv : Array(String)) : Int32
    account = ""
    OptionParser.parse(argv.dup) do |parser|
      Beryl::CLI.handle_option_errors(parser)
      parser.banner = "USAGE : beryl env show <société> [SECTION [VAR]]"
      parser.on("-h", "--help", "Affiche cette aide") { puts parser; exit 0 }
    end
    t = target(argv.reject(&.starts_with?("-")))
    unless t
      STDERR.puts "USAGE : beryl env show <société> [SECTION [VAR]]"
      return 64
    end
    account, section, var = t

    vault_path = File.join(config_root, account, Beryl::Config::EnvFile::VAULT_FILENAME)
    unless File.exists?(vault_path)
      STDERR.puts "beryl env show : #{vault_path} n'existe pas."
      return 1
    end

    identity = Secrets::MasterKey.read.identity
    plaintext = Secrets::Vault.decrypt(File.read(vault_path), identity)
    if section
      vars = Beryl::Config::EnvFile.parse_vault_toml(plaintext)[section]?
      unless vars
        STDERR.puts "beryl env show : section [#{section}] absente du coffre #{account}."
        return 1
      end
      if var && !vars.has_key?(var)
        STDERR.puts "beryl env show : #{section}.#{var} absent du coffre #{account}."
        return 1
      end
      plaintext = show_text(section, var ? vars.select(var) : vars)
    end
    STDERR.puts "─── #{vault_path} ───────────────────"
    STDOUT.puts plaintext
    STDERR.puts "─── fin du plaintext (à NE PAS commiter en clair) ───"
    0
  rescue Secrets::NotInitializedError
    STDERR.puts "beryl env show : aucune master key de chiffrement disponible."
    STDERR.puts "                 Lancez `secrets init` une première fois sur ce poste."
    1
  rescue ex
    STDERR.puts "beryl env show : échec — #{ex.message}"
    1
  end

  # Rendu filtré de `env show` : `[section]` puis ses variables triées
  # (valeurs en clair, sans les commentaires du coffre). Pur.
  def self.show_text(section : String, vars : Hash(String, String)) : String
    String.build do |s|
      s << "[#{section}]\n"
      vars.keys.sort.each { |k| s << toml_assign(k, vars[k]) }
    end
  end

  # Retire les lignes de note d'erreur (préfixe ERR_MARKER) injectées par la
  # boucle d'édition de `cmd_edit` — elles ne doivent JAMAIS finir chiffrées.
  def self.strip_error_notes(s : String) : String
    # split('\n') + join("\n") préserve le newline final (le dernier élément
    # vide après le \n terminal est rejoint correctement).
    s.split('\n').reject(&.starts_with?(ERR_MARKER)).join("\n")
  end
end
