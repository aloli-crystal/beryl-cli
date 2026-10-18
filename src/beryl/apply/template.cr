module Beryl::Apply
  # Substitution scalaire minimale `{{ var }}` (décision de design :
  # pas de logique conditionnelle, pas de Jinja/ERB — si une recette a
  # besoin de logique, c'est une recette à part entière).
  #
  # Seules les *valeurs string* d'un step sont interpolées ; une clé
  # `{{ var }}` inconnue lève `UnknownVariable` (échec explicite plutôt
  # qu'une substitution silencieuse par chaîne vide).
  module Template
    PLACEHOLDER = /\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/

    class UnknownVariable < Exception
      # Nom de la variable absente, et celles connues à ce moment.
      getter name : String
      getter known : Array(String)

      def initialize(@name : String, @known : Array(String))
        super("variable `#{@name}` non définie (variables connues : " \
              "#{@known.empty? ? "aucune" : @known.join(", ")})")
      end
    end

    # Remplace chaque `{{ var }}` de `text` par `vars[var]`. Lève
    # `UnknownVariable` si une variable référencée est absente.
    def self.render(text : String, vars : Hash(String, String)) : String
      text.gsub(PLACEHOLDER) do |_match|
        name = $1
        vars[name]? || raise UnknownVariable.new(name, vars.keys)
      end
    end

    # Vrai si `text` contient au moins un placeholder `{{ … }}`.
    def self.has_placeholder?(text : String) : Bool
      text.matches?(PLACEHOLDER)
    end
  end
end
