require "yaml"

module Beryl::Config
  # Parse de `~/.beryl/.env.yml`. Format :
  #
  #   aloli.net:
  #     OVH_APPLICATION_KEY: xxx
  #     OVH_APPLICATION_SECRET: xxx
  #     OVH_CONSUMER_KEY: xxx
  #     SCW_SECRET_KEY: xxx
  #
  #   quimeo.fr:
  #     OVH_APPLICATION_KEY: yyy
  #     ...
  #
  # Plat par domaine, commentaires pour distinguer les providers si
  # utile (pas de sous-sections ovh:/scaleway:).
  #
  # Chaque commande qui cible un host charge UNIQUEMENT la section du
  # domaine concerné dans `ENV`, le temps de l'exécution. Pas de
  # contamination entre domaines.
  class EnvFile
    DEFAULT_PATH = File.expand_path("~/.beryl/.env.yml", home: true)

    getter path : String
    getter sections : Hash(String, Hash(String, String)) # domaine => {var => valeur}

    def initialize(@path : String, @sections : Hash(String, Hash(String, String)))
    end

    # Charge le fichier. Retourne une instance vide (pas d'erreur) si
    # le fichier n'existe pas — certains usages (ex: beryl init) le
    # créent à la volée.
    def self.load(path : String = DEFAULT_PATH) : EnvFile
      return EnvFile.new(path, {} of String => Hash(String, String)) unless File.exists?(path)
      raw = YAML.parse(File.read(path))
      sections = {} of String => Hash(String, String)
      if hash = raw.as_h?
        hash.each do |domain_any, vars_any|
          domain = domain_any.as_s
          vars = {} of String => String
          if vars_hash = vars_any.as_h?
            vars_hash.each do |k, v|
              vars[k.as_s] = v.as_s
            end
          end
          sections[domain] = vars
        end
      end
      EnvFile.new(path, sections)
    end

    # Liste des domaines pour lesquels des credentials sont définies.
    def domains : Array(String)
      @sections.keys
    end

    # Variables pour un domaine donné, ou hash vide si inconnu.
    def for_domain(domain : String) : Hash(String, String)
      @sections[domain]? || {} of String => String
    end

    # Injecte les variables d'un domaine dans `ENV`. Par défaut,
    # n'écrase pas les variables déjà définies dans le shell
    # (convention `LoadEnv` : ce que l'utilisateur a explicitement
    # exporté l'emporte).
    def apply_to_env(domain : String, overwrite : Bool = false) : Int32
      count = 0
      for_domain(domain).each do |k, v|
        next if !overwrite && ENV.has_key?(k)
        ENV[k] = v
        count += 1
      end
      count
    end

    # Sauvegarde sur disque au format YAML, chmod 0600 (fichier
    # secret). Crée le dossier parent au besoin. Merge avec un fichier
    # existant si présent (préserve les autres domaines).
    def save : Nil
      Dir.mkdir_p(File.dirname(@path))
      content = String.build do |io|
        io << "# Credentials beryl par domaine — écrit par `beryl init`\n"
        io << "# Format plat : `<var>: <valeur>` sous la clé du domaine.\n"
        io << "# Pour distinguer les providers, utilisez des commentaires.\n\n"
        @sections.keys.sort.each_with_index do |domain, i|
          io << '\n' if i > 0
          io << domain << ":\n"
          @sections[domain].keys.sort.each do |var|
            value = @sections[domain][var]
            io << "  " << var << ": "
            # Quote si espaces ou caractères spéciaux.
            if value =~ /\s|["'\\]/
              io << '"' << value.gsub('"', "\\\"") << '"'
            else
              io << value
            end
            io << '\n'
          end
        end
      end
      File.write(@path, content)
      File.chmod(@path, 0o600)
    end

    # Remplace la section d'un domaine (ou la crée). Ne touche pas les
    # autres domaines présents dans le fichier.
    def set_domain(domain : String, vars : Hash(String, String)) : Nil
      @sections[domain] = vars.dup
    end
  end
end
