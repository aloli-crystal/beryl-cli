require "../primitive"

module Beryl::Apply
  # Primitive `user-create` : crée un utilisateur via `pw useradd`.
  #
  # Idempotence : `pw show <user>` avant action — si l'utilisateur
  # existe déjà, on ne touche pas à ses attributs (skip). La mise à
  # jour d'attributs (shell, groupes) relève d'une primitive dédiée
  # future ; ici on ne fait que créer l'absent.
  #
  #     - user-create:
  #         name: deploy
  #         shell: /usr/local/bin/zsh   # optionnel
  #         home: /home/deploy          # optionnel (home créé : -m)
  #         groups: [wheel, www]        # optionnel (groupes secondaires)
  #         comment: "Compte de deploy" # optionnel (gecos)
  class UserCreate < Primitive
    def name : String
      "user-create"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "name")

      if exists?(shell, user)
        return StepResult.skipped("user #{user} existe déjà")
      end

      login_shell = string(params, "shell")
      home = string(params, "home")
      comment = string(params, "comment")
      groups = string_array(params, "groups")

      return StepResult.applied("créerait le user #{user} (dry-run)") if dry_run

      args = ["useradd", "-n", user, "-m"]
      if s = login_shell
        args << "-s" << s
      end
      if h = home
        args << "-d" << h
      end
      unless groups.empty?
        args << "-G" << groups.join(",")
      end
      if c = comment
        args << "-c" << c
      end

      shell.exec("pw #{args.map { |a| Process.quote(a) }.join(" ")}")
      StepResult.applied("user #{user} créé")
    end

    # `pw usershow <user>` retourne 0 si l'utilisateur existe. (Et non
    # `pw show <user>`, qui est une syntaxe invalide — `pw` attend
    # `usershow`/`groupshow`/… ; validé sur le banc QEMU FreeBSD.)
    private def exists?(shell : Shell, user : String) : Bool
      Primitive.probe?(shell, "pw usershow #{Process.quote(user)} >/dev/null 2>&1")
    end
  end

  Primitive.register(UserCreate.new)
end
