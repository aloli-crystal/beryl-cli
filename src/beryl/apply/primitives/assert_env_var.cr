require "../primitive"

module Beryl::Apply
  # Primitive `assert-env-var` : refuse la suite de la recette si une
  # variable d'environnement (côté beryl, le poste opérateur, pas le
  # serveur cible) est absente ou vide.
  #
  # Use case : forcer l'opérateur à fournir une raison textuelle avant
  # un changement sensible (cf. recipe `sshd-public-open` qui exige
  # `BERYL_REASON='...'`).
  #
  #     - assert-env-var:
  #         name: BERYL_REASON
  #         message: "Refusé : BERYL_REASON='raison...' obligatoire."
  class AssertEnvVar < Primitive
    def name : String
      "assert-env-var"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      var_name = required_string(params, "name")
      custom_message = string(params, "message")

      value = ENV[var_name]?
      if value.nil? || value.empty?
        message = custom_message || "variable d'environnement `#{var_name}` absente ou vide"
        return StepResult.failed(message)
      end

      # En dry-run comme en réel : c'est un check, pas une action.
      StepResult.skipped("#{var_name} fournie")
    end
  end

  Primitive.register(AssertEnvVar.new)
end
