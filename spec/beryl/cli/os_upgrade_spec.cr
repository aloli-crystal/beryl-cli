require "../../spec_helper"
require "../../../src/beryl/cli/os_upgrade"

describe Beryl::CLI::OsUpgrade do
  describe ".parse_version" do
    it "parse une version avec patchlevel" do
      Beryl::CLI::OsUpgrade.parse_version("15.0-RELEASE-p10").should eq({15, 0, 10})
    end

    it "parse une version sans patchlevel" do
      Beryl::CLI::OsUpgrade.parse_version("15.1-RELEASE").should eq({15, 1, nil})
    end

    it "tolère une chaîne brute X.Y" do
      Beryl::CLI::OsUpgrade.parse_version("14.3").should eq({14, 3, nil})
    end

    it "nil si illisible" do
      Beryl::CLI::OsUpgrade.parse_version("inconnu").should be_nil
    end
  end
end
