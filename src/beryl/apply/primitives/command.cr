require "../primitive"

module Beryl::Apply
  # Primitive `command` : lance une commande UNE FOIS, gardée par `unless`
  # (commande de contrôle : code 0 → déjà fait, skip). Dernier recours, pour
  # une action d'appli qu'aucune primitive ne couvre (amorçage d'un premier
  # compte…) : sans garde, elle serait rejouée à chaque apply, d'où `unless`
  # OBLIGATOIRE.
  #
  #     - command:
  #         run: "monappli-manage bootstrap --email={{ bootstrap_email }}"
  #         unless: "psql -d monappli -tAc \"…\" | grep -q 1"
  #         user: monappli                             # facultatif (défaut root)
  #         env_file: /usr/local/etc/monappli/monappli.env   # facultatif
  #         if_set: "{{ bootstrap_email }}"            # vide → étape sautée
  #         show_output: true                          # sortie dans le compte rendu
  #
  # `run` et `unless` passent par `sh -c` ; `env_file` (lignes VAR=valeur) est
  # chargé avant, avec `set -a`. En dry-run, seule la garde est jouée : elle
  # doit donc être en LECTURE SEULE.
  class Command < Primitive
    USER_RE = /\A[a-z_][a-z0-9_-]{0,31}\z/

    def name : String
      "command"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      if params.has_key?("if_set") && (params["if_set"].as_s? || "").strip.empty?
        return StepResult.skipped("paramètre vide (if_set) — commande non demandée")
      end
      run = required_string(params, "run").strip
      guard = required_string(params, "unless").strip
      raise PrimitiveError.new("`command` : `run` vide") if run.empty?
      raise PrimitiveError.new("`command` : `unless` vide — la garde est obligatoire") if guard.empty?
      user = params["user"]?.try(&.as_s?).try(&.strip) || ""
      if !user.empty? && !user.matches?(USER_RE)
        raise PrimitiveError.new("`command` : utilisateur invalide « #{user} »")
      end
      env_file = params["env_file"]?.try(&.as_s?).try(&.strip) || ""
      show = params["show_output"]?.try(&.as_bool?) == true

      if shell.exec(wrap(guard, user, env_file), raise_on_error: false).success?
        return StepResult.skipped("déjà fait (garde `unless` satisfaite)")
      end
      return StepResult.applied("lancerait : #{run} (dry-run)") if dry_run

      res = shell.exec(wrap(run, user, env_file), raise_on_error: false)
      unless res.success?
        detail = (res.stdout + res.stderr).strip.lines.last(5).join(" | ")
        return StepResult.failed("`#{run}` en échec (code #{res.exit_code}) : #{detail.empty? ? "aucune sortie" : detail}")
      end
      out = res.stdout.strip
      StepResult.applied(show && !out.empty? ? "#{run}\n#{out}" : run)
    end

    # `sh -c` (le shell de connexion distant peut être csh), avec l'environnement
    # chargé puis, au besoin, sous l'utilisateur demandé.
    private def wrap(command : String, user : String, env_file : String) : String
      script = env_file.empty? ? command : "set -a && . #{Process.quote(env_file)} && set +a && #{command}"
      inner = "sh -c #{Process.quote(script)}"
      user.empty? ? inner : "su -m #{user} -c #{Process.quote(inner)}"
    end
  end

  Primitive.register(Command.new)
end
