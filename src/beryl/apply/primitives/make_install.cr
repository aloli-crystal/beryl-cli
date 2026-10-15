require "../primitive"

module Beryl::Apply
  # Primitive `make-install` : installe un logiciel depuis un tarball de
  # release upstream (`fetch` + `tar` + `make install PREFIX=…`). Pour les
  # outils non packagés sur FreeBSD (ex. chruby, retiré des ports).
  #
  #     - make-install:
  #         url: https://github.com/postmodern/chruby/releases/download/v0.3.9/chruby-0.3.9.tar.gz
  #         creates: /usr/local/share/chruby/chruby.sh   # idempotence
  #         sha256: "abc123…"      # optionnel : vérifie le tarball
  #         prefix: /usr/local     # optionnel (défaut /usr/local)
  #
  # Idempotente via `creates` (skip si le chemin existe). Plus large que
  # `pkg-install` (`make install` exécute le Makefile) MAIS bornée : l'URL
  # est DANS la recette (auditable), pinnée, et vérifiable par `sha256`.
  class MakeInstall < Primitive
    def name : String
      "make-install"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      url = required_string(params, "url")
      creates = string(params, "creates")
      prefix = string(params, "prefix") || "/usr/local"
      sha256 = string(params, "sha256")

      if c = creates
        if Primitive.probe?(shell, "test -e #{Process.quote(c)}")
          return StepResult.skipped("#{c} déjà présent")
        end
      end
      return StepResult.applied("make install depuis #{url} (dry-run)") if dry_run

      lines = [
        "set -e",
        "tmp=$(mktemp -d)",
        "fetch -q -o \"$tmp/src.tgz\" #{Process.quote(url)}",
      ]
      if h = sha256
        lines << "[ \"$(sha256 -q \"$tmp/src.tgz\")\" = #{Process.quote(h)} ] || { echo 'sha256 mismatch' >&2; exit 1; }"
      end
      lines << "tar -xzf \"$tmp/src.tgz\" -C \"$tmp\""
      lines << "cd \"$tmp\"/*/ && make install PREFIX=#{Process.quote(prefix)}"
      lines << "rm -rf \"$tmp\""

      shell.exec(lines.join("\n"))
      StepResult.applied("installé depuis #{url} (make install, PREFIX=#{prefix})")
    end
  end

  Primitive.register(MakeInstall.new)
end
