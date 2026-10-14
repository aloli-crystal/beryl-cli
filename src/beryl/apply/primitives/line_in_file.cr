require "../primitive"

module Beryl::Apply
  # Primitive `line-in-file` : garantit qu'UNE ligne est présente dans un
  # fichier EXISTANT, sans réécrire le reste — pour régler un fichier du
  # système (ou d'un paquet) en gardant son contenu d'origine (ex. la ligne
  # `root:` de `/etc/mail/aliases`, à côté des alias système).
  #
  # Sans `match` : ajoute `line` à la fin si elle est absente. Avec `match`
  # (expression régulière) : la PREMIÈRE ligne qui correspond est remplacée
  # par `line` (les suivantes qui correspondent sont retirées) ; aucune ne
  # correspond → `line` ajoutée à la fin. Mode et propriétaire du fichier
  # sont conservés. Fichier absent → échec (ce n'est pas un `file-write`).
  #
  #     - line-in-file:
  #         path: /etc/mail/aliases
  #         match: '^root:'
  #         line: "root: admin@example.net"
  class LineInFile < Primitive
    def name : String
      "line-in-file"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      path = required_string(params, "path")
      line = required_string(params, "line")
      match = string(params, "match")
      q = Process.quote(path)

      read = shell.exec("cat #{q}", raise_on_error: false)
      raise PrimitiveError.new("#{path} introuvable — `line-in-file` ne crée pas de fichier.") unless read.success?

      current = read.stdout
      desired = self.class.ensure_line(current, line, match)
      return StepResult.skipped("#{path} : ligne déjà présente") if desired == current
      return StepResult.applied("#{path} : ligne posée (dry-run)") if dry_run

      # write_file recrée le fichier (root, mode par défaut) : on relit puis
      # on remet le mode et le propriétaire d'origine.
      stat = shell.exec("stat -f '%Lp %Su:%Sg' #{q}").stdout.strip.split
      shell.write_file(path, desired)
      if stat.size == 2
        shell.exec("chmod #{Process.quote(stat[0])} #{q}")
        shell.exec("chown #{Process.quote(stat[1])} #{q}")
      end
      StepResult.applied("#{path} : ligne posée")
    end

    # Contenu après garantie de la ligne. Pur, exposé pour test.
    def self.ensure_line(content : String, line : String, match : String?) : String
      lines = content.lines(chomp: true)
      if pattern = match
        re = Regex.new(pattern)
        hits = (0...lines.size).select { |i| lines[i].matches?(re) }
        unless hits.empty?
          first = hits.first
          return content if lines[first] == line && hits.size == 1
          result = [] of String
          lines.each_with_index do |l, i|
            if i == first
              result << line
            elsif !hits.includes?(i)
              result << l
            end
          end
          return result.join('\n') + "\n"
        end
      elsif lines.includes?(line)
        return content
      end
      (lines << line).join('\n') + "\n"
    end
  end

  Primitive.register(LineInFile.new)
end
