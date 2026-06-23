require "../spec_helper"

# HTML représentatif d'un autoindex du miroir releases/amd64/ : on y mêle des
# RC (à IGNORER) et une vieille branche pour vérifier le tri NUMÉRIQUE (9 < 10).
private LISTING = <<-HTML
  <html><head><title>Index of /ftp/releases/amd64/</title></head><body>
  <a href="../">../</a>
  <a href="9.3-RELEASE/">9.3-RELEASE/</a>
  <a href="13.5-RELEASE/">13.5-RELEASE/</a>
  <a href="14.3-RELEASE/">14.3-RELEASE/</a>
  <a href="14.4-RELEASE/">14.4-RELEASE/</a>
  <a href="15.0-RELEASE/">15.0-RELEASE/</a>
  <a href="15.1-RELEASE/">15.1-RELEASE/</a>
  <a href="15.2-RC1/">15.2-RC1/</a>
  <a href="ISO-IMAGES/">ISO-IMAGES/</a>
  </body></html>
  HTML

private FETCHER = ->(_url : String) { LISTING }

describe Beryl::FreebsdRelease do
  describe ".parse_listing" do
    it "extrait les X.Y des X.Y-RELEASE, triés numériquement, sans les RC" do
      Beryl::FreebsdRelease.parse_listing(LISTING).should eq(["9.3", "13.5", "14.3", "14.4", "15.0", "15.1"])
    end

    it "déduplique" do
      Beryl::FreebsdRelease.parse_listing("15.1-RELEASE 15.1-RELEASE 15.0-RELEASE").should eq(["15.0", "15.1"])
    end
  end

  describe ".version_key" do
    it "trie numériquement (9 < 10, pas alphabétique)" do
      (Beryl::FreebsdRelease.version_key("9.3") < Beryl::FreebsdRelease.version_key("10.0")).should be_true
      (Beryl::FreebsdRelease.version_key("15.1") > Beryl::FreebsdRelease.version_key("15.0")).should be_true
    end
  end

  describe ".latest" do
    it "renvoie la plus récente toutes branches" do
      Beryl::FreebsdRelease.latest(FETCHER).should eq("15.1")
    end
  end

  describe ".latest_by_branch" do
    it "donne la dernière de chaque branche majeure" do
      Beryl::FreebsdRelease.latest_by_branch(FETCHER).should eq({9 => "9.3", 13 => "13.5", 14 => "14.4", 15 => "15.1"})
    end
  end
end
