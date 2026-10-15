require "../primitive"

module Beryl::Apply
  # Primitive `sysrc-set` : pose une variable dans `/etc/rc.conf` via
  # `sysrc`.
  #
  # Idempotence : `sysrc -n <key>` retourne déjà la valeur cible → skip.
  #
  #     - sysrc-set:
  #         key: clear_tmp_enable
  #         value: "YES"
  class SysrcSet < Primitive
    def name : String
      "sysrc-set"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      key = required_string(params, "key")
      value = required_string(params, "value")

      probe = Primitive.read_probe(shell, "sysrc -n #{Process.quote(key)} 2>/dev/null")
      current = probe.success? ? probe.stdout.chomp : nil

      if current == value
        return StepResult.skipped("#{key} déjà = #{value}")
      end

      msg = "#{key} : #{current.nil? ? "(non posé)" : current} → #{value}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.exec("sysrc #{Process.quote("#{key}=#{value}")}")
      StepResult.applied(msg)
    end
  end

  Primitive.register(SysrcSet.new)
end
