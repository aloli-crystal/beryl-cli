require "../primitive"

module Beryl::Apply
  # Base commune à `service-enable` / `service-disable` : lecture de
  # l'état réel d'un service rc.d FreeBSD (`sysrc -n <svc>_enable` +
  # `service <svc> onestatus`).
  abstract class ServicePrimitive < Primitive
    # `sysrc -n <svc>_enable` vaut-il YES ? (exit 1 si la variable
    # n'est pas posée → considéré non activé).
    protected def enabled?(shell : Shell, svc : String, enable_var : String? = nil) : Bool
      var = enable_var || "#{svc}_enable"
      out = shell.exec("sysrc -n #{Process.quote(var)} 2>/dev/null", raise_on_error: false).stdout
      out.strip.upcase == "YES"
    end

    # Le script rc du service existe-t-il ? (base ou ports). Sert au
    # garde-fou `if_present` : un service non installé n'est pas une erreur.
    protected def rc_present?(shell : Shell, svc : String) : Bool
      shell.exec(
        "test -f #{Process.quote("/usr/local/etc/rc.d/#{svc}")} -o -f #{Process.quote("/etc/rc.d/#{svc}")}",
        raise_on_error: false,
      ).success?
    end

    # `service <svc> onestatus` retourne 0 si le service tourne.
    protected def running?(shell : Shell, svc : String) : Bool
      shell.exec("service #{Process.quote(svc)} onestatus", raise_on_error: false).success?
    end
  end

  # Primitive `service-enable` : `sysrc <svc>_enable=YES` puis démarre
  # le service s'il ne tourne pas déjà (sauf `start: false`).
  #
  #     - service-enable:
  #         name: nginx
  #         start: true        # défaut
  class ServiceEnable < ServicePrimitive
    def name : String
      "service-enable"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      start = bool(params, "start", default: true)
      # Variable rc à poser (défaut `<svc>_enable`). Override utile quand le
      # script rc et la variable diffèrent (ex. mariadb : script mysql-server,
      # variable mysql_enable).
      enable_var = string(params, "enable_var") || "#{svc}_enable"

      # Garde-fou : si le service n'a pas de script rc (paquet non installé,
      # ex. `only: client`), on ne fait RIEN — ce n'est pas une erreur.
      if bool(params, "if_present", default: false) && !rc_present?(shell, svc)
        return StepResult.skipped("#{svc} : service absent (paquet non installé) — ignoré")
      end

      already_enabled = enabled?(shell, svc, enable_var)
      is_running = running?(shell, svc)
      need_enable = !already_enabled
      need_start = start && !is_running

      if !need_enable && !need_start
        return StepResult.skipped("#{svc} déjà activé#{start ? " et démarré" : ""}")
      end

      actions = [] of String
      actions << "enable" if need_enable
      actions << "start" if need_start
      msg = "#{svc} : #{actions.join(" + ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("sysrc #{Process.quote("#{enable_var}=YES")}") if need_enable
      shell.exec(Primitive.service_command(svc, "start")) if need_start
      StepResult.applied(msg)
    end
  end

  # Primitive `service-disable` : `sysrc <svc>_enable=NO` puis arrête le
  # service s'il tourne (sauf `stop: false`).
  #
  #     - service-disable:
  #         name: sendmail
  #         stop: true         # défaut
  class ServiceDisable < ServicePrimitive
    def name : String
      "service-disable"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      stop = bool(params, "stop", default: true)

      is_enabled = enabled?(shell, svc)
      is_running = running?(shell, svc)
      need_disable = is_enabled
      need_stop = stop && is_running

      if !need_disable && !need_stop
        return StepResult.skipped("#{svc} déjà désactivé#{stop ? " et arrêté" : ""}")
      end

      actions = [] of String
      actions << "disable" if need_disable
      actions << "stop" if need_stop
      msg = "#{svc} : #{actions.join(" + ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("sysrc #{Process.quote("#{svc}_enable=NO")}") if need_disable
      shell.exec("service #{Process.quote(svc)} stop") if need_stop
      StepResult.applied(msg)
    end
  end

  # Primitive `service-reload` : `service <svc> reload` — recharge la conf
  # d'un service SANS couper les sessions en cours (≠ restart). Usage type :
  # après une recette qui modifie sshd_config / nginx.conf. Skip si le
  # service n'est pas démarré (rien à recharger).
  #
  #     - service-reload:
  #         name: sshd
  class ServiceReload < ServicePrimitive
    def name : String
      "service-reload"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      unless running?(shell, svc)
        return StepResult.skipped("#{svc} non démarré → rien à recharger")
      end
      return StepResult.applied("#{svc} : reload (dry-run)") if dry_run
      shell.exec("service #{Process.quote(svc)} reload")
      StepResult.applied("#{svc} : reload")
    end
  end

  # Primitive `service-restart` : `service <svc> restart`, pour un service qui
  # ne relit sa configuration qu'au démarrage (ex. un fichier d'environnement
  # lu par son script rc.d). Skip si le service n'est pas démarré : le premier
  # démarrage reste l'affaire de `service-enable`. À combiner avec
  # `if_changed: true`, juste après l'étape qui écrit la configuration.
  #
  #     - secret-file: { path: /usr/local/etc/app/app.env, … }
  #     - service-restart: { name: app, if_changed: true }
  class ServiceRestart < ServicePrimitive
    def name : String
      "service-restart"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      unless running?(shell, svc)
        return StepResult.skipped("#{svc} non démarré → rien à redémarrer")
      end
      return StepResult.applied("#{svc} : restart (dry-run)") if dry_run
      shell.exec(Primitive.service_command(svc, "restart"))
      StepResult.applied("#{svc} : restart")
    end
  end

  Primitive.register(ServiceEnable.new)
  Primitive.register(ServiceDisable.new)
  Primitive.register(ServiceReload.new)
  Primitive.register(ServiceRestart.new)
end
