require "../primitive"

module Beryl::Apply
  # Primitive `user-shell` : pose le shell de login d'un utilisateur via
  # `pw usermod <user> -s <shell>` (Linux : `usermod`). Idempotent : skip si le shell est déjà
  # le bon, skip si le user n'existe pas. Capacité ÉTROITE : poser un
  # shell, rien d'autre.
  #
  #     - user-shell:
  #         user: deploy
  #         shell: /usr/local/bin/zsh
  class UserShell < Primitive
    def name : String
      "user-shell"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "user")
      desired = required_string(params, "shell")

      line = shell.exec("getent passwd #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.strip
      return StepResult.skipped("user #{user} absent (créez-le d'abord)") if line.empty?

      current = line.split(':')[6]? || ""
      return StepResult.skipped("#{user} : shell déjà #{desired}") if current == desired
      return StepResult.applied("#{user} : shell #{current} → #{desired} (dry-run)") if dry_run

      # FreeBSD : `pw usermod` ; Linux : `usermod` (shadow-utils).
      tool = context.os == LINUX ? "usermod" : "pw usermod"
      shell.exec("#{tool} #{Process.quote(user)} -s #{Process.quote(desired)}")
      StepResult.applied("#{user} : shell #{current} → #{desired}")
    end
  end

  Primitive.register(UserShell.new)
end
