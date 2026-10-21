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
  # chargé avant, avec `set -a`. Ils peuvent tenir sur plusieurs lignes (bloc
  # YAML `|`) : le script voyage en base64, à l'abri du shell de connexion
  # (csh). En dry-run, seule la garde est jouée : elle doit donc être en
  # LECTURE SEULE.
  #
  # Une garde qui ne s'exécute pas (commande introuvable, erreur de syntaxe du
  # shell) met l'étape en FAILED, en dry-run comme en --apply : ce n'est pas un
  # « pas encore fait ». Une garde qui répond « non » en écrivant sur stderr
  # reste un « would apply », avec ce stderr dans le compte rendu.
  class Command < Primitive
    USER_RE = /\A[a-z_][a-z0-9_-]{0,31}\z/

    def name : String
      "command"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
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

      guard_res = shell.exec(wrap(guard, user, env_file), raise_on_error: false)
      return StepResult.skipped("déjà fait (garde `unless` satisfaite)") if guard_res.success?
      guard_err = summary(guard_res.stderr)
      if Primitive.broken_probe?(guard_res.exit_code, guard_res.stderr)
        return StepResult.failed("garde `unless` cassée (code #{guard_res.exit_code}) : " \
                                 "#{guard_err.empty? ? "aucune sortie" : guard_err} — rien n'a été lancé")
      end
      # La garde a répondu « non » ; ce qu'elle a écrit sur stderr (psql sur une
      # base absente…) reste visible dans le compte rendu.
      seen = guard_err.empty? ? "" : " — garde : #{guard_err}"
      return StepResult.applied("lancerait : #{run} (dry-run)#{seen}") if dry_run

      res = shell.exec(wrap(run, user, env_file), raise_on_error: false)
      unless res.success?
        detail = summary(res.stdout + res.stderr)
        return StepResult.failed("`#{run}` en échec (code #{res.exit_code}) : #{detail.empty? ? "aucune sortie" : detail}")
      end
      out = res.stdout.strip
      StepResult.applied(show && !out.empty? ? "#{run}\n#{out}" : run)
    end

    private def summary(text : String) : String
      text.strip.lines.map(&.strip).reject(&.empty?).last(5).join(" | ")
    end

    # Ligne `sh -c` sûre quel que soit le shell de connexion (csh possible, et
    # `su -m` garde celui de root) : un script multi-ligne voyage en base64
    # (cf. `Apply.sh_line`). L'environnement est chargé avant (`set -a`) ; un
    # `env_file` illisible est signalé sur stderr. Puis, au besoin, `su -m`.
    private def wrap(command : String, user : String, env_file : String) : String
      script = if env_file.empty?
                 command
               else
                 f = Process.quote(env_file)
                 "[ -r #{f} ] || { echo \"beryl : env_file absent ou illisible : \"#{f} >&2; exit 1; }\n" \
                 "set -a && . #{f} && set +a || exit 1\n#{command}"
               end
      inner = Apply.sh_line(script)
      user.empty? ? inner : "su -m #{user} -c #{Process.quote(inner)}"
    end
  end

  Primitive.register(Command.new)
end
