require "../primitive"

module Beryl::Apply
  # Primitive `freshclam` : télécharge la base virale ClamAV via `freshclam`
  # si elle est absente. clamd refuse de démarrer sans base → on la pose
  # AVANT de lancer le démon. Idempotente et auto-gardée : skip si une base
  # est déjà présente dans `/var/db/clamav`. Requiert que `freshclam.conf`
  # existe (posé par la recette avant ce step).
  #
  #     - freshclam: {}
  class Freshclam < Primitive
    def name : String
      "freshclam"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      present = Primitive.probe?(shell, "ls /var/db/clamav/*.c?d >/dev/null 2>&1")
      return StepResult.skipped("base ClamAV déjà présente") if present
      return StepResult.applied("téléchargerait la base ClamAV (dry-run)") if dry_run

      shell.exec("freshclam")
      StepResult.applied("base virale ClamAV téléchargée")
    end
  end

  Primitive.register(Freshclam.new)
end
