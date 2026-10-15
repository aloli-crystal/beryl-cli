require "../primitive"

module Beryl::Apply
  # Primitive `clamd-config-set` : pose une directive dans
  # `/usr/local/etc/clamd.conf` (format `Clé Valeur`). Idempotent : skip si
  # déjà à la bonne valeur. clamd ne relit PAS sa conf à chaud (un
  # changement de socket/TCP exige un restart) → si clamd tourne, il est
  # REDÉMARRÉ ; s'il n'est pas encore lancé (install), on ne fait que poser
  # la directive (le service-enable le lancera). `value_from_command` pour
  # une valeur runtime (ex. l'IP tailscale via `tailscale ip -4`).
  #
  #     - clamd-config-set:
  #         key: TCPSocket
  #         value: "3310"
  #     - clamd-config-set:
  #         key: TCPAddr
  #         value_from_command: "tailscale ip -4"
  class ClamdConfigSet < Primitive
    PATH   = "/usr/local/etc/clamd.conf"
    HEADER = "# Géré par beryl (clamd-config-set). Ne pas éditer à la main.\n"

    def name : String
      "clamd-config-set"
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

      directives = parse(shell.exec("cat #{Process.quote(PATH)} 2>/dev/null", raise_on_error: false).stdout)
      if directives[key]? == value
        return StepResult.skipped("#{key} déjà = #{value}")
      end

      previous = directives[key]?
      directives[key] = value
      msg = "#{key} : #{previous.nil? ? "(absent)" : previous} → #{value}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("mkdir -p #{Process.quote(File.dirname(PATH))}")
      shell.write_file(PATH, render(directives), mode: "0644")
      if Primitive.probe?(shell, "service clamav_clamd onestatus")
        shell.exec("service clamav_clamd restart")
        msg += " (clamd redémarré)"
      end
      StepResult.applied(msg)
    end

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

  Primitive.register(ClamdConfigSet.new)
end
