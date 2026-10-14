require "yaml"
require "./shell"

module Beryl::Apply
  # Issue de l'exécution d'un step (une invocation de primitive).
  #
  # * `skipped`  : l'état était déjà conforme, rien fait.
  # * `applied`  : une modification a été appliquée (ou le serait hors
  #   dry-run).
  # * `failed`   : l'exécution a échoué (réservé ; en pratique les
  #   primitives lèvent une exception, capturée par l'`Executor`).
  enum Outcome
    Skipped
    Applied
    Failed
  end

  # Contexte d'exécution transmis aux primitives, porteur d'infos
  # dérivées du host qui ne tiennent pas dans les params d'un step.
  #
  # * `protected_keys` : clés publiques SSH que beryl utilise pour se
  #   connecter (dérivées de `host.identity_file`). La primitive
  #   `user-update-keys` refuse de les retirer — garde-fou pour ne pas
  #   se couper la branche sur laquelle on est assis en plein apply.
  # * `vars` : variables built-in fournies par beryl (société/`company`,
  #   `fqdn`, `hostname`, `domain`, et `vrack_ip` si l'hôte est dans un
  #   vRack), interpolables `{{ … }}` dans toutes les recettes — ex.
  #   `VersionAddendum: "{{ company }}"`, `listen {{ vrack_ip }}:80`.
  record Context,
    protected_keys : Array(String) = [] of String,
    vars : Hash(String, String) = {} of String => String

  # Variable du coffre PROPRE À UN SERVEUR : `<NOM>__<HÔTE>` (nom court en
  # majuscules, tout caractère hors [A-Z0-9] → `_`). Ex. sur loulou :
  # `PARTIDUO_AGENT_TOKEN__LOULOU`.
  def self.host_secret_name(name : String, hostname : String) : String
    "#{name}__#{hostname.upcase.gsub(/[^A-Z0-9]/, "_")}"
  end

  # Valeur d'un secret du coffre (injecté dans ENV) pour ce serveur : la
  # variante propre au serveur d'abord, puis, sauf `per_host`, la variable
  # commune à la société. nil si absente ou vide. Un secret qui doit être
  # distinct par serveur (jeton, clé) demande `per_host: true` : la valeur
  # commune est alors refusée, plutôt que de réutiliser celle d'un autre.
  def self.secret(name : String, context : Context, per_host : Bool = false) : String?
    if (host = context.vars["hostname"]?) && !host.empty?
      v = ENV[host_secret_name(name, host)]?
      return v if v && !v.empty?
    end
    return nil if per_host
    v = ENV[name]?
    v && !v.empty? ? v : nil
  end

  # Résultat d'un step : son `outcome` et un message lisible pour le
  # rapport (« nginx déjà installé », « +2 packages : zsh, tmux »).
  record StepResult, outcome : Outcome, message : String do
    def self.skipped(message : String) : StepResult
      new(Outcome::Skipped, message)
    end

    def self.applied(message : String) : StepResult
      new(Outcome::Applied, message)
    end

    def self.failed(message : String) : StepResult
      new(Outcome::Failed, message)
    end
  end

  # Tâche élémentaire idempotente exécutée sur l'hôte distant. Chaque
  # primitive lit l'état réel via `shell` avant d'agir et retourne un
  # `StepResult`. En `dry_run`, elle calcule le delta mais n'applique
  # rien (`Outcome::Applied` annonce alors ce qui *serait* fait).
  abstract class Primitive
    # Nom kebab-case utilisé comme clé de step dans les recettes
    # (« pkg-install », « service-enable », …).
    abstract def name : String

    # `params` est le hash brut du step YAML (ex: `{"packages" => [...]}`),
    # déjà interpolé par l'`Executor`. `context` porte les infos
    # dérivées du host (cf. `Context`).
    abstract def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult

    # Registre global nom → instance de primitive. Peuplé par chaque
    # fichier de primitive via `Primitive.register`.
    @@registry = {} of String => Primitive

    def self.register(primitive : Primitive) : Nil
      @@registry[primitive.name] = primitive
    end

    def self.[]?(name : String) : Primitive?
      @@registry[name]?
    end

    def self.registry : Hash(String, Primitive)
      @@registry
    end

    # Helpers de lecture typée des params, tolérants au YAML (`as_a?`,
    # `as_s?`) — factorisés ici pour toutes les primitives.

    # Liste de strings depuis `params[key]` (vide si absent ou mal typé).
    protected def string_array(params : Hash(String, YAML::Any), key : String) : Array(String)
      val = params[key]?
      return [] of String unless val
      if arr = val.as_a?
        arr.compact_map(&.as_s?)
      elsif (s = val.as_s?) && !s.empty?
        # Tolère un scalaire string seul → liste à un élément. On NE splitte
        # PAS sur les espaces : certains appelants (`keys` SSH) contiennent des
        # espaces légitimes. Permet `pkg-add: { packages: htop }` (+ fan-out
        # pour une liste).
        [s]
      else
        [] of String
      end
    end

    # Scalaire string depuis `params[key]` (nil si absent ou mal typé).
    # Tolère aussi un scalaire entier/booléen (rendu en string), pour
    # accepter `value: 22` ou `value: yes` sans guillemets côté YAML.
    protected def string(params : Hash(String, YAML::Any), key : String) : String?
      val = params[key]?
      return nil unless val
      if s = val.as_s?
        s
      elsif (i = val.as_i64?)
        i.to_s
      elsif !val.as_bool?.nil?
        val.as_bool.to_s
      else
        nil
      end
    end

    # Commande `service <svc> <action>` qui ne retient PAS la session SSH : un
    # script rc.d qui lance son démon sans fermer ses descripteurs (daemon(8)
    # sans -f) lui transmet stdin/stdout de la session, et l'apply attend
    # alors indéfiniment la fin d'un démon qui ne finit jamais (partiduo_admin,
    # loulou, 6 oct. 2026). Les descripteurs du démon pointent ici vers un
    # fichier temporaire, relu ensuite : la sortie et le code de retour de
    # `service` sont conservés.
    def self.service_command(svc : String, action : String) : String
      "out=$(mktemp \"${TMPDIR:-/tmp}/beryl-service.XXXXXX\") && " \
      "{ service #{Process.quote(svc)} #{action} </dev/null >\"$out\" 2>&1; rc=$?; " \
      "cat \"$out\"; rm -f \"$out\"; exit $rc; }"
    end

    # Comme `string` mais lève `MissingParam` si absent — pour les
    # paramètres obligatoires (`name`, `path`, `key`, …).
    protected def required_string(params : Hash(String, YAML::Any), key : String) : String
      string(params, key) || raise MissingParam.new(
        "paramètre `#{key}` obligatoire et manquant pour la primitive `#{name}`."
      )
    end

    # Booléen depuis `params[key]` (défaut `default` si absent).
    protected def bool(params : Hash(String, YAML::Any), key : String, default : Bool = false) : Bool
      val = params[key]?
      return default unless val
      b = val.as_bool?
      b.nil? ? default : b
    end

    # Base des erreurs « métier » d'une primitive (param manquant,
    # garde-fou déclenché, …). L'`Executor` les traite comme un step
    # `failed` (stop net) plutôt que comme un crash inattendu.
    class PrimitiveError < Exception
    end

    # Levée quand un paramètre obligatoire d'un step est absent.
    class MissingParam < PrimitiveError
    end
  end
end
