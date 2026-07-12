require "./primitive"
require "./recipe"
require "./template"

module Beryl::Apply
  # Levée quand un step référence une primitive inconnue du registre.
  class UnknownPrimitive < Exception
  end

  # Rapport d'exécution : un enregistrement par step + des compteurs
  # agrégés pour la ligne finale (« N étapes : X skipped, Y applied,
  # Z failed »).
  class Report
    record Entry, recipe : String, step : String, result : StepResult

    getter entries = [] of Entry

    def <<(entry : Entry) : Nil
      @entries << entry
    end

    def total : Int32
      @entries.size
    end

    def skipped : Int32
      @entries.count(&.result.outcome.skipped?)
    end

    def applied : Int32
      @entries.count(&.result.outcome.applied?)
    end

    def failed : Int32
      @entries.count(&.result.outcome.failed?)
    end

    def summary_line : String
      "#{total} étape(s) : #{skipped} skipped, #{applied} applied, #{failed} failed"
    end
  end

  # Déroule des recettes déjà ordonnées (cf. `Resolver`) : pour chaque
  # recette, chaque step est dispatché vers sa primitive. Les valeurs
  # string des params sont interpolées (`{{ var }}`) à partir des
  # `arguments`/`parameters` de la recette.
  #
  # Idempotence : c'est chaque primitive qui lit l'état réel et décide
  # skip/apply. En `dry_run`, rien n'est modifié.
  #
  # Stop net sur erreur (décision de design) : un step qui échoue
  # (`SSH::CommandFailed`) est marqué `failed`, le déroulé s'arrête, le
  # rapport partiel est retourné. L'opérateur corrige et relance —
  # l'idempotence skippe ce qui était déjà OK.
  class Executor
    def initialize(@shell : Shell, @dry_run : Bool = false, @context : Context = Context.new)
    end

    def run(recipes : Array(Recipe), recipe_args : Hash(String, Array(Hash(String, String))) = {} of String => Array(Hash(String, String))) : Report
      report = Report.new
      recipes.each do |recipe|
        # Une recette peut être jouée PLUSIEURS fois — un fan-out sur un
        # argument liste (ex. `oh-my-zsh: { user: [deploy, pne] }` → une
        # fois par user). Sans args explicites : une seule fois, jeu vide.
        combos = recipe_args[recipe.name]? || [{} of String => String]
        combos.each do |combo|
          vars = build_vars(recipe, combo)
          recipe.steps.each do |step|
            primitive = Primitive[step.name]? || raise UnknownPrimitive.new(
              "primitive `#{step.name}` inconnue (recette `#{recipe.name}`). " \
              "Primitives connues : #{Primitive.registry.keys.sort.join(", ")}."
            )
            params = interpolate(step.params, vars)
            result =
              begin
                primitive.apply(@shell, params, @dry_run, @context)
              rescue ex : SSH::CommandFailed
                StepResult.failed(ex.message || "commande distante échouée")
              rescue ex : Primitive::PrimitiveError
                StepResult.failed(ex.message || "erreur de primitive")
              end
            report << Report::Entry.new(recipe: recipe.name, step: step.name, result: result)
            log("#{recipe.name} › #{step.name} : #{describe(result)}")
            return report if result.outcome.failed?
          end
        end
      end
      report
    end

    # Construit la table des variables scalaires interpolables :
    # défauts déclarés dans `parameters`, écrasés par les `arguments`
    # concrets. Seuls les scalaires string sont retenus (Phase 1).
    private def build_vars(recipe : Recipe, extra : Hash(String, String) = {} of String => String) : Hash(String, String)
      vars = {} of String => String
      # Variables built-in de beryl (société, fqdn…) d'abord : disponibles
      # partout, surchargeables par les parameters/arguments de la recette.
      @context.vars.each { |k, v| vars[k] = v }
      recipe.parameters.each do |key, decl|
        next unless dh = decl.as_h?
        # `from_env: VAR` → valeur par défaut depuis le COFFRE (ENV injecté
        # par `apply_all_credentials_to_env!`) si présente et non vide :
        # prioritaire sur `default:`, mais surchargée par un argument explicite
        # (forme map ou positionnelle). Permet `- smtp-relay` nu avec l'adresse
        # dans le coffre, et `- smtp-relay: autre@x.fr` pour la surcharger.
        if (env_name = dh[YAML::Any.new("from_env")]?.try(&.as_s?)) && (v = ENV[env_name]?) && !v.empty?
          vars[key] = v
        elsif default = dh[YAML::Any.new("default")]?.try(&.as_s?)
          vars[key] = resolve_builtins(default)
        end
      end
      recipe.arguments.each do |key, value|
        if s = value.as_s?
          vars[key] = resolve_builtins(s)
        end
      end
      # Arguments fournis par l'hôte (apply_recipes forme map) : priorité max.
      extra.each { |k, v| vars[k] = resolve_builtins(v) }
      # Forme positionnelle (`- pkg-add: htop`) : la valeur réservée est
      # re-mappée sur le paramètre `positional:` déclaré par la recette.
      if (pos = recipe.positional) && (pv = extra[Recipe::POSITIONAL_ARG]?)
        vars[pos] = pv
      end
      vars
    end

    # Résout les variables BUILT-IN de beryl (`company`, `fqdn`, `hostname`,
    # `domain`, `vrack_ip`, `public_ip` — cf. `Apply::Context.vars`) dans une
    # valeur de `default:` ou d'argument `apply_recipes`. Permet à une recette
    # de défaut-er un paramètre sur un fait du host sans le dupliquer côté YAML :
    #
    #     parameters:
    #       ip: { default: "{{ vrack_ip }}" }   # → lit `vrack.ip` du host
    #
    # Seuls les built-in (fournis par le CLI) sont visibles ici — pas les
    # autres paramètres de la recette, pour éviter toute dépendance d'ordre.
    # Une valeur sans `{{ … }}` passe inchangée ; un placeholder inconnu lève
    # `Template::UnknownVariable` (le host ne fournit pas ce fait).
    private def resolve_builtins(value : String) : String
      return value unless Template.has_placeholder?(value)
      Template.render(value, @context.vars)
    end

    # Interpole les valeurs string contenant `{{ … }}`. Les autres
    # valeurs (listes, scalaires sans placeholder) passent inchangées.
    private def interpolate(params : Hash(String, YAML::Any), vars : Hash(String, String)) : Hash(String, YAML::Any)
      out = {} of String => YAML::Any
      params.each do |key, value|
        if (s = value.as_s?) && Template.has_placeholder?(s)
          out[key] = YAML::Any.new(Template.render(s, vars))
        else
          out[key] = value
        end
      end
      out
    end

    private def describe(result : StepResult) : String
      tag = case result.outcome
            in Outcome::Skipped then "skip"
            in Outcome::Applied then @dry_run ? "would apply" : "applied"
            in Outcome::Failed  then "FAILED"
            end
      "#{tag} — #{result.message}"
    end

    private def log(message : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl apply] #{message}"
    end
  end
end
