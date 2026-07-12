require "../primitive"
require "../../freebsd_release"

module Beryl::Apply
  # Primitive `poudriere-build` : maintient un dépôt pkg poudriere à la
  # dernière MINEURE d'un majeur FreeBSD figé, et publie l'alias par ABI
  # (`FreeBSD:<major>:<arch>` → set courant) pour un client agnostique à la
  # version (`url: https://…/${ABI}`).
  #
  # Idempotent & réconciliateur : à chaque apply, compare la dernière
  # release de la branche (`FreebsdRelease.latest_by_branch`) à ce que vise
  # l'alias. Égal → skip. Plus récent → build en DÉTACHÉ (daemon -f + log +
  # lock anti-double-build), qui crée la jail au besoin, `poudriere bulk` la
  # build-list (overlay), puis repointe l'alias.
  #
  # `major` FIGÉ (ex. "15") : suit 15.0 → 15.1 → 15.2 (même ABI, sûr) mais
  # JAMAIS un saut de majeur (16.0 = nouvelle ABI). Pour ouvrir 16 : une 2ᵉ
  # instance `major: 16` → l'alias `FreeBSD:16:amd64` cohabite ; un client
  # bascule quand SA base passe en 16.
  #
  #     - poudriere-build:
  #         major: "15"
  #         pkglist: /usr/local/etc/poudriere.d/quimeo-pkglist
  #         overlay: quimeo               # optionnel (défaut quimeo)
  #         reapply: /usr/local/poudriere/quimeo-ports/reapply-base-patches.sh  # optionnel
  class PoudriereBuild < Primitive
    DEFAULT_PKGDIR = "/usr/local/poudriere/data/packages"

    def name : String
      "poudriere-build"
    end

    # "15.1" + amd64 → "fbsd151amd64". Pur, exposé pour test.
    def self.jail_name(version : String, arch : String) : String
      "fbsd#{version.delete('.')}#{arch}"
    end

    # Alias par ABI : "FreeBSD:15:amd64". Pur.
    def self.alias_name(major : String, arch : String) : String
      "FreeBSD:#{major}:#{arch}"
    end

    # Nom du set poudriere : "fbsd151amd64-default". Pur.
    def self.set_name(version : String, arch : String, ports : String) : String
      "#{jail_name(version, arch)}-#{ports}"
    end

    # Reconstruit la version depuis un nom de set ("fbsd151amd64-default" +
    # major "15" → "15.1"). nil si le nom ne correspond pas. Pur.
    def self.set_version(setname : String, major : String, arch : String, ports : String) : String?
      suffix = "#{arch}-#{ports}"
      return nil unless setname.starts_with?("fbsd") && setname.ends_with?(suffix)
      digits = setname[4...(setname.size - suffix.size)]
      return nil unless digits.starts_with?(major)
      minor = digits[major.size..]
      minor.empty? ? nil : "#{major}.#{minor}"
    end

    # Script de build (lancé en détaché sur le builder). Pur, exposé pour test.
    def self.build_script(version : String, arch : String, ports : String,
                          overlay : String, pkglist : String, pkgdir : String,
                          reapply : String?) : String
      major = version.split('.').first
      jail = jail_name(version, arch)
      set = set_name(version, arch, ports)
      ali = "#{pkgdir}/#{alias_name(major, arch)}"
      # reapply : ré-applique les patches quimeo sur l'arbre base APRÈS le pull
      # (ex. retirer du MOVED les ports expirés que l'overlay ré-introduit). On
      # lui passe le chemin de l'arbre ($PTDIR) et on PRÉVIENT dans le log s'il
      # est configuré mais absent/non exécutable (au lieu d'un skip silencieux).
      reapply_line =
        if reapply
          r = Process.quote(reapply)
          "if [ -x #{r} ]; then #{r} \"$PTDIR\"; else echo \"beryl: reapply absent ou non exécutable, patches base NON appliqués : #{reapply}\"; fi"
        else
          "true"
        end
      <<-SH
      #!/bin/sh
      set -eu
      if ! poudriere jail -l -q 2>/dev/null | awk '{print $1}' | grep -qx #{Process.quote(jail)}; then
        poudriere jail -c -j #{Process.quote(jail)} -v #{Process.quote("#{version}-RELEASE")} -a #{Process.quote(arch)}
      fi
      # Arbre de ports PROPRE avant le git pull : un `reapply` précédent laisse
      # des modifs non commitées → `poudriere ports -u` (git pull --rebase)
      # échoue (« You have unstaged changes »). On remet l'arbre à l'état git
      # (les patches seront ré-appliqués juste après par le reapply).
      PTDIR=$(poudriere ports -lq 2>/dev/null | awk -v p=#{Process.quote(ports)} '$1==p{print $NF}')
      [ -d "$PTDIR/.git" ] || PTDIR=/usr/local/poudriere/ports/#{Process.quote(ports)}
      if [ -d "$PTDIR/.git" ]; then
        git -C "$PTDIR" reset -q --hard 2>/dev/null || true
        git -C "$PTDIR" clean -qfd 2>/dev/null || true
      fi
      poudriere ports -u -p #{Process.quote(ports)}
      #{reapply_line}
      poudriere bulk -j #{Process.quote(jail)} -p #{Process.quote(ports)} -O #{Process.quote(overlay)} -f #{Process.quote(pkglist)}
      ln -sfh #{Process.quote(set)} #{Process.quote(ali)}
      echo "poudriere-build #{version} OK ($(date -u +%FT%TZ))"
      SH
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      major = required_string(params, "major")
      arch = string(params, "arch") || "amd64"
      ports = string(params, "ports") || "default"
      overlay = string(params, "overlay") || "quimeo"
      pkglist = required_string(params, "pkglist")
      pkgdir = string(params, "pkgdir") || DEFAULT_PKGDIR
      reapply = string(params, "reapply")

      target = begin
        Beryl::FreebsdRelease.latest_by_branch[major.to_i]?
      rescue
        nil
      end
      return StepResult.skipped("détection FreeBSD indisponible — pas de build (majeur #{major})") if target.nil?

      alias_path = "#{pkgdir}/#{self.class.alias_name(major, arch)}"
      cur_set = shell.exec("readlink #{Process.quote(alias_path)} 2>/dev/null", raise_on_error: false).stdout.strip
      current = cur_set.empty? ? nil : self.class.set_version(cur_set, major, arch, ports)

      if current && Beryl::FreebsdRelease.version_key(current) >= Beryl::FreebsdRelease.version_key(target)
        return StepResult.skipped("dépôt majeur #{major} déjà à jour sur #{current}")
      end

      lock = "#{pkgdir}/.beryl-build-#{major}.lock"
      if shell.exec("test -f #{Process.quote(lock)}", raise_on_error: false).success?
        return StepResult.skipped("build majeur #{major} déjà en cours (lock présent)")
      end

      msg = "build FreeBSD #{target}#{current ? " (← #{current})" : " (initial)"} [majeur #{major}]"
      return StepResult.applied("#{msg} — serait lancé (dry-run)") if dry_run

      script_path = "/tmp/beryl-poudriere-build-#{major}.sh"
      shell.write_file(script_path, self.class.build_script(target, arch, ports, overlay, pkglist, pkgdir, reapply), "0755")
      # Lock AVANT lancement (les applies concurrents skippent). Le script
      # détaché retire le lock à la fin (succès ou échec).
      shell.exec("touch #{Process.quote(lock)}")
      log = "#{pkgdir}/.beryl-build-#{major}.log"
      # Détachement via `daemon -f` (FreeBSD n'a PAS `setsid`) : fork + nouvelle
      # session, survit à la fermeture SSH ; `daemon` rend la main aussitôt. Le
      # script redirige lui-même sa sortie vers `log` et retire le `lock` à la fin.
      shell.exec(
        "daemon -f sh -c 'sh #{Process.quote(script_path)} > #{Process.quote(log)} 2>&1; rm -f #{Process.quote(lock)}'; echo lancé",
      )
      StepResult.applied("#{msg} lancé en détaché — suivi : tail -f #{log}")
    end
  end

  Primitive.register(PoudriereBuild.new)
end
