require "../../spec_helper"

# Réponse API GitHub minimale, utilisée comme fixture pour isoler
# MfsBSDRelease des tests réseau réels.
private FAKE_RELEASE_JSON = <<-JSON
{
  "tag_name": "v20260120-080439",
  "assets": [
    {
      "name": "mfsbsd-13.5-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-13.5-RELEASE-amd64.iso"
    },
    {
      "name": "mfsbsd-14.3-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-14.3-RELEASE-amd64.iso"
    },
    {
      "name": "mfsbsd-15.0-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-15.0-RELEASE-amd64.iso"
    },
    {
      "name": "mfsbsd-mini-15.0-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-mini-15.0-RELEASE-amd64.iso"
    },
    {
      "name": "mfsbsd-se-13.5-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-se-13.5-RELEASE-amd64.iso"
    },
    {
      "name": "mfsbsd-se-14.3-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-se-14.3-RELEASE-amd64.iso"
    },
    {
      "name": "mfsbsd-se-15.0-RELEASE-amd64.iso",
      "browser_download_url": "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-se-15.0-RELEASE-amd64.iso"
    }
  ]
}
JSON

private def fake_fetcher(body : String) : Beryl::Bootstrap::MfsBSDRelease::Fetcher
  ->(_url : String) { body }
end

describe Beryl::Bootstrap::MfsBSDRelease do
  describe ".latest" do
    it "retourne la plus haute version SE (15.0) parmi les assets" do
      info = Beryl::Bootstrap::MfsBSDRelease.latest(fake_fetcher(FAKE_RELEASE_JSON))
      info.version.should eq("15.0")
      info.major.should eq("15")
      info.abi.should eq("FreeBSD:15:amd64")
      info.image_url.should eq(
        "https://github.com/mmatuska/mfsbsd/releases/download/v20260120-080439/mfsbsd-se-15.0-RELEASE-amd64.iso"
      )
    end

    it "ignore les variants `mfsbsd-` et `mfsbsd-mini-` (seule la SE compte)" do
      # Seules mfsbsd-vanilla et mfsbsd-mini sont présentes : pas
      # d'asset mfsbsd-se-* → erreur explicite.
      non_se_only = <<-JSON
      {
        "assets": [
          {
            "name": "mfsbsd-15.0-RELEASE-amd64.iso",
            "browser_download_url": "https://example.com/mfsbsd-15.0.iso"
          },
          {
            "name": "mfsbsd-mini-15.0-RELEASE-amd64.iso",
            "browser_download_url": "https://example.com/mfsbsd-mini-15.0.iso"
          }
        ]
      }
      JSON
      expect_raises(Beryl::Bootstrap::MfsBSDRelease::DetectionFailed, /aucun asset mfsbsd-se/) do
        Beryl::Bootstrap::MfsBSDRelease.latest(fake_fetcher(non_se_only))
      end
    end

    it "accepte l'ancien format .img (rétrocompat vx.sk)" do
      img_json = <<-JSON
      {
        "assets": [
          {
            "name": "mfsbsd-se-14.2-RELEASE-amd64.img",
            "browser_download_url": "https://example.com/mfsbsd-se-14.2.img"
          }
        ]
      }
      JSON
      info = Beryl::Bootstrap::MfsBSDRelease.latest(fake_fetcher(img_json))
      info.version.should eq("14.2")
      info.image_url.should end_with(".img")
    end

    it "lève DetectionFailed si aucun asset" do
      empty_json = %q({"assets": []})
      expect_raises(Beryl::Bootstrap::MfsBSDRelease::DetectionFailed, /aucun asset/) do
        Beryl::Bootstrap::MfsBSDRelease.latest(fake_fetcher(empty_json))
      end
    end

    it "lève DetectionFailed si pas de champ assets" do
      bad_json = %q({"message": "Not Found"})
      expect_raises(Beryl::Bootstrap::MfsBSDRelease::DetectionFailed, /aucun champ `assets/) do
        Beryl::Bootstrap::MfsBSDRelease.latest(fake_fetcher(bad_json))
      end
    end
  end
end
