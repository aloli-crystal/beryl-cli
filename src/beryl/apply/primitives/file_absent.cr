require "../primitive"

module Beryl::Apply
  # Primitive `file-absent` : garantit qu'un FICHIER n'existe pas (suppression
  # s'il est là). Idempotente. Sert surtout aux migrations de recettes : retirer
  # un fichier qu'une version précédente posait ailleurs.
  #
  #     - file-absent:
  #         path: /usr/local/etc/monit.d/ancien.conf
  #
  # Refuse un dossier ou un chemin vide : seulement des fichiers (ou liens).
  class FileAbsent < Primitive
    def name : String
      "file-absent"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      path = required_string(params, "path").strip
      raise PrimitiveError.new("`file-absent` : chemin vide") if path.empty? || path == "/"
      q = Process.quote(path)
      exists = Primitive.probe?(shell, "test -e #{q} -o -L #{q}")
      return StepResult.skipped("#{path} déjà absent") unless exists
      if Primitive.probe?(shell, "test -d #{q}")
        raise PrimitiveError.new("`file-absent` : #{path} est un dossier — refus de le supprimer")
      end
      return StepResult.applied("#{path} : supprimé (dry-run)") if dry_run
      shell.exec("rm -f #{q}")
      StepResult.applied("#{path} : supprimé")
    end
  end

  Primitive.register(FileAbsent.new)
end
