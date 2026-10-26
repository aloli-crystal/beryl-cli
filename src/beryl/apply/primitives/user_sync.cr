require "../primitive"

module Beryl::Apply
  # Primitive `user-sync` : réconcilie UN compte depuis sa déclaration
  # `freebsd.users`. Idempotente.
  #
  #     - user-sync:
  #         name: deploy
  #         secondary_groups: [www, wheel]
  #         shell: /usr/local/bin/zsh   # optionnel
  #         primary_group: www          # optionnel
  #         state: present              # ou `absent` → pw userdel
  #
  # Groupes EXACTS quand ils sont déclarés (`secondary_groups` ou alias
  # `groups`, même vide) : le user est ajouté aux groupes listés et RETIRÉ des
  # autres groupes secondaires — la fiche fait foi, aussi sur un compte déjà
  # créé (ex. `deploy` sorti de `wheel`). Rien de déclaré : groupes laissés tels
  # quels. Jamais retiré : son groupe principal, ni `wheel` du compte par
  # lequel beryl se connecte (`connect_user` : il se couperait son sudo).
  # `primary_group` déclaré : posé aussi sur un compte existant. Le `shell`
  # n'est posé ici qu'à la CRÉATION : sur un user existant, le changement de
  # shell passe par `user-shell` (chemin déclaré) ou par sa recette
  # (`oh-my-zsh`) — sinon les deux se contrediraient (flap csh↔zsh). La suppression
  # exige `state: absent` EXPLICITE (jamais par absence) et garde le /home.
  class UserSync < Primitive
    def name : String
      "user-sync"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "name")
      state = string(params, "state") || "present"
      line = shell.exec("getent passwd #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.strip
      exists = !line.empty?

      if state == "absent"
        return StepResult.skipped("#{user} déjà absent") unless exists
        return StepResult.applied("#{user} : compte supprimé (dry-run)") if dry_run
        shell.exec("pw userdel #{Process.quote(user)}") # /home conservé (pas de -r)
        return StepResult.applied("#{user} : compte supprimé (home conservé)")
      end

      # `secondary_groups` (canonique, comme le bootstrap) + alias `groups`.
      groups = (string_array(params, "secondary_groups") + string_array(params, "groups")).uniq
      shell_path = string(params, "shell")
      primary = string(params, "primary_group")

      unless exists
        return StepResult.applied("#{user} : à créer (dry-run)") if dry_run
        args = ["useradd", "-n", user, "-m"]
        args.concat(["-g", primary]) if primary
        args.concat(["-G", groups.join(",")]) unless groups.empty?
        args.concat(["-s", shell_path]) if shell_path
        shell.exec("pw #{args.map { |a| Process.quote(a) }.join(" ")}")
        return StepResult.applied("#{user} : créé")
      end

      # Compte existant → réconciliation (groupes exacts s'ils sont déclarés).
      changes = [] of String
      current_groups = shell.exec("id -Gn #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.split
      # `id -Gn` : le groupe principal d'abord.
      current_primary = current_groups.first?
      if primary && current_primary && primary != current_primary
        shell.exec("pw usermod #{Process.quote(user)} -g #{Process.quote(primary)}") unless dry_run
        changes << "groupe principal #{current_primary} → #{primary}"
        current_primary = primary
      end
      groups.each do |g|
        next if current_groups.includes?(g)
        shell.exec("pw groupmod #{Process.quote(g)} -m #{Process.quote(user)}") unless dry_run
        changes << "+#{g}"
      end
      kept = nil
      if declares_groups?(params)
        # Groupes principaux (actuel, déclaré, et l'ancien s'il vient de changer) :
        # jamais retirés, ce ne sont pas des appartenances secondaires.
        (current_groups - groups - [current_groups.first?, current_primary, primary].compact).each do |g|
          if g == "wheel" && user == context.vars["connect_user"]?
            kept = "wheel conservé : compte de connexion de beryl"
            next
          end
          shell.exec("pw groupmod #{Process.quote(g)} -d #{Process.quote(user)}") unless dry_run
          changes << "-#{g}"
        end
      end

      # Le shell d'un user EXISTANT n'est pas touché ici (cf. en-tête) :
      # une recette s'en charge (oh-my-zsh / user-shell), sans flap.

      return StepResult.skipped("#{user} : conforme#{kept ? " (#{kept})" : ""}") if changes.empty?
      msg = "#{user} : #{(changes + [kept].compact).join(", ")}"
      StepResult.applied(dry_run ? "#{msg} (dry-run)" : msg)
    end

    # Groupes secondaires déclarés (clé présente, même liste vide) ? Pur.
    def declares_groups?(params : Hash(String, YAML::Any)) : Bool
      params.has_key?("secondary_groups") || params.has_key?("groups")
    end
  end

  Primitive.register(UserSync.new)
end
