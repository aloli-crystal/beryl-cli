require "../../spec_helper"
require "../../../src/beryl/cli/info"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::CLI::Info do
  describe ".build_adoc" do
    it "produit une table AsciiDoc avec en-tête, données host et totaux" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      hosts = ["infohw"].map { |n| root.resolve(n) }
      out = Beryl::CLI::Info.build_adoc(hosts, "test")
      out.should contain("= Inventaire des serveurs — test")
      out.should contain("| Host | Gamme | CPU | RAM | Disques | vRack | Rôle | Prix/mois")
      out.should contain("| infohw")
      out.should contain("Advance-2")
      out.should contain("8c/16t")
      out.should contain("1 serveurs")
    end
  end

  describe ".upsert_block" do
    it "remplace un bloc existant en préservant les autres clés" do
      content = "provider: ovh\novh:\n  service_name: old\nvrack:\n  name: pn-1\n"
      out = Beryl::CLI::Info.upsert_block(content, "ovh",
        ["ovh:", "  service_name: new", "  commercial_name: Advance-2"])
      out.should eq("provider: ovh\novh:\n  service_name: new\n  commercial_name: Advance-2\nvrack:\n  name: pn-1\n")
    end

    it "ajoute le bloc en fin si absent, en préservant les commentaires" do
      content = "# Clients : all\nprovider: ovh\n"
      out = Beryl::CLI::Info.upsert_block(content, "hardware",
        ["hardware:", "  cpu: EPYC", "  ram_gb: 64"])
      out.should contain("# Clients : all")
      out.should contain("provider: ovh")
      out.should contain("hardware:\n  cpu: EPYC\n  ram_gb: 64")
    end

    it "ne déborde pas sur le bloc suivant lors du remplacement" do
      content = "provider: ovh\novh:\n  service_name: x\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Info.upsert_block(content, "ovh", ["ovh:", "  service_name: y"])
      out.should contain("apply_recipes:\n  - clamav")
      out.should contain("  service_name: y")
      out.should_not contain("service_name: x")
    end
  end
end
