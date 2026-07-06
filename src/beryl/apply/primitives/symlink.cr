require "../primitive"

module Beryl::Apply
  # Primitive `symlink` : crée/met à jour un lien symbolique `path` →
  # `target`, idempotente. Refuse de remplacer un vrai fichier/dossier
  # (ne clobbere qu'un lien existant). `owner` optionnel (chown -h).
  #
  #     - symlink:
  #         path: /home/v2ror_production/shared/platforms
  #         target: /home/platforms
  #         owner: deploy:www   # optionnel
  class Symlink < Primitive
    def name : String
      "symlink"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      path = required_string(params, "path")
      target = required_string(params, "target")
      owner = string(params, "owner")
      qp = Process.quote(path)
      qt = Process.quote(target)

      is_link = shell.exec("test -L #{qp}", raise_on_error: false).success?
      if !is_link && shell.exec("test -e #{qp}", raise_on_error: false).success?
        raise PrimitiveError.new("#{path} existe et n'est pas un lien symbolique — refus de clobberer.")
      end

      current = is_link ? shell.exec("readlink #{qp}", raise_on_error: false).stdout.strip : nil
      if current == target
        return StepResult.skipped("#{path} → #{target} déjà en place")
      end

      msg = "#{path} → #{target}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      # Le parent doit exister ; `-h`+`-f` remplacent un lien existant sans
      # suivre (jamais un dossier — on a refusé les non-liens plus haut).
      shell.exec("mkdir -p #{Process.quote(File.dirname(path))}")
      shell.exec("ln -sfh #{qt} #{qp}")
      shell.exec("chown -h #{Process.quote(owner)} #{qp}") if owner
      StepResult.applied(msg)
    end
  end

  Primitive.register(Symlink.new)
end
