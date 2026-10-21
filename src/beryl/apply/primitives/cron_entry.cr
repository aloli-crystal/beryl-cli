require "../primitive"

module Beryl::Apply
  # Primitive `cron-entry` : maintient une ligne dans la crontab d'un
  # user, à l'intérieur d'un bloc géré par beryl (marqueurs
  # `# >>> beryl >>>` / `# <<< beryl <<<`). Le reste de la crontab de
  # l'utilisateur n'est pas touché.
  #
  # Idempotence : diff par ligne dans le bloc géré. La nouvelle crontab
  # est installée via `crontab` (qui valide la syntaxe).
  #
  #     - cron-entry:
  #         user: root                  # défaut root
  #         entry: "0 3 * * * /usr/sbin/freebsd-update cron"
  #         state: present              # ou absent (défaut present)
  class CronEntry < Primitive
    TMP       = "/tmp/beryl-crontab.tmp"
    BEGIN_TAG = "# >>> beryl >>>"
    END_TAG   = "# <<< beryl <<<"

    def name : String
      "cron-entry"
    end

    # Portable : FreeBSD et Linux.
    def systems : Array(String)
      [FREEBSD, LINUX]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = string(params, "user") || "root"
      entry = required_string(params, "entry").strip
      state = string(params, "state") || "present"

      current = shell.exec("crontab -l -u #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout
      before, block, after, had_block = split_managed(current)

      present = block.includes?(entry)
      case state
      when "present"
        return StepResult.skipped("cron #{user} : entrée déjà présente") if present
        block << entry
        verb = "ajout"
      when "absent"
        return StepResult.skipped("cron #{user} : entrée déjà absente") unless present
        block.reject! { |l| l == entry }
        verb = "retrait"
      else
        raise MissingParam.new("`state` doit valoir present ou absent (reçu #{state.inspect}).")
      end

      msg = "cron #{user} : #{verb} « #{entry} »"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      shell.write_file(TMP, rebuild(before, block, after, had_block))
      shell.exec("crontab -u #{Process.quote(user)} #{Process.quote(TMP)}")
      shell.exec("rm -f #{Process.quote(TMP)}", raise_on_error: false)
      StepResult.applied(msg)
    end

    private def split_managed(content : String) : {Array(String), Array(String), Array(String), Bool}
      lines = content.empty? ? [] of String : content.lines.map(&.chomp)
      bi = lines.index(BEGIN_TAG)
      ei = lines.index(END_TAG)
      if bi && ei && ei > bi
        {lines[0...bi], lines[(bi + 1)...ei].reject(&.strip.empty?), lines[(ei + 1)..], true}
      else
        {lines, [] of String, [] of String, false}
      end
    end

    private def rebuild(before : Array(String), block : Array(String), after : Array(String), had_block : Bool) : String
      String.build do |io|
        before.each { |l| io << l << '\n' }
        if !block.empty? || had_block
          io << BEGIN_TAG << '\n'
          block.each { |l| io << l << '\n' }
          io << END_TAG << '\n'
        end
        after.each { |l| io << l << '\n' }
      end
    end
  end

  Primitive.register(CronEntry.new)
end
