require "http/client"
require "json"

module Beryl::Bootstrap
  # Détection de la dernière release mfsBSD disponible sur
  # https://github.com/mmatuska/mfsbsd/releases (source officielle
  # actuelle, miroirée sur mfsbsd.vx.sk seulement pour les anciennes
  # majors).
  #
  # **Pourquoi dynamique :** mfsBSD évolue dans son coin côté Martin
  # Matuska, au fil des releases FreeBSD. Figer une version en dur dans
  # beryl (ex: « 14.2 ») condamne l'outil à devoir être rebuildé à
  # chaque nouvelle release. La détection au runtime évite ça et garantit
  # qu'un bootstrap utilise la dernière version disponible au moment du
  # lancement.
  #
  # **mfsBSD SE contient les dists FreeBSD** (base.txz + kernel.txz +
  # MANIFEST) de la MÊME version : installer FreeBSD X.Y via mfsBSD SE
  # X.Y évite le téléchargement et le mismatch pkg. C'est pour ça que
  # `freebsd_version` et `mfsbsd_version` sont synchronisés dans beryl.
  #
  # **Pas de défaut silencieux** (règle Aloli) : si la détection échoue
  # (réseau HS, API GitHub en panne, JSON malformé), on lève
  # `DetectionFailed` — pas de fallback sur une valeur arbitraire.
  # L'opérateur peut forcer une version avec
  # `beryl bootstrap --freebsd-version=X.Y`.
  module MfsBSDRelease
    LATEST_API_URL = "https://api.github.com/repos/mmatuska/mfsbsd/releases/latest"

    # Pattern extrayant la version FreeBSD d'un nom d'asset mfsBSD SE.
    # Accepte `.iso` (format actuel GitHub) et `.img` (ancien format vx.sk).
    SE_ASSET_RX = /^mfsbsd-se-(\d+)\.(\d+)-RELEASE-amd64\.(iso|img)$/

    # Info complète sur une release mfsBSD SE.
    struct Info
      getter version : String   # ex: "15.0"
      getter major : String     # ex: "15"
      getter abi : String       # ex: "FreeBSD:15:amd64"
      getter image_url : String # URL complète du .iso / .img

      def initialize(@version, @major, @abi, @image_url)
      end
    end

    class DetectionFailed < Exception
    end

    # Fetcher injectable : reçoit une URL, retourne le corps texte.
    alias Fetcher = String -> String

    # Fetcher par défaut : `HTTP::Client.get` avec User-Agent (GitHub API
    # refuse les requêtes sans User-Agent).
    def self.default_fetch(url : String) : String
      response = HTTP::Client.get(
        url,
        HTTP::Headers{
          "User-Agent" => "beryl/#{Beryl::VERSION}",
          "Accept"     => "application/vnd.github+json",
        },
      )
      raise DetectionFailed.new(
        "HTTP #{response.status_code} sur #{url}"
      ) unless response.status_code == 200
      response.body
    end

    # Détecte la dernière mfsBSD SE disponible sur GitHub releases.
    #
    # Étapes :
    #   1. GET l'API GitHub → JSON de la dernière release
    #   2. Parcourt `assets[]` et filtre ceux dont le nom matche
    #      `mfsbsd-se-<X>.<Y>-RELEASE-amd64.<iso|img>$`
    #   3. Retourne l'Info de la plus haute version (par (major, minor))
    #
    # `fetcher` est injectable pour les tests.
    def self.latest(fetcher : Fetcher = ->default_fetch(String)) : Info
      body = fetcher.call(LATEST_API_URL)
      parsed = JSON.parse(body)
      assets = parsed["assets"]?.try(&.as_a?) || raise DetectionFailed.new(
        "aucun champ `assets[]` dans la réponse GitHub"
      )

      candidates = [] of {Int32, Int32, String}
      assets.each do |asset|
        name = asset["name"]?.try(&.as_s?) || next
        url = asset["browser_download_url"]?.try(&.as_s?) || next
        if m = SE_ASSET_RX.match(name)
          candidates << {m[1].to_i, m[2].to_i, url}
        end
      end

      raise DetectionFailed.new(
        "aucun asset mfsbsd-se-<X>.<Y>-RELEASE-amd64.(iso|img) dans la release GitHub"
      ) if candidates.empty?

      best = candidates.max_by { |(ma, mi, _)| {ma, mi} }
      major, minor, url = best
      Info.new(
        version: "#{major}.#{minor}",
        major: major.to_s,
        abi: "FreeBSD:#{major}:amd64",
        image_url: url,
      )
    end
  end
end
