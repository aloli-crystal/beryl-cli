require "../primitive"

module Beryl::Apply
  # Primitive `pkg-install` : garantit que les packages listés sont
  # installés via `pkg install -y` (FreeBSD : `-r <dépôt>` choisi par pkg,
  # cf. `Primitive.pkg_install`).
  #
  # Idempotence : lecture de l'état réel (`pkg info`) avant action,
  # seul le delta manquant est installé. Si tout est déjà présent →
  # `skipped`. En `dry_run`, le delta est calculé mais rien n'est
  # installé.
  #
  # Step YAML :
  #
  #     - pkg-install:
  #         packages: [bash, git, curl]
  class PkgInstall < Primitive
    def name : String
      "pkg-install"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      packages = string_array(params, "packages")
      return StepResult.skipped("aucun package déclaré") if packages.empty?

      installed = installed_packages(shell, context.os)
      missing = packages.reject { |p| installed.includes?(p) }

      if missing.empty?
        return StepResult.skipped("#{packages.size} package(s) déjà installé(s)")
      end

      msg = "+#{missing.size} package(s) : #{missing.join(", ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      list = missing.map { |p| Process.quote(p) }.join(" ")
      if context.os == LINUX
        # Linux : SUSE seulement (zypper) — la seule distribution gérée.
        unless Primitive.probe?(shell, "command -v zypper >/dev/null 2>&1")
          raise PrimitiveError.new("pkg-install : zypper introuvable (seule SUSE est prise en charge sous Linux)")
        end
        shell.exec("zypper --non-interactive install --no-recommends #{list}")
      else
        Primitive.pkg_install(shell, missing)
      end
      StepResult.applied(msg)
    end

    # Ensemble des noms de packages installés (sans la version). On lit
    # tout en une seule commande pour limiter les allers-retours SSH —
    # `pkg info -q` liste `<nom>-<version>`, on retire le suffixe de
    # version pour comparer par nom. Linux : `rpm -qa` donne les noms seuls.
    private def installed_packages(shell : Shell, os : String) : Set(String)
      command =
        if os == LINUX
          "rpm -qa --qf '%{NAME}\\n' 2>/dev/null | sort -u"
        else
          "pkg info -q 2>/dev/null | sed 's/-[0-9].*$//' | sort -u"
        end
      out = shell.exec(command, raise_on_error: false).stdout
      out.lines.map(&.strip).reject(&.empty?).to_set
    end
  end

  Primitive.register(PkgInstall.new)
end
