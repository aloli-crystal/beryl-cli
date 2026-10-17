require "../../spec_helper"
require "../../../src/beryl/cli/bootstrap"

describe Beryl::CLI::Bootstrap do
  describe ".drop_installed_false" do
    it "retire la ligne (avec son commentaire de fin) et rien d'autre" do
      input = "# tika.initech.example\n\ninstalled: false # retiré par `beryl bootstrap`\nprovider: ovh\nfreebsd:\n  hostname: tika\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input)
        .should eq("# tika.initech.example\n\nprovider: ovh\nfreebsd:\n  hostname: tika\n")
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

describe "Beryl::CLI::HostKeys.names" do
  it "vise le FQDN, le nom hébergeur, l'IP publique et les IP vRack" do
    fixture = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "ssh-host-override"))
    host = Beryl::Config::Root.load(fixture).resolve("rescuehidden")
    Beryl::CLI::HostKeys.names(host).should eq([
      "rescuehidden.initech.example", "192.168.42.50", "ns9999.ip-1-2-3.eu", "1.2.3.4", "192.168.42.150",
    ])
  end
end
