require "yaml"

# Failles ACCEPTÉES (clé `vuln_accepted:` des fiches, héritable) : un paquet
# vulnérable SANS correctif possible (logiciel en fin de vie qu'on empaquette
# soi-même, ex. openssl111 pour Ruby 2.7) sort de l'alerte de `beryl
# upgrade`, mais reste AFFICHÉ, avec sa raison et son échéance. Accepter
# n'est pas masquer : la décision est écrite, datée, versionnée.
#
#     vuln_accepted:
#       openssl111:
#         reason: "OpenSSL 1.1.1 en fin de vie, requis par Ruby 2.7 (seul usage)"
#         until: 2027-05-31
#
# `reason` et `until` OBLIGATOIRES : une acceptation incomplète ne vaut rien
# (le paquet reste en alerte, avec la raison du refus). Passé `until`
# (inclus), l'acceptation est ÉCHUE : retour dans l'alerte → la décision est
# à revoir, pas à oublier.
module Beryl::VulnAccept
  extend self

  record Entry, package : String, reason : String?, until_date : String?

  record Result, alert : Array(String), notes : Array(String)

  # Entrées de la clé `vuln_accepted:` (table `paquet: { reason, until }`).
  # Forme inattendue → entrée vide (refusée à l'usage, avec sa raison). Pur.
  def entries(any : YAML::Any?) : Array(Entry)
    h = any.try(&.as_h?) || return [] of Entry
    h.compact_map do |k, v|
      name = k.as_s? || next
      fields = v.as_h? || {} of YAML::Any => YAML::Any
      reason = fields[YAML::Any.new("reason")]?.try(&.as_s?).try(&.strip).presence
      Entry.new(name, reason, date(fields[YAML::Any.new("until")]?))
    end
  end

  # Date `AAAA-MM-JJ` (YAML la lit en date ou en texte), sinon nil. Pur.
  def date(any : YAML::Any?) : String?
    return unless any
    if t = any.raw.as?(Time)
      return t.to_s("%F")
    end
    s = any.as_s?.try(&.strip) || return
    s.matches?(/\A\d{4}-\d{2}-\d{2}\z/) ? s : nil
  end

  # Nom d'un paquet « nom-version » (sortie de `pkg audit -q`). Pur.
  def package_name(pkg_version : String) : String
    pkg_version.rindex('-').try { |i| pkg_version[0...i] } || pkg_version
  end

  # Répartit les paquets vulnérables : `alert` (non acceptés, acceptation
  # invalide ou échue) et `notes` (une ligne par acceptation, en vigueur ou
  # non). `today` au format AAAA-MM-JJ. Pur.
  def split(vulns : Array(String), entries : Array(Entry), today : String) : Result
    alert = [] of String
    notes = [] of String
    vulns.each do |v|
      e = entries.find { |x| x.package == package_name(v) }
      unless e
        alert << v
        next
      end
      reason = e.reason
      until_date = e.until_date
      if reason.nil? || until_date.nil?
        alert << v
        notes << "#{v} : acceptation `vuln_accepted.#{e.package}` INVALIDE (`reason` et `until: AAAA-MM-JJ` obligatoires)"
      elsif today > until_date
        alert << v
        notes << "#{v} : acceptation ÉCHUE le #{until_date} — à revoir (#{reason})"
      else
        notes << "#{v} : faille acceptée jusqu'au #{until_date} — #{reason}"
      end
    end
    Result.new(alert, notes)
  end
end
