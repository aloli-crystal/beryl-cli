require "../primitive"

module Beryl::Apply
  # Base commune à `service-enable` / `service-disable` : lecture de
  # l'état réel d'un service rc.d FreeBSD (`sysrc -n <svc>_enable` +
  # `service <svc> onestatus`), ou d'une unité systemd sous Linux
  # (`systemctl is-enabled` / `is-active`).
  abstract class ServicePrimitive < Primitive
    # Portable : rc.d sur FreeBSD, systemd sur Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    # FreeBSD : `sysrc -n <svc>_enable` vaut-il YES ? (exit 1 si la variable
    # n'est pas posée → considéré non activé). Linux : unité `enabled`.
    protected def enabled?(shell : Shell, svc : String, os : String, enable_var : String? = nil) : Bool
      if os == LINUX
        state = shell.exec("systemctl is-enabled #{Process.quote(svc)} 2>/dev/null", raise_on_error: false).stdout
        return state.strip == "enabled"
      end
      var = enable_var || "#{svc}_enable"
      out = shell.exec("sysrc -n #{Process.quote(var)} 2>/dev/null", raise_on_error: false).stdout
      out.strip.upcase == "YES"
    end

    # Le service existe-t-il ? (script rc de la base ou des ports, unité
    # systemd). Sert au garde-fou `if_present` : un service non installé
    # n'est pas une erreur.
    protected def rc_present?(shell : Shell, svc : String, os : String) : Bool
      if os == LINUX
        return Primitive.probe?(shell, "systemctl cat #{Process.quote(svc)} >/dev/null 2>&1")
      end
      Primitive.probe?(
        shell,
        "test -f #{Process.quote("/usr/local/etc/rc.d/#{svc}")} -o -f #{Process.quote("/etc/rc.d/#{svc}")}",
      )
    end

    # Le service tourne-t-il ? (`service <svc> onestatus`, `systemctl is-active`).
    protected def running?(shell : Shell, svc : String, os : String) : Bool
      if os == LINUX
        Primitive.probe?(shell, "systemctl is-active --quiet #{Process.quote(svc)}")
      else
        Primitive.probe?(shell, "service #{Process.quote(svc)} onestatus")
      end
    end

    # Commande d'une action (start, stop, reload, restart).
    protected def action_command(svc : String, action : String, os : String) : String
      os == LINUX ? "systemctl #{action} #{Process.quote(svc)}" : Primitive.service_command(svc, action)
    end
  end

  # Primitive `service-enable` : `sysrc <svc>_enable=YES` (FreeBSD) ou
  # `systemctl enable` (Linux), puis démarre le service s'il ne tourne pas
  # déjà (sauf `start: false`).
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
      os = context.os
      # Variable rc à poser (défaut `<svc>_enable`, FreeBSD seulement).
      # Override utile quand le script rc et la variable diffèrent (ex.
      # mariadb : script mysql-server, variable mysql_enable).
      enable_var = string(params, "enable_var") || "#{svc}_enable"

      # Garde-fou : si le service n'existe pas (paquet non installé, ex.
      # `only: client`), on ne fait RIEN — ce n'est pas une erreur.
      if bool(params, "if_present", default: false) && !rc_present?(shell, svc, os)
        return StepResult.skipped("#{svc} : service absent (paquet non installé) — ignoré")
      end

      already_enabled = enabled?(shell, svc, os, enable_var)
      is_running = running?(shell, svc, os)
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

      if need_enable
        if os == LINUX
          shell.exec("systemctl enable #{Process.quote(svc)}")
        else
          shell.exec("sysrc #{Process.quote("#{enable_var}=YES")}")
        end
      end
      shell.exec(action_command(svc, "start", os)) if need_start
      StepResult.applied(msg)
    end
  end

  # Primitive `service-disable` : `sysrc <svc>_enable=NO` (FreeBSD) ou
  # `systemctl disable` (Linux), puis arrête le service s'il tourne (sauf
  # `stop: false`).
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
      os = context.os

      is_enabled = enabled?(shell, svc, os)
      is_running = running?(shell, svc, os)
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

      if need_disable
        if os == LINUX
          shell.exec("systemctl disable #{Process.quote(svc)}")
        else
          shell.exec("sysrc #{Process.quote("#{svc}_enable=NO")}")
        end
      end
      if need_stop
        shell.exec(os == LINUX ? "systemctl stop #{Process.quote(svc)}" : "service #{Process.quote(svc)} stop")
      end
      StepResult.applied(msg)
    end
  end

  # Primitive `service-reload` : `service <svc> reload` (ou `systemctl
  # reload`) — recharge la conf d'un service SANS couper les sessions en
  # cours (≠ restart). Usage type : après une recette qui modifie
  # sshd_config / nginx.conf. Skip si le service n'est pas démarré (rien à
  # recharger).
  #
  #     - service-reload:
  #         name: sshd
  class ServiceReload < ServicePrimitive
    def name : String
      "service-reload"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      unless running?(shell, svc, context.os)
        return StepResult.skipped("#{svc} non démarré → rien à recharger")
      end
      return StepResult.applied("#{svc} : reload (dry-run)") if dry_run
      shell.exec(context.os == LINUX ? "systemctl reload #{Process.quote(svc)}" : "service #{Process.quote(svc)} reload")
      StepResult.applied("#{svc} : reload")
    end
  end

  # Primitive `service-restart` : `service <svc> restart` (ou `systemctl
  # restart`), pour un service qui ne relit sa configuration qu'au
  # démarrage (ex. un fichier d'environnement lu par son script rc.d). Skip
  # si le service n'est pas démarré : le premier démarrage reste l'affaire de
  # `service-enable`. À combiner avec `if_changed: true`, juste après
  # l'étape qui écrit la configuration.
  #
  #     - secret-file: { path: /usr/local/etc/app/app.env, … }
  #     - service-restart: { name: app, if_changed: true }
  class ServiceRestart < ServicePrimitive
    def name : String
      "service-restart"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      svc = required_string(params, "name")
      unless running?(shell, svc, context.os)
        return StepResult.skipped("#{svc} non démarré → rien à redémarrer")
      end
      return StepResult.applied("#{svc} : restart (dry-run)") if dry_run
      shell.exec(action_command(svc, "restart", context.os))
      StepResult.applied("#{svc} : restart")
    end
  end

  Primitive.register(ServiceEnable.new)
  Primitive.register(ServiceDisable.new)
  Primitive.register(ServiceReload.new)
  Primitive.register(ServiceRestart.new)
end
