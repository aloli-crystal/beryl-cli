require "yaml"

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
    # `requires_vrack: true` → recette ÉCARTÉE par `beryl apply` si le host n'a
    # pas d'IP vRack (ex. `pkg-repo-quimeo` joint le builder sur le vRack).
    getter requires_vrack : Bool
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
      requires = string_array(root, "requires")
      requires_vrack = root[YAML::Any.new("requires_vrack")]?.try(&.as_bool?) == true
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
      )
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
