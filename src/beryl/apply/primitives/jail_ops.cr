require "../primitive"
require "../../jail"

module Beryl::Apply
  # `jail-base` : construit/rafraîchit le BASE PARTAGÉ des thin jails (nullfs RO).
  # Re-run = upgrade du base (pkgbase `pkg --rootdir install -U`) → après reboot
  # des jails, toutes suivent. C'est ça l'intérêt du thin : patcher UNE fois.
  #
  #     - jail-base: {}              # base par défaut /jails/.base
  #     - jail-base: { base: /jails/.base }
  class JailBase < Primitive
    def name : String
      "jail-base"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      base = string(params, "base") || "/jails/.base"
      script = Beryl::Jail.base_install_script(base)
      return StepResult.applied("build/refresh du base partagé #{base} (pkgbase) — dry-run") if dry_run

      shell.exec("mkdir -p #{base}", raise_on_error: false)
      res = shell.exec(script, raise_on_error: false)
      return StepResult.failed("build du base #{base} échoué : #{res.stderr.strip.lines.last?}") unless res.success?
      StepResult.applied("base partagé #{base} construit/à jour")
    end
  end

  # `jail-exec` : exécute une commande DANS une jail (`jexec`). Sert au setup
  # applicatif (pkg install dans la jail, build, migrations…) et au déploiement.
  # Non idempotent (commande libre) — l'idempotence est la responsabilité de la
  # commande passée.
  #
  #     - jail-exec: { jail: myapp, command: "pkg install -y ruby" }
  class JailExec < Primitive
    def name : String
      "jail-exec"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      jail = required_string(params, "jail")
      cmd = required_string(params, "command")
      return StepResult.failed("nom de jail invalide : #{jail.inspect}") unless Beryl::Jail.valid_name?(jail)
      full = "jexec #{jail} /bin/sh -c #{Process.quote(cmd)}"
      return StepResult.applied("jexec #{jail} : #{cmd} — dry-run") if dry_run

      res = shell.exec(full, raise_on_error: false)
      out = (res.stdout + res.stderr).strip
      return StepResult.failed("jexec #{jail} a échoué (#{res.exit_code}) : #{out.lines.last?}") unless res.success?
      StepResult.applied("jexec #{jail} : #{cmd}#{out.empty? ? "" : " → #{out.lines.first?}"}")
    end
  end

  # `jail-proxy` : pose le bloc nginx (host) qui reverse-proxy `server_name` vers
  # la jail (loopback) + recharge nginx. TLS via les recettes nginx/letsencrypt.
  #
  #     - jail-proxy: { name: myapp, ip: 127.0.1.5, port: 3000, server_name: app.example.net }
  class JailProxy < Primitive
    def name : String
      "jail-proxy"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      jname = required_string(params, "name")
      ip = required_string(params, "ip")
      port = (string(params, "port") || "").to_i? || return StepResult.failed("`jail-proxy` requiert `port:` (entier)")
      server_name = string(params, "server_name") || jname
      conf_dir = string(params, "conf_dir") || "/usr/local/etc/nginx/conf.d"
      path = "#{conf_dir}/#{jname}.conf"
      block = Beryl::Jail.nginx_proxy(server_name, ip, port)

      return StepResult.applied("nginx #{path} → #{ip}:#{port} (#{server_name}) — dry-run") if dry_run

      # Idempotence : si la conf est déjà identique, on ne recharge pas nginx.
      current = shell.exec("cat #{path} 2>/dev/null", raise_on_error: false).stdout
      if current == block
        return StepResult.skipped("proxy nginx #{server_name} déjà à jour")
      end

      shell.exec("mkdir -p #{conf_dir}", raise_on_error: false)
      shell.write_file(path, block, "0644")
      check = shell.exec("nginx -t", raise_on_error: false)
      unless check.success?
        return StepResult.failed("nginx -t a échoué : #{check.stderr.strip.lines.last?}")
      end
      shell.exec("service nginx reload", raise_on_error: false)
      StepResult.applied("proxy nginx #{server_name} → #{ip}:#{port} posé + rechargé")
    end
  end

  # `jail-destroy` : arrête et SUPPRIME une jail (conf + montages + skeleton rw).
  # Idempotent : absente → skip. Le `service jail stop` démonte d'abord les
  # nullfs (via la fstab) ; on ne `rm` QUE le skeleton rw sous <root>/<name>.
  #
  #     - jail-destroy: { name: myapp }
  class JailDestroy < Primitive
    def name : String
      "jail-destroy"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      jname = required_string(params, "name")
      return StepResult.failed("nom de jail invalide : #{jname.inspect}") unless Beryl::Jail.valid_name?(jname)
      root = string(params, "root") || "/jails"
      jail_path = "#{root}/#{jname}"
      conf = "/etc/jail.conf.d/#{jname}.conf"
      fstab = "#{jail_path}.fstab"

      running = shell.exec("jls -j #{jname}", raise_on_error: false).success?
      present = running || shell.exec("test -d #{jail_path}", raise_on_error: false).success?
      unless present
        return StepResult.skipped("jail #{jname} absente")
      end
      return StepResult.applied("stop + suppression de la jail #{jname} (#{jail_path}) — dry-run") if dry_run

      shell.exec("service jail stop #{jname}", raise_on_error: false) if running
      # Filet : démonte tout nullfs résiduel SOUS le path avant le rm (jamais de
      # rm sur des montages actifs → ne toucherait pas le base partagé).
      shell.exec("mount -t nullfs | awk '$3 ~ \"^#{jail_path}/\" {print $3}' | sort -r | xargs -r umount -f", raise_on_error: false)
      shell.exec("rm -rf #{jail_path} #{fstab} #{conf}", raise_on_error: false)
      StepResult.applied("jail #{jname} arrêtée et supprimée")
    end
  end

  Primitive.register(JailBase.new)
  Primitive.register(JailExec.new)
  Primitive.register(JailProxy.new)
  Primitive.register(JailDestroy.new)
end
