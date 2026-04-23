require "yaml"

module Beryl::Config
  # Parse de `~/.beryl/.env.yml`. Format à **trois niveaux** :
  # `société → fournisseur → variables`.
  #
  #   aloli:
  #     ovh:
  #       OVH_APPLICATION_KEY: xxx
  #       OVH_APPLICATION_SECRET: yyy
  #       OVH_CONSUMER_KEY: zzz
  #     scaleway:
  #       SCW_SECRET_KEY: abc
  #
  #   quimeo:
  #     ovh:
  #       OVH_APPLICATION_KEY: aaa
  #       ...
  #
  # Justification (ADR-014) : une société a généralement plusieurs
  # domaines payés chez le même compte fournisseur. Indexer par
  # domaine forçait la duplication des credentials. Indexer par
  # société + fournisseur élimine cette duplication : aloli.net et
  # aloli.fr partagent `.env.yml[aloli][ovh]`.
  #
  # Chaque commande qui cible un host charge uniquement la section
  # `[account][provider]` concernée dans `ENV`, le temps de
  # l'exécution. Pas de contamination entre sociétés.
  class EnvFile
    DEFAULT_PATH = File.expand_path("~/.beryl/.env.yml", home: true)

    # Signature interne : account → provider → var → value.
    alias Data = Hash(String, Hash(String, Hash(String, String)))

    getter path : String
    getter data : Data

    def initialize(@path : String, @data : Data)
    end

    # Charge le fichier. Retourne une instance vide si le fichier
    # n'existe pas (certains flux — ex: `beryl init` — le créent à
    # la volée).
    def self.load(path : String = DEFAULT_PATH) : EnvFile
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
          @data[account].keys.sort.each_with_index do |provider, _|
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
