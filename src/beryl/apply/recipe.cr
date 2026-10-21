require "yaml"
require "./systems"

module Beryl::Apply
  # Un step d'une recette : l'invocation d'une primitive (ou, à terme,
  # d'une sous-recette). Format YAML = hash à une seule clé :
  #
  #     - pkg-install:
  #         packages: [bash, git]
  #
  # `name` = la clé (« pkg-install »), `params` = la valeur (le hash
  # d'arguments), tel quel et non interpolé (l'`Executor` interpole).
  record Step, name : String, params : Hash(String, YAML::Any)

  # Une recette YAML chargée et validée. Porte ses métadonnées
  # (`name`, `description`), ses dépendances (`requires`), ses
  # `parameters` (déclaration typée) / `arguments` (valeurs concrètes
  # d'une copie locale), et ses `steps`.
  class Recipe
    # Clé d'argument RÉSERVÉE : reçoit la valeur POSITIONNELLE d'une entrée
    # `apply_recipes` non-map (ex. `- pkg-add: [a, b]` ou `- pkg-add: htop`).
    # L'Executor la re-mappe sur le paramètre déclaré `positional:`.
    POSITIONAL_ARG = "__positional__"

    getter name : String
    getter description : String
    getter requires : Array(String)
    # Arguments imposés à une dépendance par la forme map de `requires:` :
    #
    #     requires:
    #       - acme
    #       - nginx-lite: { http_extra: "include monappli/*.conf;" }
    #
    # nom de la dépendance → arguments. Les arguments de l'hôte (`apply_recipes`)
    # restent prioritaires (cf. `Executor.merge_required_args`).
    getter requires_args : Hash(String, Hash(String, String))
    # Ordre imposé entre certaines dépendances (`order: [a, b]` → `b` après `a`),
    # en plus du tri topologique : `requires:` reste trié par ordre alphabétique
    # et `order:` dit ce qui doit passer avant quoi (ex. le dépôt pkg avant la
    # recette qui installe son paquet). Chaque nom figure dans `requires:`.
    getter order : Array(String)
    # `requires_vrack: true` → recette ÉCARTÉE par `beryl apply` si le host n'a
    # pas d'IP vRack (ex. `pkg-repo-acme` joint le builder sur le vRack).
    getter requires_vrack : Bool
    # `systems: [linux]` (ou `[freebsd, linux]`) : systèmes pris en charge.
    # FreeBSD seul par défaut ; `beryl apply` ÉCARTE une recette hors de la
    # liste du système de l'hôte (ex. les recettes des défauts de la société
    # sur une VM Linux confiée par un client).
    getter systems : Array(String)
    getter parameters : Hash(String, YAML::Any)
    getter arguments : Hash(String, YAML::Any)
    getter steps : Array(Step)
    getter source_path : String
    # Nom du paramètre qui reçoit la valeur positionnelle (forme concise
    # `- recipe: <valeur>`). nil = pas de forme positionnelle.
    getter positional : String?

    def initialize(
      @name : String,
      @description : String,
      @requires : Array(String),
      @parameters : Hash(String, YAML::Any),
      @arguments : Hash(String, YAML::Any),
      @steps : Array(Step),
      @source_path : String,
      @positional : String? = nil,
      @requires_vrack : Bool = false,
      @requires_args : Hash(String, Hash(String, String)) = {} of String => Hash(String, String),
      @order : Array(String) = [] of String,
      @systems : Array(String) = [FREEBSD],
    )
    end

    # Levée si un fichier de recette est mal formé ou viole une
    # convention (nom ≠ fichier, `steps` mal typé, etc.).
    class InvalidRecipe < Exception
    end

    # Suffixe typé d'un fichier de recette.
    SUFFIX = ".recipe.yml"

    # Charge et valide une recette depuis un fichier `<nom>.recipe.yml`.
    # Le nom de la recette est *dérivé du nom de fichier* (sans le
    # suffixe `.recipe.yml`). Le champ `recipe:` est facultatif ; s'il
    # est présent, il doit correspondre au nom de fichier.
    def self.load(path : String) : Recipe
      expected_name = File.basename(path).rchop(SUFFIX)
      raw =
        begin
          YAML.parse(File.read(path))
        rescue ex : YAML::ParseException
          raise InvalidRecipe.new("recette `#{path}` : YAML invalide — #{ex.message}")
        end

      root = raw.as_h? || raise InvalidRecipe.new(
        "recette `#{path}` : le document doit être un mapping YAML."
      )

      declared = root[YAML::Any.new("recipe")]?.try(&.as_s?)
      if declared && declared != expected_name
        raise InvalidRecipe.new(
          "recette `#{path}` : `recipe: #{declared}` ne correspond pas au nom " \
          "de fichier (`#{expected_name}`). Retirez le champ ou alignez-le."
        )
      end
      name = expected_name

      description = root[YAML::Any.new("description")]?.try(&.as_s?) || ""
      requires, requires_args = parse_requires(root, path)
      requires_vrack = root[YAML::Any.new("requires_vrack")]?.try(&.as_bool?) == true
      systems = parse_systems(root, path)
      order = parse_order(root, requires, path)
      parameters = sub_hash(root, "parameters")
      arguments = sub_hash(root, "arguments")
      steps = parse_steps(root, path)
      positional = root[YAML::Any.new("positional")]?.try(&.as_s?)
      if positional && !parameters.has_key?(positional)
        raise InvalidRecipe.new(
          "recette `#{path}` : `positional: #{positional}` ne correspond à aucun " \
          "paramètre déclaré."
        )
      end

      new(
        name: name,
        description: description,
        requires: requires,
        parameters: parameters,
        arguments: arguments,
        steps: steps,
        source_path: path,
        positional: positional,
        requires_vrack: requires_vrack,
        requires_args: requires_args,
        order: order,
        systems: systems,
      )
    end

    # `systems:` : `linux`, `[freebsd, linux]`… ; absent → FreeBSD seul.
    private def self.parse_systems(root : Hash(YAML::Any, YAML::Any), path : String) : Array(String)
      raw = root[YAML::Any.new("systems")]?
      return [FREEBSD] unless raw
      list = raw.as_a?.try(&.map(&.as_s?)) || [raw.as_s?]
      values = list.compact
      known = [FREEBSD, LINUX]
      if values.empty? || values.size != list.size || !(values - known).empty?
        raise InvalidRecipe.new("recette `#{path}` : `systems:` attend #{known.join(" et/ou ")} (reçu #{raw.inspect}).")
      end
      values.uniq
    end

    # `order:` : liste de noms, tous présents dans `requires:`, sans doublon.
    private def self.parse_order(root : Hash(YAML::Any, YAML::Any), requires : Array(String), path : String) : Array(String)
      raw = root[YAML::Any.new("order")]?
      return [] of String unless raw
      list = raw.as_a? || raise InvalidRecipe.new("recette `#{path}` : `order:` est une liste de dépendances.")
      names = list.map do |entry|
        entry.as_s? || raise InvalidRecipe.new("recette `#{path}` : `order:` — nom de dépendance invalide.")
      end
      names.each do |n|
        unless requires.includes?(n)
          raise InvalidRecipe.new("recette `#{path}` : `order: #{n}` absent de `requires:`.")
        end
      end
      if names.uniq.size != names.size
        raise InvalidRecipe.new("recette `#{path}` : `order:` — dépendance en double.")
      end
      names
    end

    # `requires:` : liste de noms, ou de maps à UNE clé `nom: { arg: valeur }`
    # (arguments scalaires seulement, transmis à la dépendance).
    private def self.parse_requires(root : Hash(YAML::Any, YAML::Any), path : String) : Tuple(Array(String), Hash(String, Hash(String, String)))
      names = [] of String
      args = {} of String => Hash(String, String)
      list = root[YAML::Any.new("requires")]?.try(&.as_a?) || [] of YAML::Any
      list.each do |entry|
        if s = entry.as_s?
          names << s
        elsif (h = entry.as_h?) && h.size == 1
          key, value = h.first
          dep = key.as_s? || raise InvalidRecipe.new("recette `#{path}` : `requires:` — nom de dépendance invalide.")
          given = {} of String => String
          (value.as_h? || {} of YAML::Any => YAML::Any).each do |k, v|
            ks = k.as_s?
            vs = v.as_s? || v.raw.to_s
            raise InvalidRecipe.new("recette `#{path}` : `requires: #{dep}` — argument invalide.") unless ks
            given[ks] = vs
          end
          names << dep
          args[dep] = given
        else
          raise InvalidRecipe.new(
            "recette `#{path}` : chaque entrée de `requires:` est un nom ou une map " \
            "à une clé (`- recette: { arg: valeur }`)."
          )
        end
      end
      {names, args}
    end

    private def self.string_array(root : Hash(YAML::Any, YAML::Any), key : String) : Array(String)
      val = root[YAML::Any.new(key)]?
      return [] of String unless val
      (val.as_a? || [] of YAML::Any).compact_map(&.as_s?)
    end

    private def self.sub_hash(root : Hash(YAML::Any, YAML::Any), key : String) : Hash(String, YAML::Any)
      result = {} of String => YAML::Any
      h = root[YAML::Any.new(key)]?.try(&.as_h?)
      return result unless h
      h.each do |k, v|
        ks = k.as_s?
        result[ks] = v if ks
      end
      result
    end

    private def self.parse_steps(root : Hash(YAML::Any, YAML::Any), path : String) : Array(Step)
      steps = [] of Step
      list = root[YAML::Any.new("steps")]?.try(&.as_a?)
      return steps unless list

      list.each do |entry|
        h = entry.as_h? || raise InvalidRecipe.new(
          "recette `#{path}` : chaque step doit être un mapping à une " \
          "clé (`<primitive>: { … }`)."
        )
        if h.size != 1
          raise InvalidRecipe.new(
            "recette `#{path}` : un step doit avoir exactement une clé " \
            "(la primitive). Trouvé #{h.size} clés : #{h.keys.compact_map(&.as_s?).join(", ")}."
          )
        end
        key_any, value_any = h.first
        prim_name = key_any.as_s? || raise InvalidRecipe.new(
          "recette `#{path}` : nom de primitive non textuel dans un step."
        )
        params = {} of String => YAML::Any
        if ph = value_any.as_h?
          ph.each do |pk, pv|
            pks = pk.as_s?
            params[pks] = pv if pks
          end
        end
        steps << Step.new(name: prim_name, params: params)
      end

      steps
    end
  end
end
