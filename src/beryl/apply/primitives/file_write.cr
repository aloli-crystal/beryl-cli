require "digest/sha256"
require "../primitive"

module Beryl::Apply
  # Primitive `file-write` : écrit un fichier avec un contenu donné.
  #
  # Idempotence : SHA-256 du contenu distant comparé au contenu cible
  # (skip si identique). `mode` (ex: "0640") et `owner` (ex: "root:wheel"
  # ou "deploy") sont optionnels et vérifiés/corrigés via `stat`.
  #
  #     - file-write:
  #         path: /usr/local/etc/exemple.conf
  #         content: |
  #           ligne 1
  #           ligne 2
  #         mode: "0644"        # optionnel
  #         owner: root:wheel   # optionnel
  #         if_absent: true     # optionnel : crée le fichier S'IL MANQUE,
  #                             # ne le modifie JAMAIS ensuite (page par
  #                             # défaut, exemple de conf à personnaliser…)
  #
  # Note : le contenu (valeur string) est déjà interpolé `{{ var }}`
  # par l'`Executor` ; `file-template` n'est qu'un alias explicite.
  class FileWrite < Primitive
    def name : String
      "file-write"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      path = required_string(params, "path")
      content = required_string(params, "content")
      mode = string(params, "mode")
      owner = string(params, "owner")

      if bool(params, "if_absent") && Primitive.probe?(shell, "test -e #{Process.quote(path)}")
        return StepResult.skipped("#{path} existe déjà — laissé tel quel (if_absent)")
      end

      desired_hash = Digest::SHA256.hexdigest(content)
      # Empreinte, mode et propriétaire en un seul appel. Fichier absent
      # (empreinte vide) : il sera créé, mode et owner sont à poser.
      state = PathState.parse(shell.exec(Posix.file_state(path, context.os), raise_on_error: false).stdout)
      absent = state.head.empty?

      need_write = state.head != desired_hash
      need_chmod = !mode.nil? && (absent || state.mode_differs?(mode))
      need_chown = !owner.nil? && (absent || state.owner_differs?(owner))

      if !need_write && !need_chmod && !need_chown
        return StepResult.skipped("#{path} à jour")
      end

      actions = [] of String
      actions << "contenu" if need_write
      actions << "mode #{mode}" if need_chmod
      actions << "owner #{owner}" if need_chown
      msg = "#{path} : #{actions.join(", ")}"
      if dry_run
        # Contenu simulé, lu par les étapes suivantes du même dry-run.
        context.dry_files[path] = content if need_write
        return StepResult.applied("#{msg} (dry-run)")
      end

      # write_file (re)crée le fichier appartenant à root (écriture via
      # sudo/SFTP) avec un mode par défaut → après TOUTE écriture il faut
      # re-poser mode ET owner, même s'ils « correspondaient » avant (sinon
      # ils repassent à root/0644 à chaque changement de contenu).
      if need_write
        # Garantit le répertoire parent (l'`install`/`cat >` sous-jacent ne le
        # crée pas, et FreeBSD n'a pas le `install -D` de GNU). `mkdir -p` est
        # idempotent ; via `shell.exec` il passe par sudo si besoin.
        dir = File.dirname(path)
        shell.exec("mkdir -p #{Process.quote(dir)}") unless dir == "/" || dir == "."
        shell.write_file(path, content)
      end
      if mode && (need_chmod || need_write)
        shell.exec("chmod #{Process.quote(mode)} #{Process.quote(path)}")
      end
      if owner && (need_chown || need_write)
        shell.exec("chown #{Process.quote(owner)} #{Process.quote(path)}")
      end
      StepResult.applied(msg)
    end
  end

  # Primitive `file-template` : sémantiquement « file-write avec
  # interpolation ». L'interpolation `{{ var }}` étant déjà faite par
  # l'`Executor` sur les valeurs string, le comportement est identique
  # à `file-write`. Conservée comme nom explicite pour la lisibilité
  # des recettes.
  class FileTemplate < FileWrite
    def name : String
      "file-template"
    end
  end

  Primitive.register(FileWrite.new)
  Primitive.register(FileTemplate.new)
end
