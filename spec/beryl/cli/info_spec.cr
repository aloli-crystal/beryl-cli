require "../../spec_helper"
require "../../../src/beryl/cli/info"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::CLI::Info do
  describe ".build_adoc" do
    it "produit un doc AsciiDoc sectionné (synthèse + matériel)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      out = Beryl::CLI::Info.build_adoc([root.resolve("infohw")], "test")
      out.should contain("= Inventaire des serveurs — test")
      out.should contain("== Synthèse")
      out.should contain("Serveurs:: 1")
      out.should contain("== Matériel")
      out.should contain("| Host | Gamme | CPU | RAM | Disques | Prix/mois")
      out.should contain("| infohw")
      out.should contain("Advance-2")
      out.should contain("8c/16t")
      out.should_not contain("== Utilisation disque") # pas d'usage fourni
    end

    it "ajoute la section utilisation disque quand l'usage est fourni" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      usage = {} of String => Array(Beryl::CLI::Info::UsageRow)?
      usage[h.fqdn] = [Beryl::CLI::Info::UsageRow.new("zroot", "460G", "12G", "448G", "3%")]
      out = Beryl::CLI::Info.build_adoc([h], "test", usage)
      out.should contain("== Utilisation disque")
      out.should contain("| infohw | zroot | 460G | 12G | 448G | 3%")
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
