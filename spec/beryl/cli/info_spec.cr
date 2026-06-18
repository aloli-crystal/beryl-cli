require "../../spec_helper"
require "../../../src/beryl/cli/info"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::CLI::Info do
  describe ".build_adoc" do
    it "produit un doc AsciiDoc sectionné (synthèse + matériel + réseau)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      out = Beryl::CLI::Info.build_adoc([root.resolve("infohw")], "test")
      out.should contain("= Inventaire des serveurs — test")
      out.should contain(":pdf-page-layout: landscape") # paysage
      out.should contain("== Synthèse")
      out.should contain("== Matériel")
      out.should contain("| Host | Gamme | Baie | CPU | RAM | Disques | Prix/mois")
      out.should contain("16RA09") # rack
      out.should contain("== Réseau")
      out.should contain("| Host | IPv4 publique | IPv6 publique | vRack | Rôle")
      out.should contain("1.2.3.4")
      out.should contain("2001:db8::1")
      out.should_not contain("== Utilisation disque") # pas d'usage fourni
    end

    it "alerte sur les serveurs co-localisés (même baie)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      hosts = ["infohw", "infohw2"].map { |n| root.resolve(n) }
      out = Beryl::CLI::Info.build_adoc(hosts, "test")
      out.should contain("[WARNING]")
      out.should contain("CO-LOCALISÉS")
      out.should contain("*16RA09* : infohw, infohw2")
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

  describe ".parse_zpool" do
    it "une ligne par pool" do
      txt = "zroot\t460G\t12G\t448G\t3%\nzdata\t14T\t5T\t9T\t36%"
      rows = Beryl::CLI::Info.parse_zpool(txt)
      rows.map(&.label).should eq(["zroot", "zdata"])
      rows[1].pct.should eq("36%")
    end
  end

  describe ".parse_df" do
    it "regroupe les datasets ZFS par pool (montage racine), filtre les pseudo-FS" do
      df = <<-DF
        Filesystem            Size    Used   Avail Capacity  Mounted on
        zroot/ROOT/default    430G    8.0G    422G     2%    /
        zroot/usr/home        422G    100K    422G     0%    /usr/home
        zdata                  14T    5.0T    9.0T    36%    /data
        devfs                  1.0K    1.0K      0B   100%    /dev
        tmpfs                  4.0G    1.0M    4.0G     0%    /tmp
        DF
      rows = Beryl::CLI::Info.parse_df(df)
      rows.map(&.label).should eq(["zroot", "zdata"])
      rows[0].used.should eq("8.0G") # racine du pool (/), pas /usr/home
      rows[1].pct.should eq("36%")
    end

    it "garde les devices classiques par montage (Linux/UFS)" do
      df = <<-DF
        Filesystem      Size  Used Avail Use% Mounted on
        /dev/sda1        50G   20G   30G  40% /
        /dev/sdb1       2.0T  1.2T  800G  60% /data
        tmpfs           7.8G     0  7.8G   0% /run
        DF
      rows = Beryl::CLI::Info.parse_df(df)
      rows.map(&.label).should eq(["/", "/data"])
      rows[1].used.should eq("1.2T")
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
