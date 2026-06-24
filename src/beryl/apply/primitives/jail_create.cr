require "../primitive"
require "../../jail"

module Beryl::Apply
  # Primitive `jail-create` : crée (idempotent) une thin jail FreeBSD en RAW
  # jail.conf — une appli web = une jail, base partagé en nullfs RO + couche rw.
  # Confine l'appli : depuis l'intérieur, `../` ne sort pas de la jail.
  #
  #     - jail-create:
  #         name: myapp            # = nom de l'appli (et de la jail)
  #         index: 5               # → IP loopback 127.0.1.5 (ou `ip:` explicite)
  #         # base: /jails/.base   # défaut ; doit exister (primitive jail-base)
  #         # root: /jails         # défaut : racine des jails
  #
  # Idempotent : si la jail tourne déjà (`jls -j <name>`), skip. Sinon : crée le
  # skeleton rw, pose /etc/jail.conf.d/<name>.conf + <root>/<name>.fstab (nullfs
  # RO), et démarre la jail.
  #
  # ⚠️ À VALIDER IN VIVO (jails non testables hors FreeBSD) : les générateurs
  # purs (jail.conf, fstab, skeleton) sont testés ; l'exécution réelle non.
  class JailCreate < Primitive
    def name : String
      "jail-create"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      jname = required_string(params, "name")
      unless Beryl::Jail.valid_name?(jname)
        return StepResult.failed("nom de jail invalide : #{jname.inspect} (attendu [a-z][a-z0-9_-]*)")
      end
      root = string(params, "root") || "/jails"
      base = string(params, "base") || "#{root}/.base"
      jail_path = "#{root}/#{jname}"

      ip =
        if explicit = string(params, "ip")
          explicit
        elsif idx = string(params, "index").try(&.to_i?)
          begin
            Beryl::Jail.loopback_ip(idx)
          rescue ex : ArgumentError
            return StepResult.failed(ex.message || "index invalide")
          end
        else
          return StepResult.failed("`jail-create` requiert `ip:` ou `index:` (alloc loopback 127.0.1.<index>)")
        end

      conf = Beryl::Jail.jail_conf(jname, ip, jail_path)
      fstab = Beryl::Jail.thin_fstab(jail_path, base)
      skeleton = Beryl::Jail.skeleton_script(jail_path, base)

      msg = "jail `#{jname}` (#{ip}, base nullfs RO #{base})"
      if dry_run
        return StepResult.applied("#{msg} — DRY-RUN :\n" \
                                  "  /etc/jail.conf.d/#{jname}.conf + #{jail_path}.fstab (#{Beryl::Jail::RO_DIRS.size} montages RO)\n" \
                                  "  skeleton rw + service jail start #{jname}")
      end

      # Idempotence : jail déjà démarrée ?
      if shell.exec("jls -j #{jname}", raise_on_error: false).success?
        return StepResult.skipped("jail #{jname} déjà démarrée")
      end
      # Le base partagé doit exister (sinon les nullfs RO échoueront).
      unless shell.exec("test -d #{base}/bin", raise_on_error: false).success?
        return StepResult.failed("base partagé #{base} absent — appliquez `jail-base` d'abord")
      end

      shell.write_file("/etc/jail.conf.d/#{jname}.conf", conf, "0644")
      shell.write_file("#{jail_path}.fstab", fstab, "0644")

      sk = shell.exec(skeleton, raise_on_error: false)
      return StepResult.failed("skeleton échoué : #{sk.stderr.strip.lines.last?}") unless sk.success?

      st = shell.exec("service jail start #{jname}", raise_on_error: false)
      return StepResult.failed("service jail start #{jname} échoué : #{st.stderr.strip.lines.last?}") unless st.success?

      StepResult.applied("#{msg} créée + démarrée")
    end
  end

  Primitive.register(JailCreate.new)
end
