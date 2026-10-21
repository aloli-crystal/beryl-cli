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
      remote_hash = shell.exec(Posix.sha256(path, context.os), raise_on_error: false).stdout.strip

      need_write = remote_hash != desired_hash
      need_chmod = mode_differs?(shell, path, mode, remote_hash.empty?, context.os)
      need_chown = owner_differs?(shell, path, owner, remote_hash.empty?, context.os)

      if !need_write && !need_chmod && !need_chown
        return StepResult.skipped("#{path} à jour")
      end

      actions = [] of String
      actions << "contenu" if need_write
      actions << "mode #{mode}" if need_chmod
      actions << "owner #{owner}" if need_chown
      msg = "#{path} : #{actions.join(", ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

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

    # Vrai si `mode` est demandé et diffère du mode distant (comparaison
    # en octal). Si le fichier est absent, il sera créé → on chmod.
    private def mode_differs?(shell : Shell, path : String, mode : String?, file_absent : Bool, os : String) : Bool
      return false unless mode
      return true if file_absent
      remote = shell.exec("#{Posix.mode(path, os)} 2>/dev/null", raise_on_error: false).stdout.strip
      mode.to_i?(8) != remote.to_i?(8)
    end

    # Vrai si `owner` est demandé et diffère du propriétaire distant.
    # `owner` peut être "user" ou "user:group".
    private def owner_differs?(shell : Shell, path : String, owner : String?, file_absent : Bool, os : String) : Bool
      return false unless owner
      return true if file_absent
      remote = shell.exec("#{Posix.owner(path, os, owner.includes?(':'))} 2>/dev/null", raise_on_error: false).stdout.strip
      remote != owner
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
