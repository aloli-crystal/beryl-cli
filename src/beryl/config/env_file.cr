require "yaml"
require "toml"
require "secrets"

module Beryl::Config
  # Parse de `~/.config/beryl/.env.yml`. Format à **trois niveaux** :
  # `société → fournisseur → variables`.
  #
  #   acme:
  #     ovh:
  #       OVH_APPLICATION_KEY: xxx
  #       OVH_APPLICATION_SECRET: yyy
  #       OVH_CONSUMER_KEY: zzz
  #     scaleway:
  #       SCW_SECRET_KEY: abc
  #
  #   beta:
  #     ovh:
  #       OVH_APPLICATION_KEY: aaa
  #       ...
  #
  # Justification (ADR-014) : une société a généralement plusieurs
  # domaines payés chez le même compte fournisseur. Indexer par
  # domaine forçait la duplication des credentials. Indexer par
  # société + fournisseur élimine cette duplication : example.net et
  # example.com partagent `.env.yml[acme][ovh]`.
  #
  # Chaque commande qui cible un host charge uniquement la section
  # `[account][provider]` concernée dans `ENV`, le temps de
  # l'exécution. Pas de contamination entre sociétés.
  class EnvFile
    # Chemin par défaut de `.env.yml` (dynamique : honore
    # `$XDG_CONFIG_HOME` si défini, sinon
    # `~/.config/beryl/.env.yml`). Voir `Beryl::Xdg.config_dir`.
    def self.default_path : String
      File.join(Beryl::Xdg.config_dir, ".env.yml")
    end

    # Signature interne : account → provider → var → value.
    alias Data = Hash(String, Hash(String, Hash(String, String)))

    getter path : String
    getter data : Data

    def initialize(@path : String, @data : Data)
    end

    # Charge le fichier. Retourne une instance vide si le fichier
    # n'existe pas (certains flux — ex: `beryl init` — le créent à
    # la volée).
    def self.load(path : String? = nil) : EnvFile
      path ||= default_path
      return EnvFile.new(path, Data.new) unless File.exists?(path)
      raw = YAML.parse(File.read(path))
      data = Data.new
      if accounts_hash = raw.as_h?
        accounts_hash.each do |account_any, providers_any|
          account = account_any.as_s
          next unless providers_hash = providers_any.as_h?
          per_provider = Hash(String, Hash(String, String)).new
          providers_hash.each do |provider_any, vars_any|
            provider = provider_any.as_s
            vars = {} of String => String
            if vars_hash = vars_any.as_h?
              vars_hash.each { |k, v| vars[k.as_s] = v.as_s }
            end
            per_provider[provider] = vars
          end
          data[account] = per_provider
        end
      end
      EnvFile.new(path, data)
    end

    # Liste des sociétés connues du fichier.
    def accounts : Array(String)
      @data.keys
    end

    # Liste des fournisseurs configurés pour une société (hash vide
    # si la société est inconnue).
    def providers_for(account : String) : Array(String)
      (@data[account]? || Hash(String, Hash(String, String)).new).keys
    end

    # Toutes les variables d'une société, à plat (tous fournisseurs
    # confondus). Utile pour diagnostics.
    def for_account(account : String) : Hash(String, Hash(String, String))
      @data[account]? || Hash(String, Hash(String, String)).new
    end

    # Variables pour un couple (société, fournisseur). Hash vide si
    # pas de credentials posées.
    def for_account_provider(account : String, provider : String) : Hash(String, String)
      @data[account]?.try(&.[provider]?) || {} of String => String
    end

    # Injecte les variables d'un (société, fournisseur) dans `ENV`.
    # Par défaut, n'écrase pas les variables déjà définies dans le
    # shell (convention `LoadEnv` : ce que l'utilisateur a explicitement
    # exporté l'emporte). Retourne le nombre de variables réellement
    # posées.
    def apply_to_env(account : String, provider : String, overwrite : Bool = false) : Int32
      count = 0
      for_account_provider(account, provider).each do |k, v|
        next if !overwrite && ENV.has_key?(k)
        ENV[k] = v
        count += 1
      end
      count
    end

    # Injecte TOUTES les variables d'une société (tous fournisseurs
    # confondus) dans `ENV`. Utile en début de CLI quand on ne sait
    # pas encore précisément quel(s) provider(s) seront appelés.
    # Retourne le nombre de variables posées.
    def apply_all_to_env(account : String, overwrite : Bool = false) : Int32
      count = 0
      for_account(account).each do |_, vars|
        vars.each do |k, v|
          next if !overwrite && ENV.has_key?(k)
          ENV[k] = v
          count += 1
        end
      end
      count
    end

    # Remplace (ou crée) les credentials d'un couple (société,
    # fournisseur). Ne touche pas aux autres sections du fichier.
    def set_account_provider(account : String, provider : String, vars : Hash(String, String)) : Nil
      @data[account] ||= Hash(String, Hash(String, String)).new
      @data[account][provider] = vars.dup
    end

    # Remplace **toute** la section société (tous fournisseurs) par
    # `providers`. Utilisé par le loader après avoir lu le coffre
    # chiffré d'une société : le coffre fait autorité, écrase
    # l'éventuelle section homonyme du `.env.yml` racine.
    def set_account(account : String, providers : Hash(String, Hash(String, String))) : Nil
      @data[account] = providers
    end

    # Vide une section société (utilisé par `beryl env migrate`
    # après avoir transféré les credentials d'une société vers son
    # coffre chiffré).
    def clear_account(account : String) : Nil
      @data.delete(account)
    end

    # ─────────────────────────────────────────────────────────────
    # Coffres chiffrés `.env.toml.age` (un par société)
    # ─────────────────────────────────────────────────────────────
    #
    # Format TOML cible (dans le plaintext, avant chiffrement age) :
    #
    #     [ovh]
    #     OVH_APPLICATION_KEY = "xxx"
    #     OVH_APPLICATION_SECRET = "yyy"
    #     OVH_CONSUMER_KEY = "zzz"
    #
    #     [scaleway]
    #     SCW_SECRET_KEY = "abc"
    #
    # Le niveau « société » n'existe pas dans le coffre — il est
    # porté par le dossier (`~/.config/beryl/<société>/.env.toml.age`).
    # Cette séparation permet à chaque société d'être chiffrée à un
    # roster `Secrets::Recipients` distinct (à terme — pour l'instant
    # tous les coffres utilisent le roster global du shard secrets).

    VAULT_FILENAME = ".env.toml.age"

    # Charge un coffre chiffré et retourne un hash
    # `provider → var → value`. Lève si le coffre est absent,
    # illisible, ou si le master key n'est pas accessible (le module
    # `Secrets::MasterKey` lève `NotInitializedError`).
    def self.load_vault(vault_path : String) : Hash(String, Hash(String, String))
      unless File.exists?(vault_path)
        raise "vault not found: #{vault_path}"
      end
      identity = Secrets::MasterKey.read.identity
      ciphertext = File.read(vault_path)
      plaintext = Secrets::Vault.decrypt(ciphertext, identity)
      parse_vault_toml(plaintext)
    end

    # Variante qui retourne un hash vide si le coffre n'existe pas
    # (utile au loader : tous les comptes n'ont pas forcément
    # migré). Lève toujours si déchiffrement / parsing échoue.
    def self.load_vault_if_present(vault_path : String) : Hash(String, Hash(String, String))
      return {} of String => Hash(String, String) unless File.exists?(vault_path)
      load_vault(vault_path)
    end

    # Parse le plaintext TOML d'un coffre société. Public pour les
    # tests (qui peuvent injecter du plaintext sans chiffrement).
    def self.parse_vault_toml(plaintext : String) : Hash(String, Hash(String, String))
      result = {} of String => Hash(String, String)
      doc = ::TOML.parse(plaintext)
      doc.to_h.each do |provider_any, vars_any|
        provider = provider_any.to_s
        next unless vars_any.is_a?(Hash)
        vars = {} of String => String
        vars_any.each do |k, v|
          vars[k.to_s] = v.to_s if v.is_a?(String)
        end
        result[provider] = vars
      end
      result
    end

    # Sérialise une section société (providers → vars) en TOML
    # ASCII, prêt à être chiffré et écrit dans `.env.toml.age`.
    # Trié par provider puis par variable pour rester déterministe.
    def self.serialize_account_to_toml(providers : Hash(String, Hash(String, String))) : String
      String.build do |io|
        io << "# beryl credentials — written by `beryl env migrate` / `beryl env edit`.\n"
        io << "# Format : one TOML table per provider.\n\n"
        providers.keys.sort.each_with_index do |provider, i|
          io << '\n' if i > 0
          io << '[' << provider << "]\n"
          providers[provider].keys.sort.each do |var|
            value = providers[provider][var]
            # TOML basic string: escape backslashes and double quotes.
            escaped = value.gsub('\\', "\\\\").gsub('"', "\\\"")
            io << var << " = \"" << escaped << "\"\n"
          end
        end
      end
    end

    # Écrit un coffre chiffré à `vault_path`. Le contenu est
    # sérialisé en TOML puis chiffré au roster `Secrets::Recipients`.
    # Crée le dossier parent au besoin, chmod 0600.
    def self.write_vault(vault_path : String, providers : Hash(String, Hash(String, String))) : Nil
      Dir.mkdir_p(File.dirname(vault_path))
      File.chmod(File.dirname(vault_path), 0o700)
      plaintext = serialize_account_to_toml(providers)
      ciphertext = Secrets::Vault.encrypt(plaintext, Secrets::Recipients.encryption_keys)
      File.write(vault_path, ciphertext)
      File.chmod(vault_path, 0o600)
    end

    # Sauvegarde sur disque au format YAML, chmod 0600 (fichier
    # secret). Crée le dossier parent au besoin.
    def save : Nil
      Dir.mkdir_p(File.dirname(@path))
      content = String.build do |io|
        io << "# Credentials beryl — écrit par `beryl init` / `add-provider`.\n"
        io << "# Format à 3 niveaux : société → fournisseur → variables.\n"
        io << "# Voir ADR-014 pour la justification.\n"
        @data.keys.sort.each_with_index do |account, i|
          io << '\n'
          io << account << ":\n"
          @data[account].keys.sort.each do |provider|
            io << "  " << provider << ":\n"
            @data[account][provider].keys.sort.each do |var|
              value = @data[account][provider][var]
              io << "    " << var << ": " << yaml_scalar(value) << '\n'
            end
          end
        end
      end
      File.write(@path, content)
      File.chmod(@path, 0o600)
    end

    # Quote une valeur YAML si elle contient des caractères
    # problématiques. Simple, sans gestion exhaustive — suffit pour
    # des credentials API (alphanum + tirets).
    private def yaml_scalar(value : String) : String
      if value =~ /\s|["'\\:]/
        %("#{value.gsub('"', "\\\"")}")
      else
        value
      end
    end
  end
end
