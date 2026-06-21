require "../primitive"

module Beryl::Apply
  # Primitive `headscale-join` : joint un host au mesh Headscale via
  # `tailscale up --login-server=URL --authkey=KEY`.
  #
  # Idempotence : `tailscale status` exit 0 si déjà joint → skip ;
  # exit non-zéro → on enrôle. La clé d'auth est lue depuis une
  # variable d'environnement (jamais sur la ligne de commande beryl
  # → pas de leak via `ps`). Le secret côté serveur cible est en
  # argv pendant le temps de `tailscale up` (limitation du binaire
  # upstream, < 1 s d'exposition).
  #
  #     - headscale-join:
  #         login_server: https://headscale.example.net
  #         authkey_env_var: HEADSCALE_AUTHKEY  # nom de la var (pas la valeur)
  #         ephemeral: false                     # défaut false ; true pour CI
  #         hostname: "{{ host_short }}"          # optionnel, override
  #         force_reauth: false                  # défaut false ; true pour re-enrôler
  #
  # `authkey_env_var` est résolue côté beryl (pas côté serveur) au
  # moment de l'apply. C'est l'opérateur qui fournit la variable
  # dans son environnement (via le coffre secrets injecté par
  # `EnvFile#apply_to_env`).
  class HeadscaleJoin < Primitive
    def name : String
      "headscale-join"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      login_server = required_string(params, "login_server")
      authkey_env_var = required_string(params, "authkey_env_var")
      ephemeral = bool(params, "ephemeral", default: false)
      force_reauth = bool(params, "force_reauth", default: false)
      hostname = string(params, "hostname")

      # Cas trivial : on est déjà joint et pas de force_reauth.
      if !force_reauth && already_joined?(shell)
        return StepResult.skipped("tailscale déjà joint au mesh")
      end

      # Lire la pre-auth key côté beryl. JAMAIS dans les args YAML
      # ou dans le log : la valeur ne sort pas de la mémoire de la
      # primitive et du process tailscale côté serveur cible.
      authkey = ENV[authkey_env_var]?
      if authkey.nil? || authkey.empty?
        return StepResult.failed(
          "variable d'environnement `#{authkey_env_var}` absente ou vide. " \
          "Posez-la via le coffre secrets de la société puis relancez."
        )
      end

      args = ["tailscale", "up", "--login-server=#{login_server}", "--authkey=#{authkey}"]
      args << "--reset" if force_reauth
      args << "--hostname=#{hostname}" if hostname && !hostname.empty?
      args << "--ephemeral" if ephemeral

      msg = if force_reauth
              "tailscale up --reset (re-enrôlement forcé)"
            elsif ephemeral
              "tailscale up --ephemeral"
            else
              "tailscale up"
            end
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      # La commande shell-out : authkey EST en argv durant l'exécution.
      # On ne logge JAMAIS la commande complète — seulement le verbe.
      result = shell.exec(args.map { |a| Process.quote(a) }.join(" "), raise_on_error: false)
      if result.success?
        StepResult.applied(msg)
      else
        # Ne pas inclure stderr brut s'il contient la clé. La pre-auth
        # key n'apparaît jamais dans stderr de tailscale (vérifié sur
        # les versions ≥ 1.50), mais par défense en profondeur, on
        # masque toute occurrence de la clé.
        sanitized = result.stderr.gsub(authkey, "[REDACTED]")
        StepResult.failed("tailscale up échoue : #{sanitized.strip}")
      end
    end

    # `tailscale status` retourne 0 si une session est active.
    # Exit non-zéro = pas joint (ou tailscaled down).
    private def already_joined?(shell : Shell) : Bool
      shell.exec("tailscale status --json >/dev/null 2>&1", raise_on_error: false).success?
    end
  end

  Primitive.register(HeadscaleJoin.new)
end
