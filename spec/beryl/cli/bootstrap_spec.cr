require "../../spec_helper"
require "../../../src/beryl/cli/bootstrap"

describe Beryl::CLI::Bootstrap do
  describe ".drop_installed_false" do
    it "retire la ligne (avec son commentaire de fin) et rien d'autre" do
      input = "# tika.aloli.net\n\ninstalled: false # retiré par `beryl bootstrap`\nprovider: ovh\nfreebsd:\n  hostname: tika\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input)
        .should eq("# tika.aloli.net\n\nprovider: ovh\nfreebsd:\n  hostname: tika\n")
    end

    it "laisse le fichier intact sans la clé, ou avec `installed: true`" do
      input = "provider: ovh\ninstalled: true\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input).should eq(input)
    end

    it "ne touche pas une clé `installed` imbriquée" do
      input = "jail:\n  installed: false\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input).should eq(input)
    end
  end
end
