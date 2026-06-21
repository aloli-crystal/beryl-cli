require "../primitive"

module Beryl::Apply
  # Primitive `auto-close-schedule` : pose un `at +Nh` qui rejoue une
  # autre recipe sur ce même host. Sert au pattern « fenêtre temporaire »
  # (cf. `sshd-public-open` qui ouvre 22 pour 1 h, auto-close via cette
  # primitive). Idempotent : si un job `at` du même tag existe déjà,
  # on le supprime et on en pose un nouveau (réinitialisation du compteur).
  #
  #     - auto-close-schedule:
  #         tag: sshd-public-window
  #         after_hours: 1
  #         recipe: sshd-public-close
  #
  # Le job posé exécute `beryl apply --recipe <recipe>` au moment où
  # il se déclenche. Il faut donc que le binaire `beryl` soit présent
  # côté serveur cible (cf. recipe `beryl-bin` à venir, ou
  # `pkg-install` du shard packagé).
  #
  # Le tag distingue plusieurs fenêtres concurrentes sur le même host
  # (ex. l'opérateur lance deux `sshd-public-open` avec des durées
  # différentes — chacune a son tag unique).
  class AutoCloseSchedule < Primitive
    TAG_DIR = "/var/run/beryl/auto-close"

    def name : String
      "auto-close-schedule"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      tag = required_string(params, "tag")
      recipe = required_string(params, "recipe")

      # Délai : `after_minutes` (granularité fine, ex. dead-man's-switch de
      # `sshd-overlay-only`) OU `after_hours` (fenêtre longue, ex.
      # `sshd-public-open`). `at` ne descend pas sous la minute. Défaut 1 h.
      after_minutes = string(params, "after_minutes").try(&.to_i?)
      after_hours = string(params, "after_hours").try(&.to_i?)
      if after_minutes
        at_spec = "#{after_minutes} minutes"
        human = "#{after_minutes} min"
      elsif after_hours
        at_spec = "#{after_hours} hours"
        human = "#{after_hours} h"
      else
        at_spec = "1 hours"
        human = "1 h"
      end

      tag_file = "#{TAG_DIR}/#{tag}.atjob"

      msg = "auto-close `#{recipe}` dans #{human} (tag #{tag})"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("mkdir -p #{Process.quote(TAG_DIR)} && chmod 0700 #{Process.quote(TAG_DIR)}")

      # 1. Si un job existant porte ce tag, on l'annule (on le remplace).
      existing = shell.exec("cat #{Process.quote(tag_file)} 2>/dev/null", raise_on_error: false).stdout.strip
      if !existing.empty? && existing.matches?(/^\d+$/)
        shell.exec("atrm #{Process.quote(existing)} 2>/dev/null", raise_on_error: false)
      end

      # 2. Poser le nouveau job.
      at_command = "beryl apply --recipe #{Process.quote(recipe)} $(hostname -f)"
      submit = shell.exec(
        "echo #{Process.quote(at_command)} | at now + #{at_spec} 2>&1",
        raise_on_error: false,
      )
      unless submit.success?
        return StepResult.failed("at submit échoue : #{submit.stderr.strip}")
      end

      # `at` écrit sur stderr une ligne « job <N> at <date> » au submit.
      # On l'extrait pour la stocker en tag.
      output = submit.stdout + submit.stderr
      job_id = output.match(/job\s+(\d+)/).try(&.[1]?)
      if job_id
        shell.exec("printf '%s\\n' #{Process.quote(job_id)} > #{Process.quote(tag_file)}")
      end

      StepResult.applied(msg)
    end
  end

  Primitive.register(AutoCloseSchedule.new)
end
