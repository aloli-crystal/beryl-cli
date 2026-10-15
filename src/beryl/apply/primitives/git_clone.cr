require "../primitive"

module Beryl::Apply
  # Primitive `git-clone` : clone un dépôt git vers `dest` (chemin absolu).
  # Idempotent : skip si `dest` existe déjà. `user:` optionnel → le clone
  # est fait EN TANT QUE cet utilisateur (fichiers lui appartenant), via
  # `sudo -u`. Capacité ÉTROITE et AUDITABLE : l'URL est dans la recette,
  # visible et révisable — contrairement à une primitive `run` qui
  # exécuterait n'importe quoi. `git clone` récupère des fichiers, il
  # n'exécute rien par lui-même.
  #
  #     - git-clone:
  #         repo: https://github.com/ohmyzsh/ohmyzsh.git
  #         dest: /home/deploy/.oh-my-zsh
  #         user: deploy        # optionnel
  class GitClone < Primitive
    def name : String
      "git-clone"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      repo = required_string(params, "repo")
      dest = required_string(params, "dest")
      user = string(params, "user")

      if Primitive.probe?(shell, "test -e #{Process.quote(dest)}")
        return StepResult.skipped("#{dest} déjà présent")
      end
      return StepResult.applied("clone #{repo} → #{dest} (dry-run)") if dry_run

      clone = "git clone --depth=1 #{Process.quote(repo)} #{Process.quote(dest)}"
      if u = user
        shell.exec("sudo -u #{Process.quote(u)} #{clone}")
      else
        shell.exec(clone)
      end
      StepResult.applied("clone #{repo} → #{dest}")
    end
  end

  Primitive.register(GitClone.new)
end
