require "toml"

# Tri alphabétique du texte déchiffré d'un coffre (`.env.toml.age`) :
# sections, puis variables dans chaque section — COMMENTAIRES GARDÉS.
#
# Rattachement des commentaires :
#   * avant la première section : préambule, reste en tête ;
#   * collés (sans ligne vide) à un en-tête `[section]` : suivent la section ;
#   * avant une variable : suivent la variable ;
#   * en fin de section (rien après) : restent en fin de section.
# Une valeur multi-ligne (`'''…'''`, `"""…"""`) se déplace d'un bloc.
#
# Garde-fou : le résultat est relu ; s'il ne donne pas EXACTEMENT les mêmes
# données que l'original, le texte d'origine est rendu tel quel.
module Beryl::CLI::VaultSort
  extend self

  HEADER = /\A\s*\[\s*([^\[\]]+?)\s*\]\s*(#.*)?\z/
  KEY    = /\A\s*([A-Za-z0-9_-]+)\s*=\s*(.*)\z/m

  private class Entry
    getter key : String
    getter lines : Array(String)

    def initialize(@key, @lines)
    end
  end

  private class Section
    getter name : String
    getter head : Array(String)
    getter entries = [] of Entry
    property tail = [] of String

    def initialize(@name, @head)
    end
  end

  # Texte trié (lignes terminées par `\n`), ou `plaintext` intact si le tri
  # changerait les données ou si le texte n'est pas du TOML valide.
  def sort(plaintext : String) : String
    sorted = render(*parse(plaintext))
    same_data?(plaintext, sorted) ? sorted : plaintext
  rescue
    plaintext
  end

  private def parse(plaintext : String) : {Array(String), Array(Section)}
    lines = plaintext.lines(chomp: true)
    preamble = [] of String
    sections = [] of Section
    pending = [] of String
    i = 0
    while i < lines.size
      line = lines[i]
      if m = line.match(HEADER)
        cur = sections.last?
        # Commentaires collés à l'en-tête → à la section ; le reste du bloc
        # en attente (séparé par une ligne vide) → fin de section précédente.
        split = pending.rindex(&.strip.empty?)
        own = split ? pending[(split + 1)..] : pending
        before = split ? pending[0..split] : [] of String
        if cur
          cur.tail.concat(before)
        else
          preamble.concat(before)
        end
        sections << Section.new(m[1].strip, own + [line])
        pending = [] of String
      elsif (m = line.match(KEY)) && (cur = sections.last?)
        block = [line]
        rest = m[2]
        if (delim = {"'''", "\"\"\""}.find { |d| rest.starts_with?(d) }) && !rest[3..].includes?(delim)
          loop do
            i += 1
            raise "chaîne multi-ligne non fermée" if i >= lines.size
            block << lines[i]
            break if lines[i].includes?(delim)
          end
        end
        cur.entries << Entry.new(m[1], pending.reject(&.strip.empty?) + block)
        pending = [] of String
      else
        # Avant la 1ʳᵉ section aussi : le bloc collé au premier en-tête le
        # suit, le reste devient le préambule (cf. HEADER ci-dessus).
        pending << line
      end
      i += 1
    end
    if cur = sections.last?
      cur.tail.concat(pending)
    else
      preamble.concat(pending)
    end
    {preamble, sections}
  end

  private def render(preamble : Array(String), sections : Array(Section)) : String
    blocks = [] of Array(String)
    pre = trim(preamble)
    blocks << pre unless pre.empty?
    sections.sort_by(&.name).each do |s|
      body = s.head.dup
      s.entries.sort_by(&.key).each { |e| body.concat(e.lines) }
      tail = trim(s.tail)
      body.concat(tail) unless tail.empty?
      blocks << body
    end
    blocks.map(&.join("\n")).join("\n\n") + "\n"
  end

  # Retire les lignes vides de début et de fin.
  private def trim(lines : Array(String)) : Array(String)
    a = lines.index { |l| !l.strip.empty? } || return [] of String
    b = lines.rindex! { |l| !l.strip.empty? }
    lines[a..b]
  end

  private def same_data?(a : String, b : String) : Bool
    ::TOML.parse(a).to_h == ::TOML.parse(b).to_h
  end
end
