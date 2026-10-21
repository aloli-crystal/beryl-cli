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

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "name")

      if exists?(shell, user, context.os)
        return StepResult.skipped("user #{user} existe déjà")
      end

      login_shell = string(params, "shell")
      home = string(params, "home")
      comment = string(params, "comment")
      groups = string_array(params, "groups")

      return StepResult.applied("créerait le user #{user} (dry-run)") if dry_run

      # FreeBSD : `pw useradd -n <user> -m …` ; Linux : `useradd -m … <user>`
      # (shadow-utils, mêmes options -s/-d/-G/-c).
      args = context.os == LINUX ? ["useradd", "-m"] : ["pw", "useradd", "-n", user, "-m"]
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
      args << user if context.os == LINUX

      shell.exec(args.map { |a| Process.quote(a) }.join(" "))
      StepResult.applied("user #{user} créé")
    end

    # FreeBSD : `pw usershow <user>` retourne 0 si l'utilisateur existe (et
    # non `pw show <user>`, syntaxe invalide — validé sur le banc QEMU
    # FreeBSD). Linux : `getent passwd <user>`.
    private def exists?(shell : Shell, user : String, os : String) : Bool
      if os == LINUX
        Primitive.probe?(shell, "getent passwd #{Process.quote(user)} >/dev/null 2>&1")
      else
        Primitive.probe?(shell, "pw usershow #{Process.quote(user)} >/dev/null 2>&1")
      end
    end
  end

  Primitive.register(UserCreate.new)
end
