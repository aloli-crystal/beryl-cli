require "http/client"

module Beryl
  # Détection des RELEASE FreeBSD DISPONIBLES en amont (projet FreeBSD), pour
  # signaler qu'une nouvelle version est sortie (ex. 15.1) sans aller vérifier
  # à la main. Source : le listing du miroir officiel des releases — on ne
  # compte QUE les `X.Y-RELEASE` (pas les -RC/-BETA, ni les snapshots CURRENT).
  #
  # NB : ceci concerne les RELEASE (minor/major, ex. 15.0 → 15.1), PAS les
  # correctifs intra-release (`-pN`) qui relèvent de `freebsd-update`.
  module FreebsdRelease
    LISTING_URL = "https://download.freebsd.org/ftp/releases/amd64/"

    alias Fetcher = Proc(String, String)

    # Fetch HTTP par défaut, suit les redirections (le miroir renvoie souvent
    # un 30x vers un miroir géographique). Injectable pour les tests.
    def self.default_fetch(url : String) : String
      current = url
      5.times do
        resp = HTTP::Client.get(current, headers: HTTP::Headers{"User-Agent" => "beryl"})
        if resp.status.redirection? && (loc = resp.headers["Location"]?)
          current = loc.starts_with?("http") ? loc : "https://download.freebsd.org#{loc}"
          next
        end
        raise "HTTP #{resp.status_code} pour #{current}" unless resp.success?
        return resp.body
      end
      raise "trop de redirections depuis #{url}"
    end

    # Parse le HTML du listing → versions `X.Y` des `X.Y-RELEASE`, triées
    # croissant, dédupliquées. PUR → testable sans réseau.
    def self.parse_listing(html : String) : Array(String)
      html.scan(/(\d+\.\d+)-RELEASE/).map(&.[1]).uniq.sort { |a, b| version_key(a) <=> version_key(b) }
    end

    # Clé de tri numérique d'une version `X.Y` (sinon « 9.0 » > « 10.0 » en alpha).
    def self.version_key(v : String) : {Int32, Int32}
      parts = v.split('.')
      {parts[0]?.try(&.to_i?) || 0, parts[1]?.try(&.to_i?) || 0}
    end

    # Toutes les RELEASE disponibles (versions `X.Y`, triées croissant).
    def self.available(fetcher : Fetcher = ->default_fetch(String)) : Array(String)
      parse_listing(fetcher.call(LISTING_URL))
    end

    # La plus récente toutes branches confondues (ex. « 15.1 »), ou nil.
    def self.latest(fetcher : Fetcher = ->default_fetch(String)) : String?
      available(fetcher).last?
    end

    # Dernière release par branche MAJEURE : {15 => "15.1", 14 => "14.4", …}.
    def self.latest_by_branch(fetcher : Fetcher = ->default_fetch(String)) : Hash(Int32, String)
      by = {} of Int32 => String
      available(fetcher).each do |v|
        major = version_key(v)[0]
        cur = by[major]?
        by[major] = v if cur.nil? || version_key(v) > version_key(cur)
      end
      by
    end
  end
end
