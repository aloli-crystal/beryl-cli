require "./recipe"

module Beryl::Apply
  # Résout l'ensemble des recettes à exécuter et leur ordre, à partir
  # d'une liste de recettes d'ENTRÉE (les noms demandés) et d'un CHEMIN
  # DE RECHERCHE de dépôts de recettes (`search_dirs`, ordonné).
  #
  # Chemin de recherche (priorité au premier qui matche) : permet de
  # séparer les recettes PRIVÉES par société (ex. `<config>/<société>/
  # recipes/`, qui PEUT surcharger une recette générique du même nom)
  # des recettes GÉNÉRIQUES publiques (ex. dépôt beryl-recipes). La
  # société privée passe en tête → override ; le générique en fallback.
  #
  # Les recettes d'entrée viennent de la config (`apply_recipes:`,
  # cascadé du merge société → domaine → host) ou d'un argument CLI
  # one-off (`beryl apply <host> <recette>`). Il n'y a PLUS de dossier
  # d'orchestration par host : la personnalisation passe par les
  # `parameters:` des recettes.
  #
  # Étapes :
  #   1. Fermeture transitive des `requires:` — chaque recette est
  #      cherchée dans les `search_dirs` (1er match gagne). Introuvable
  #      partout → `RecipeNotFound`.
  #   2. Tri topologique (Kahn) : les dépendances sortent avant leurs
  #      dépendants. Ordre alphabétique à indegree égal (déterministe).
  #   3. Cycle → `Cycle` (liste des recettes impliquées).
  class Resolver
    # Levée quand une recette référencée (demandée ou via `requires:`)
    # est introuvable dans le dépôt de recettes.
    class RecipeNotFound < Exception
    end

    # Levée quand le graphe des `requires:` contient un cycle.
    class Cycle < Exception
      getter recipes : Array(String)

      def initialize(@recipes : Array(String))
        super("cycle de dépendances entre recettes : #{@recipes.join(" → ")}")
      end
    end

    # `search_dirs` : dépôts de recettes, par ORDRE DE PRIORITÉ (le premier
    # qui contient `<name>.recipe.yml` gagne). Accepte aussi un seul dossier
    # (String) pour la compat des appels existants/tests.
    @search_dirs : Array(String)

    def initialize(search_dirs : Array(String) | String)
      @search_dirs = search_dirs.is_a?(String) ? [search_dirs] : search_dirs
    end

    # Retourne les recettes dans l'ordre d'exécution (dépendances
    # d'abord), à partir des noms d'entrée `requested`. Liste vide si
    # `requested` est vide.
    def resolve(requested : Array(String)) : Array(Recipe)
      return [] of Recipe if requested.empty?

      loaded = {} of String => Recipe
      requested.each { |name| load_closure(name, requirer: nil, loaded: loaded) }
      topo_sort(loaded)
    end

    # Localise et charge `<name>.recipe.yml` : parcourt `search_dirs` dans
    # l'ordre, le PREMIER qui contient le fichier gagne (override société >
    # générique). Introuvable partout → `RecipeNotFound`.
    private def lookup(name : String, requirer : String?) : Recipe
      @search_dirs.each do |dir|
        path = File.join(dir, "#{name}#{Recipe::SUFFIX}")
        return Recipe.load(path) if File.exists?(path)
      end

      origin = requirer ? " (requise par `#{requirer}`)" : ""
      tried = @search_dirs.map { |d| File.join(d, "#{name}#{Recipe::SUFFIX}") }.join("\n    ")
      raise RecipeNotFound.new(
        "recette `#{name}` introuvable#{origin} dans le chemin de recherche.\n" \
        "  cherchée dans :\n    #{tried}"
      )
    end

    # Charge récursivement `name` et toutes ses dépendances dans
    # `loaded` (dédup par nom).
    private def load_closure(name : String, requirer : String?, loaded : Hash(String, Recipe)) : Nil
      return if loaded.has_key?(name)
      recipe = lookup(name, requirer)
      loaded[name] = recipe
      recipe.requires.each do |dep|
        load_closure(dep, requirer: name, loaded: loaded)
      end
    end

    # Tri topologique de Kahn. À indegree égal, ordre alphabétique.
    private def topo_sort(loaded : Hash(String, Recipe)) : Array(Recipe)
      indegree = {} of String => Int32
      loaded.each_key { |n| indegree[n] = 0 }
      dependents = {} of String => Array(String)
      loaded.each do |name, recipe|
        recipe.requires.each do |dep|
          indegree[name] += 1
          (dependents[dep] ||= [] of String) << name
        end
      end

      ready = indegree.select { |_, d| d == 0 }.keys.sort
      result = [] of Recipe
      until ready.empty?
        n = ready.shift
        result << loaded[n]
        (dependents[n]? || [] of String).sort.each do |m|
          indegree[m] -= 1
          ready << m if indegree[m] == 0
        end
        ready.sort!
      end

      if result.size != loaded.size
        remaining = (loaded.keys - result.map(&.name)).sort
        raise Cycle.new(remaining)
      end

      result
    end
  end
end
