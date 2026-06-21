require "../primitive"

module Beryl::Apply
  # Primitive `auto-close-cancel` : annule un job `at` posé par
  # `auto-close-schedule` (même `tag`). C'est le « commit » du pattern
  # dead-man's-switch : après une bascule destructive (ex. `sshd-overlay-only`),
  # l'opérateur vérifie qu'il garde l'accès, PUIS annule le rollback automatique
  # via cette primitive. S'il ne le fait pas (accès perdu), le job `at` se
  # déclenche et restaure l'état.
  #
  #     - auto-close-cancel:
  #         tag: sshd-overlay-deadman
  #
  # Idempotent : si aucun job ne porte ce tag (déjà déclenché ou jamais posé),
  # on skip sans erreur.
  class AutoCloseCancel < Primitive
    # DOIT correspondre à AutoCloseSchedule::TAG_DIR (même emplacement de tags).
    TAG_DIR = "/var/run/beryl/auto-close"

    def name : String
      "auto-close-cancel"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      tag = required_string(params, "tag")
      tag_file = "#{TAG_DIR}/#{tag}.atjob"

      return StepResult.applied("annule le job auto-close (tag #{tag}) (dry-run)") if dry_run

      existing = shell.exec("cat #{Process.quote(tag_file)} 2>/dev/null", raise_on_error: false).stdout.strip
      if existing.empty?
        return StepResult.skipped("aucun job auto-close pour le tag #{tag}")
      end

      if existing.matches?(/^\d+$/)
        shell.exec("atrm #{Process.quote(existing)} 2>/dev/null", raise_on_error: false)
      end
      shell.exec("rm -f #{Process.quote(tag_file)}", raise_on_error: false)

      StepResult.applied("job auto-close `#{tag}` annulé (job #{existing})")
    end
  end

  Primitive.register(AutoCloseCancel.new)
end
