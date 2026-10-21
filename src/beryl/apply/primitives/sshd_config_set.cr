require "../primitive"

module Beryl::Apply
  # Primitive `sshd-config-set` : pose une directive dans
  # `/etc/ssh/sshd_config.d/beryl.conf` (fichier géré par beryl). Comme
  # FreeBSD ne met PAS d'`Include sshd_config.d/*.conf` par défaut, la
  # primitive l'ajoute EN TÊTE du `sshd_config` si absent — sinon le
  # drop-in serait écrit mais jamais lu. En tête car sshd retient la
  # PREMIÈRE valeur d'une directive → les drop-ins priment.
  #
  # Idempotence : la directive est déjà présente avec la bonne valeur →
  # skip. Sinon le fichier est réécrit, validé (`sshd -t`) et sshd est
  # rechargé (`service sshd reload`).
  #
  # Valeur RÉELLE : un drop-in lu AVANT `beryl.conf` (ordre alphabétique,
  # ex. `10-beryl-bootstrap.conf` du bootstrap) qui fixe la même directive
  # l'emporte. S'il est à beryl (nom contenant « beryl »), la directive y est
  # retirée ; sinon, échec qui nomme le fichier. Sans masque, la valeur
  # effective (`sshd -T`) doit commencer par la valeur voulue (tolère
  # `ListenAddress 1.2.3.4` → `1.2.3.4:22`) — sinon échec : autre source
  # (sshd_config, bloc Match).
  #
  #     - sshd-config-set:
  #         key: PermitRootLogin
  #         value: "no"
  #
  # Cas où la valeur dépend d'un état runtime (ex. IP de l'interface
  # tailscale0 inconnue à l'écriture de la recette) : utiliser
  # `value_from_command` à la place. La commande est exécutée côté
  # serveur cible, son stdout strippé devient la valeur. Échec
  # (exit ≠ 0 ou stdout vide) → la primitive `fail`.
  #
  #     - sshd-config-set:
  #         key: ListenAddress
  #         value_from_command: "tailscale ip -4"
  class SshdConfigSet < Primitive
    PATH = "/etc/ssh/sshd_config.d/beryl.conf"
    # Linux : « 00- » pour passer AVANT les drop-ins du système (SUSE :
    # 40-suse-crypto-policies.conf, 50-cloud-init.conf), lus dans l'ordre
    # alphabétique — sshd retient la première valeur.
    LINUX_PATH = "/etc/ssh/sshd_config.d/00-beryl.conf"

    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def self.path(os : String) : String
      os == LINUX ? LINUX_PATH : PATH
    end

    HEADER = "# Géré par beryl (sshd-config-set). Ne pas éditer à la main.\n"

    def name : String
      "sshd-config-set"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      key = required_string(params, "key")

      static_value = string(params, "value")
      cmd_value = string(params, "value_from_command")

      if static_value.nil? && cmd_value.nil?
        return StepResult.failed("ni `value` ni `value_from_command` fournis")
      end
      if static_value && cmd_value
        return StepResult.failed("`value` et `value_from_command` sont mutuellement exclusifs")
      end

      value = if cmd = cmd_value
                probe = shell.exec(cmd, raise_on_error: false)
                resolved = probe.stdout.strip
                if !probe.success? || resolved.empty?
                  return StepResult.failed("`value_from_command` (#{cmd}) retourne vide ou échoue : #{probe.stderr.strip}")
                end
                resolved
              else
                static_value.not_nil!
              end

      # Garantit l'Include AVANT toute autre logique : sans lui, un
      # `beryl.conf` déjà "à jour" resterait pourtant inerte.
      path = self.class.path(context.os)
      include_added = ensure_include(shell, dry_run)

      current = shell.exec("cat #{Process.quote(path)} 2>/dev/null", raise_on_error: false)
      original = current.success? ? current.stdout : nil
      directives = parse(current.stdout)
      changed = directives[key]? != value

      shadows = shadowing_files(shell, key, path)
      foreign = shadows.reject { |file| File.basename(file).includes?("beryl") }
      unless foreign.empty?
        return StepResult.failed("#{key} est fixée par #{foreign.join(", ")}, lu(s) avant #{File.basename(path)} : " \
                                 "retirez-la de ce(s) fichier(s) ou alignez la valeur sur #{value}")
      end

      if !changed && !include_added && shadows.empty?
        if (effective = effective_values(shell, key)) && effective.none?(&.starts_with?(value.downcase))
          return StepResult.failed("#{key} : valeur effective (sshd -T) #{effective.join(", ")} ≠ #{value} — " \
                                   "imposée hors de sshd_config.d (sshd_config, bloc Match ?)")
        end
        return StepResult.skipped("#{key} déjà = #{value}")
      end

      previous = directives[key]?
      directives[key] = value

      parts = [] of String
      parts << "Include sshd_config.d/*.conf activé" if include_added
      parts << (changed ? "#{key} : #{previous.nil? ? "(absent)" : previous} → #{value}" : "#{key} déjà = #{value}")
      shadows.each { |file| parts << "#{key} retirée de #{file} (masquait #{File.basename(path)})" }
      msg = parts.join(" ; ")
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shadows.each { |file| shell.exec(remove_directive_command(file, key)) }
      shell.exec("mkdir -p #{Process.quote(File.dirname(path))}")
      shell.write_file(path, render(directives), mode: "0644")
      # Valide la conf AVANT de recharger. Refusée : on remet l'ancien
      # fichier (ou on retire le nouveau) — sinon le prochain démarrage de
      # sshd échouerait et fermerait la porte du serveur.
      check = shell.exec("sshd -t", raise_on_error: false)
      unless check.success?
        if prev = original
          shell.write_file(path, prev, mode: "0644")
        else
          shell.exec("rm -f #{Process.quote(path)}")
        end
        detail = check.stderr.strip.lines.last(3).join(" | ")
        return StepResult.failed("#{key} = #{value} refusée par sshd -t (#{detail}) — #{File.basename(path)} remis en l'état")
      end
      shell.exec(context.os == LINUX ? "systemctl reload sshd" : "service sshd reload")
      StepResult.applied(msg)
    end

    # Motif (grep -iE) d'une ligne qui fixe `key` (`Clé valeur` ou `Clé=valeur`).
    private def directive_pattern(key : String) : String
      "^[[:space:]]*#{Regex.escape(key)}([[:space:]]|=)"
    end

    # Drop-ins lus AVANT beryl.conf (ordre du glob, celui de sshd) qui fixent
    # `key` : ils l'emportent (sshd retient la première valeur).
    private def shadowing_files(shell : Shell, key : String, path : String) : Array(String)
      script = "for f in #{File.dirname(path)}/*.conf; do [ \"$f\" = #{Process.quote(path)} ] && break; " \
               "[ -f \"$f\" ] && grep -qiE #{Process.quote(directive_pattern(key))} \"$f\" && echo \"$f\"; done; true"
      shell.exec(script, raise_on_error: false).stdout.lines.map(&.strip).reject(&.empty?)
    end

    # Retire de `file` les lignes qui fixent `key` (le reste du fichier gardé).
    private def remove_directive_command(file : String, key : String) : String
      q = Process.quote(file)
      %(tmp=$(mktemp) && { grep -viE #{Process.quote(directive_pattern(key))} #{q} || true; } > "$tmp" && cat "$tmp" > #{q} && rm -f "$tmp")
    end

    # Valeurs effectives de `key` d'après `sshd -T` (nil si sshd -T échoue ou
    # ne la cite pas : rien à conclure).
    private def effective_values(shell : Shell, key : String) : Array(String)?
      res = shell.exec("sshd -T 2>/dev/null", raise_on_error: false)
      return unless res.success?
      values = res.stdout.lines.compact_map do |line|
        name, _, rest = line.strip.partition(' ')
        rest.downcase if name.downcase == key.downcase
      end
      values.empty? ? nil : values
    end

    # S'assure que `/etc/ssh/sshd_config` inclut le dossier des drop-ins,
    # en TÊTE de fichier (premier-match → drop-ins prioritaires). Retourne
    # true s'il a fallu l'ajouter. En dry-run : détecte sans modifier.
    private def ensure_include(shell : Shell, dry_run : Bool) : Bool
      present = Primitive.probe?(
        shell,
        "grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\\.d/' /etc/ssh/sshd_config",
      )
      return false if present
      return true if dry_run

      shell.exec(
        %(tmp=$(mktemp); { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat /etc/ssh/sshd_config; } > "$tmp" && cat "$tmp" > /etc/ssh/sshd_config && rm -f "$tmp"),
      )
      true
    end

    # Parse le fichier géré (lignes `Clé Valeur`) en préservant l'ordre
    # d'apparition. Ignore commentaires et lignes vides.
    private def parse(content : String) : Hash(String, String)
      result = {} of String => String
      content.each_line do |raw|
        line = raw.strip
        next if line.empty? || line.starts_with?('#')
        parts = line.split(/\s+/, 2)
        next unless parts.size == 2
        result[parts[0]] = parts[1]
      end
      result
    end

    private def render(directives : Hash(String, String)) : String
      String.build do |io|
        io << HEADER
        directives.each { |k, v| io << k << ' ' << v << '\n' }
      end
    end
  end

  Primitive.register(SshdConfigSet.new)
end
