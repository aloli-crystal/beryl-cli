require "./primitive"
require "./recipe"
require "./template"

module Beryl::Apply
  # Levée AVANT toute exécution quand deux recettes (ou deux jeux d'arguments
  # d'une même recette) écriraient le MÊME fichier : la dernière écraserait
  # silencieusement la première à chaque apply (cf. `Executor.check_paths!`).
  class DuplicatePath < Exception
  end

  # Levée quand deux recettes imposent des valeurs différentes au même
  # argument d'une dépendance commune (forme map de `requires:`).
  class ConflictingRequiredArgs < Exception
  end

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
      recipe_args = self.class.merge_required_args(recipes, recipe_args)
      check_paths!(recipes, recipe_args)
      deferred = [] of Deferred
      recipes.each do |recipe|
        # Une recette peut être jouée PLUSIEURS fois — un fan-out sur un
        # argument liste (ex. `oh-my-zsh: { user: [deploy, pne] }` → une
        # fois par user). Sans args explicites : une seule fois, jeu vide.
        combos = recipe_args[recipe.name]? || [{} of String => String]
        combos.each do |combo|
          vars = build_vars(recipe, combo)
          # Une étape a-t-elle déjà modifié quelque chose dans CETTE recette ?
          # Sert l'option `if_changed: true` (cf. `skip_unchanged?`).
          changed = false
          recipe.steps.each do |step|
            primitive = Primitive[step.name]? || raise UnknownPrimitive.new(
              "primitive `#{step.name}` inconnue (recette `#{recipe.name}`). " \
              "Primitives connues : #{Primitive.registry.keys.sort.join(", ")}."
            )
            params = interpolate(step.params, vars)
            if self.class.skip_unchanged?(params, changed)
              record(report, recipe.name, step.name,
                StepResult.skipped("rien n'a changé dans la recette — #{step.name} inutile (if_changed)"))
              next
            end
            clean = params.reject(IF_CHANGED, DEFERRED)
            if params[DEFERRED]?.try(&.as_bool?) == true
              # Reporté en fin d'apply, une seule fois par (primitive, params).
              unless deferred.any? { |d| d.step == step.name && d.params == clean }
                deferred << Deferred.new(recipe.name, step.name, primitive, clean)
              end
              log("#{recipe.name} › #{step.name} : reporté en fin d'apply (deferred)")
              next
            end
            result = apply_step(primitive, clean)
            changed ||= result.outcome.applied?
            record(report, recipe.name, step.name, result)
            if result.outcome.failed?
              run_deferred(report, deferred)
              return report
            end
          end
        end
      end
      run_deferred(report, deferred)
      report
    end

    # Option d'étape `deferred: true` (valable pour TOUTE primitive) : l'étape
    # n'est pas jouée sur place mais UNE SEULE FOIS en fin d'apply, même si
    # plusieurs recettes la demandent (dédoublonnage sur primitive + params).
    # Sert au rechargement de monit : chaque recette qui dépose une sonde le
    # demandait, et chaque rechargement envoie une alerte « Monit instance
    # changed » (deux courriels identiques sur le builder, 6 oct. 2026).
    # Combinable avec `if_changed: true` (reporté seulement si la recette a
    # changé quelque chose). Jouée aussi après un échec, pour qu'une sonde déjà
    # posée soit chargée (sinon `if_changed` la sauterait au prochain apply).
    # ⚠️ Pas pour nginx : une recette suivante peut avoir besoin de la conf
    # rechargée tout de suite (défi ACME en webroot).
    DEFERRED = "deferred"

    private record Deferred, recipe : String, step : String, primitive : Primitive, params : Hash(String, YAML::Any)

    private def run_deferred(report : Report, deferred : Array(Deferred)) : Nil
      deferred.each do |d|
        result = apply_step(d.primitive, d.params)
        record(report, d.recipe, d.step, result)
      end
      deferred.clear
    end

    private def apply_step(primitive : Primitive, params : Hash(String, YAML::Any)) : StepResult
      primitive.apply(@shell, params, @dry_run, @context)
    rescue ex : SSH::CommandFailed
      StepResult.failed(ex.message || "commande distante échouée")
    rescue ex : Primitive::PrimitiveError
      StepResult.failed(ex.message || "erreur de primitive")
    end

    private def record(report : Report, recipe : String, step : String, result : StepResult) : Nil
      report << Report::Entry.new(recipe: recipe, step: step, result: result)
      log("#{recipe} › #{step} : #{describe(result)}")
    end

    # Option d'étape `if_changed: true` (valable pour TOUTE primitive) :
    # l'étape n'est jouée que si une étape PRÉCÉDENTE de la même recette a
    # modifié quelque chose — l'équivalent des « handlers » d'Ansible. Sert
    # surtout aux rechargements (`service-reload`) : recharger nginx ou monit
    # à chaque apply sans changement est inutile (et, pour monit, chaque
    # rechargement envoie une alerte « instance changed »).
    #
    #     - file-write: { path: /usr/local/etc/nginx/nginx.conf, content: … }
    #     - service-reload: { name: nginx, if_changed: true }
    IF_CHANGED = "if_changed"

    def self.skip_unchanged?(params : Hash(String, YAML::Any), changed : Bool) : Bool
      params[IF_CHANGED]?.try(&.as_bool?) == true && !changed
    end

    # Arguments imposés par les `requires:` en forme map (ex. monappli-base →
    # `nginx-lite: { http_extra: "include monappli/*.conf;" }`) : servent de BASE à chaque jeu
    # d'arguments de la dépendance ; ceux de l'hôte restent prioritaires.
    # Deux recettes qui imposent des valeurs différentes au même argument →
    # `ConflictingRequiredArgs` (aucune ne peut gagner silencieusement).
    def self.merge_required_args(recipes : Array(Recipe), recipe_args : Hash(String, Array(Hash(String, String)))) : Hash(String, Array(Hash(String, String)))
      imposed = {} of String => Hash(String, String)
      origin = {} of String => String
      recipes.each do |requirer|
        requirer.requires_args.each do |dep, args|
          base = imposed[dep] ||= {} of String => String
          args.each do |k, v|
            if (prev = base[k]?) && prev != v
              raise ConflictingRequiredArgs.new(
                "`#{dep}` : l'argument `#{k}` est imposé à « #{prev} » par `#{origin["#{dep}.#{k}"]}` " \
                "et à « #{v} » par `#{requirer.name}` — recettes incompatibles sur ce serveur."
              )
            end
            base[k] = v
            origin["#{dep}.#{k}"] = requirer.name
          end
        end
      end
      merged = recipe_args.dup
      imposed.each do |dep, base|
        combos = recipe_args[dep]? || [{} of String => String]
        merged[dep] = combos.map { |c| base.merge(c) }
      end
      merged
    end

    # Primitives qui POSSÈDENT le fichier qu'elles écrivent (contenu complet).
    # `line-in-file` n'en fait pas partie : plusieurs recettes peuvent
    # légitimement ajouter chacune leur ligne au même fichier.
    OWNING_PRIMITIVES = %w(file-write secret-file)

    # Garde « une recette par fichier » : avant toute exécution, interpole le
    # `path` de chaque écriture complète et refuse que deux recettes (ou deux
    # jeux d'arguments d'une même recette) visent le même fichier — sinon la
    # dernière écraserait l'autre à chaque apply, sans erreur. Un chemin
    # non interpolable ici (variable inconnue) est laissé au déroulé normal,
    # qui signalera l'erreur à son étape.
    private def check_paths!(recipes : Array(Recipe), recipe_args : Hash(String, Array(Hash(String, String)))) : Nil
      owners = {} of String => String
      recipes.each do |recipe|
        combos = recipe_args[recipe.name]? || [{} of String => String]
        combos.each_with_index do |combo, i|
          label = combos.size > 1 ? "#{recipe.name} (jeu d'arguments #{i + 1})" : recipe.name
          vars = build_vars(recipe, combo) rescue next
          recipe.steps.each do |step|
            next unless OWNING_PRIMITIVES.includes?(step.name)
            raw = step.params["path"]?.try(&.as_s?) || next
            path = (Template.has_placeholder?(raw) ? Template.render(raw, vars) : raw) rescue next
            if (other = owners[path]?) && other != label
              raise DuplicatePath.new(
                "#{path} serait écrit par `#{other}` ET par `#{label}` : la seconde écraserait " \
                "la première à chaque apply. Une seule recette par fichier (nginx : un fichier " \
                "par site dans conf.d/, cf. nginx-lite)."
              )
            end
            owners[path] = label
          end
        end
      end
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
        if (env_name = dh[YAML::Any.new("from_env")]?.try(&.as_s?)) && (v = Apply.secret(env_name, @context))
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

    # Interpole les `{{ … }}` de chaque valeur string des params, EN DESCENDANT
    # récursivement dans les listes et les maps imbriquées (ex. `domains: [
    # "{{ hostname }}.example.net", … ]`). Les scalaires non-string et les
    # strings sans placeholder passent inchangés.
    private def interpolate(params : Hash(String, YAML::Any), vars : Hash(String, String)) : Hash(String, YAML::Any)
      out = {} of String => YAML::Any
      params.each { |key, value| out[key] = interpolate_value(value, vars) }
      out
    end

    private def interpolate_value(value : YAML::Any, vars : Hash(String, String)) : YAML::Any
      if s = value.as_s?
        Template.has_placeholder?(s) ? YAML::Any.new(Template.render(s, vars)) : value
      elsif arr = value.as_a?
        YAML::Any.new(arr.map { |e| interpolate_value(e, vars) })
      elsif h = value.as_h?
        interpolated = {} of YAML::Any => YAML::Any
        h.each { |k, v| interpolated[k] = interpolate_value(v, vars) }
        YAML::Any.new(interpolated)
      else
        value
      end
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
