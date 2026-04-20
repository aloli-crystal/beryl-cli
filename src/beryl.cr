require "./beryl/version"
require "./beryl/i18n"
require "./beryl/ssh"
require "./beryl/inventory"
require "./beryl/bootstrap"

module Beryl
  # Horodatage sensible à la locale, utilisé par les logs de toutes les
  # sous-commandes. On détecte uniquement le français (LANG/LC_TIME qui
  # commence par `fr`) et on retombe sur l'ISO 8601 sinon : deux formats
  # suffisent pour l'usage de beryl, pas de dépendance à un moteur i18n.
  #
  # * `fr` → `20/04/2026 21h35m12`
  # * autre → `2026-04-20 21:35:12`
  def self.format_timestamp(t : Time) : String
    if french_locale?
      t.to_s("%d/%m/%Y %Hh%Mm%S")
    else
      t.to_s("%Y-%m-%d %H:%M:%S")
    end
  end

  private def self.french_locale? : Bool
    {"LC_ALL", "LC_TIME", "LANG"}.each do |var|
      v = ENV[var]?
      next if v.nil? || v.empty?
      return v.starts_with?("fr")
    end
    false
  end
end

module Beryl
end
