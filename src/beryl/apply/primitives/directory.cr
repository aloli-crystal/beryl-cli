require "../primitive"

module Beryl::Apply
  # Primitive `directory` : crée un dossier (`mkdir -p`) avec `owner` et
  # `mode` optionnels, idempotente. Refuse de clobberer un chemin déjà
  # occupé par un NON-dossier.
  #
  #     - directory:
  #         path: /home/platforms
  #         owner: deploy:www   # optionnel (user ou user:group)
  #         mode: "0775"        # optionnel
  class Directory < Primitive
    def name : String
      "directory"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    # Normalise un mode octal pour comparaison avec `stat -f %Lp`
    # (« 0775 » → « 775 »). Pur, exposé pour test.
    def self.norm_mode(mode : String) : String
      mode.to_i(8).to_s(8)
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      path = required_string(params, "path")
      owner = string(params, "owner")
      mode = string(params, "mode")
      q = Process.quote(path)

      # Nature, mode et propriétaire en un seul appel distant.
      state = PathState.parse(Primitive.read_probe(shell, Posix.dir_state(path, context.os)).stdout)
      is_dir = state.head == "dir"
      if state.head == "other"
        raise PrimitiveError.new("#{path} existe mais n'est pas un dossier — refus de clobberer.")
      end

      need_owner = owner && (!is_dir || state.owner_differs?(owner))
      need_mode = mode && (!is_dir || state.mode_differs?(mode))

      if is_dir && !need_owner && !need_mode
        return StepResult.skipped("#{path} déjà conforme")
      end

      actions = [] of String
      actions << "créé" unless is_dir
      actions << "owner #{owner}" if need_owner
      actions << "mode #{mode}" if need_mode
      msg = "#{path} : #{actions.join(", ")}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("mkdir -p #{q}") unless is_dir
      shell.exec("chown #{Process.quote(owner)} #{q}") if need_owner && owner
      shell.exec("chmod #{Process.quote(mode)} #{q}") if need_mode && mode
      StepResult.applied(msg)
    end
  end

  Primitive.register(Directory.new)
end
