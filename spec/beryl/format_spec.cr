require "../spec_helper"
require "../../src/beryl"

private def fixture(name : String) : String
  File.expand_path(File.join(__DIR__, "..", "fixtures", "config", name))
end

describe Beryl do
  describe ".format_ssh_target" do
    it "retourne le FQDN seul quand ssh_host == fqdn" do
      rh = Beryl::Config::Root.load(fixture("direct-hosts")).resolve("loulou")
      Beryl.format_ssh_target(rh).should eq("loulou.aloli.net")
    end

    it "annonce « = ssh_host côté provider » quand le ssh_host vient d'un provider hébergeur (OVH)" do
      rh = Beryl::Config::Root.load(fixture("provider-name-search")).resolve("loulou")
      Beryl.format_ssh_target(rh).should eq(
        "loulou.aloli.net (= ns3156789.ip-51-83-6.eu côté ovh)"
      )
    end

    it "annonce « via ssh_host » (sans mention provider) quand le ssh_host vient d'un override YAML" do
      rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("clientvm")
      Beryl.format_ssh_target(rh).should eq(
        "clientvm.aloli.net (via 127.0.0.1)"
      )
    end
  end
end
