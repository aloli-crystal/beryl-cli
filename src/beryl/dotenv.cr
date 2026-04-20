module Beryl
  # Chargeur `.env` minimaliste, Crystal pur, zéro dépendance.
  #
  # Parse les formats usuels `KEY=VALUE`, `KEY="..."`, `KEY='...'`, ignore
  # les lignes vides et les commentaires (`#`). Pose les variables dans
  # `ENV` sans écraser par défaut (les variables déjà définies dans le
  # shell ou en CLI restent prioritaires).
  #
  # Usage :
  #
  #     Beryl::Dotenv.load              # charge `.env` dans le cwd, silencieux si absent
  #     Beryl::Dotenv.load(".env.prod") # autre chemin
  #
  # Les valeurs entre guillemets conservent leurs espaces internes ; les
  # séquences `\n`, `\r`, `\t`, `\\` sont déséchappées dans les chaînes à
  # guillemets doubles (bash-like). Les guillemets simples sont litéraux.
  module Dotenv
    # Charge un fichier `.env` (silencieux si absent).
    #
    # `overwrite: false` (défaut) : n'écrase pas les variables déjà
    # présentes dans `ENV`. Pose la convention « override = export avant
    # d'invoquer beryl » et évite de casser un shell déjà configuré.
    #
    # Retourne le nombre de variables effectivement posées.
    def self.load(path : String = ".env", overwrite : Bool = false) : Int32
      return 0 unless File.exists?(path)

      count = 0
      parse(File.read(path)).each do |key, value|
        next if !overwrite && ENV.has_key?(key)
        ENV[key] = value
        count += 1
      end
      count
    end

    # Parse un contenu `.env` en Hash(String, String).
    # Public pour faciliter les tests ; l'API principale reste `load`.
    def self.parse(content : String) : Hash(String, String)
      result = {} of String => String
      content.each_line do |raw|
        line = raw.strip
        next if line.empty? || line.starts_with?('#')

        # `export FOO=bar` accepté par convention (les .env générés à la main
        # l'incluent souvent pour être sourcés directement).
        line = line.sub(/^export\s+/, "")

        eq = line.index('=')
        next unless eq
        key = line[0...eq].strip
        next if key.empty?

        value = line[(eq + 1)..].strip
        result[key] = unquote(value)
      end
      result
    end

    # Retire des guillemets entourants et déséchappe les séquences bash
    # usuelles dans le cas des doubles guillemets.
    private def self.unquote(value : String) : String
      return "" if value.empty?

      if value.size >= 2 && value.starts_with?('"') && value.ends_with?('"')
        inner = value[1...-1]
        inner
          .gsub("\\n", "\n")
          .gsub("\\r", "\r")
          .gsub("\\t", "\t")
          .gsub("\\\"", "\"")
          .gsub("\\\\", "\\")
      elsif value.size >= 2 && value.starts_with?('\'') && value.ends_with?('\'')
        value[1...-1]
      else
        # Valeur non quotée : on retire un éventuel commentaire de fin de ligne
        # précédé d'un espace (`FOO=bar # note`).
        if idx = value.index(" #")
          value[0...idx].rstrip
        else
          value
        end
      end
    end
  end
end
