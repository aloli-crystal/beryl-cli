require "../../spec_helper"
require "../../../src/beryl/cli/scan"
require "../../../src/beryl/cli/dns_setup"

# Specs unitaires sur les pièces pures de `beryl scan` : parser lsblk,
# sélection de disques, défauts RAID, rendu YAML. La connexion SSH
# n'est pas testée ici (couverte par les tests manuels et le stub SSH
# dans rescue_spec).
describe Beryl::CLI::Scan do
  describe ".parse_lsblk" do
    it "parse la sortie `lsblk -b -d -n -o NAME,SIZE,MODEL,ROTA,TRAN,VENDOR`" do
      # Cas typique OVH dédié : 2 HDD + 2 SSD
      output = <<-LSBLK
      sda  4000787030016 HGST HUS726040ALA610     1 sata ATA
      sdb  4000787030016 HGST HUS726040ALA610     1 sata ATA
      sdc   480103981056 INTEL SSDSC2BB480G7      0 sata ATA
      sdd   480103981056 INTEL SSDSC2BB480G7      0 sata ATA
      LSBLK

      disks = Beryl::CLI::Scan.parse_lsblk(output)
      disks.size.should eq(4)

      disks[0].name.should eq("sda")
      disks[0].size_bytes.should eq(4_000_787_030_016_i64)
      disks[0].is_ssd.should be_false
      disks[0].transport.should eq("sata")
      disks[0].model.should contain("HGST")
      disks[0].dev_path.should eq("/dev/sda")

      disks[2].name.should eq("sdc")
      disks[2].is_ssd.should be_true
      disks[2].model.should contain("INTEL")
    end

    it "ignore les périphériques parasites (loop, zram, sr)" do
      output = <<-LSBLK
      sda  2000398934016 Samsung SSD 870 EVO      0 sata ATA
      loop0          1024 (none)                  1
      sr0   1073741824 (none)                     1 sata
      zram0   8589934592 (none)                   0
      LSBLK

      disks = Beryl::CLI::Scan.parse_lsblk(output)
      disks.size.should eq(1)
      disks[0].name.should eq("sda")
    end

    it "ignore les disques < 1 Go (clés USB douteuses)" do
      output = "usb0 536870912 (none) 1 usb\n"
      Beryl::CLI::Scan.parse_lsblk(output).should be_empty
    end

    it "gère un NVMe sans erreur" do
      output = "nvme0n1 1024209543168 Samsung SSD 980 PRO 1TB 0 nvme ATA\n"
      disks = Beryl::CLI::Scan.parse_lsblk(output)
      disks.size.should eq(1)
      disks[0].name.should eq("nvme0n1")
      disks[0].is_ssd.should be_true
      disks[0].transport.should eq("nvme")
    end

    it "ignore les lignes vides" do
      output = "\n\nsda 2000398934016 Samsung 0 sata ATA\n\n"
      Beryl::CLI::Scan.parse_lsblk(output).size.should eq(1)
    end
  end

  describe "Disk#human_size" do
    it "formate en TB, GB, MB" do
      Beryl::CLI::Scan::Disk.new("a", 4_000_000_000_000_i64, "m", false, "sata").human_size.should contain("TB")
      Beryl::CLI::Scan::Disk.new("a", 500_000_000_000_i64, "m", true, "nvme").human_size.should contain("GB")
      Beryl::CLI::Scan::Disk.new("a", 500_000_000_i64, "m", true, "usb").human_size.should contain("MB")
    end
  end

  describe ".resolve_disk_selection" do
    disks = [
      Beryl::CLI::Scan::Disk.new("sda", 1_000_000_000_000_i64, "A", false, "sata"),
      Beryl::CLI::Scan::Disk.new("sdb", 1_000_000_000_000_i64, "B", false, "sata"),
      Beryl::CLI::Scan::Disk.new("sdc", 500_000_000_000_i64, "C", true, "sata"),
    ]

    it "résout 'all'" do
      Beryl::CLI::Scan.resolve_disk_selection(disks, "all").size.should eq(3)
    end

    it "résout des indices 1-based" do
      result = Beryl::CLI::Scan.resolve_disk_selection(disks, "1,3")
      result.map(&.name).should eq(["sda", "sdc"])
    end

    it "résout des noms de disques" do
      result = Beryl::CLI::Scan.resolve_disk_selection(disks, "sda,sdb")
      result.map(&.name).should eq(["sda", "sdb"])
    end

    it "accepte un mélange indices + noms" do
      result = Beryl::CLI::Scan.resolve_disk_selection(disks, "1,sdc")
      result.map(&.name).should eq(["sda", "sdc"])
    end

    it "lève sur un index hors borne" do
      expect_raises(Exception, /index disque invalide/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "99")
      end
    end

    it "lève sur un nom inconnu" do
      expect_raises(Exception, /disque inconnu/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "sdz")
      end
    end

    it "lève Aborted sur entrée vide" do
      expect_raises(Beryl::CLI::Scan::Aborted) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "")
      end
    end
  end

  describe ".raid_default_for" do
    it "1 disque → stripe" do
      Beryl::CLI::Scan.raid_default_for(1).should eq("stripe")
    end

    it "2 disques → mirror" do
      Beryl::CLI::Scan.raid_default_for(2).should eq("mirror")
    end

    it "3+ disques → stripe (feedback_raid_strategy_rails : RAID 0 + backups)" do
      Beryl::CLI::Scan.raid_default_for(3).should eq("stripe")
      Beryl::CLI::Scan.raid_default_for(5).should eq("stripe")
    end
  end

  describe ".render_yaml" do
    it "génère un YAML consommable par Inventory.load en mode arborescent" do
      host = Beryl::Host.new(
        name: "rails01.aloli.fr",
        provider: "ovh",
        provider_config: {
          "service_name" => YAML::Any.new("ns42.example"),
          "ssh_key_name" => YAML::Any.new("philippe-aloli-fr"),
        },
      )
      disks = [
        Beryl::CLI::Scan::Disk.new("sda", 2_000_000_000_000_i64, "HGST", false, "sata"),
        Beryl::CLI::Scan::Disk.new("sdb", 2_000_000_000_000_i64, "HGST", false, "sata"),
      ]

      yaml = Beryl::CLI::Scan.render_yaml(host, "rails01", disks, "mirror", ["aloli-admin", "rails-servers"])

      yaml.should contain("provider: ovh")
      yaml.should contain("service_name: ns42.example")
      # ssh_key_name par défaut n'est PAS écrit dans le host : il vient
      # d'un groupe zone partagé (feedback Philippe 22 avril 2026 :
      # « la clé SSH ne doit pas être dupliquée sur chaque serveur »).
      yaml.should_not contain("ssh_key_name: philippe-aloli-fr")
      yaml.should contain("ssh_key_name : vient d'un groupe")
      yaml.should contain("- aloli-admin")
      yaml.should contain("- rails-servers")
      yaml.should contain("hostname: rails01")
      yaml.should contain("- /dev/sda")
      yaml.should contain("- /dev/sdb")
      yaml.should contain("raid: mirror")

      # Le YAML doit être parsable et Inventory doit accepter un host
      # généré ainsi (sanity check round-trip).
      parsed = YAML.parse(yaml)
      parsed["provider"].as_s.should eq("ovh")
      parsed["freebsd"]["raid"].as_s.should eq("mirror")
    end

    it "omet le bloc ovh: si pas de provider" do
      host = Beryl::Host.new(name: "plain.aloli.fr")
      disks = [Beryl::CLI::Scan::Disk.new("sda", 1_000_000_000_000_i64, "x", true, "sata")]
      yaml = Beryl::CLI::Scan.render_yaml(host, "plain", disks, "stripe", [] of String)
      yaml.should_not contain("provider:")
      yaml.should_not contain("ovh:")
      yaml.should_not contain("groups:")
    end

    it "écrit ssh_key_name explicite quand --ssh-key-name est passé (override host)" do
      host = Beryl::Host.new(
        name: "rails01.aloli.fr",
        provider: "ovh",
        provider_config: {"service_name" => YAML::Any.new("ns42.example")},
      )
      disks = [Beryl::CLI::Scan::Disk.new("sda", 1_000_000_000_000_i64, "x", false, "sata")]
      yaml = Beryl::CLI::Scan.render_yaml(host, "rails01", disks, "stripe", [] of String, ssh_key_name: "cle-specifique-rails01")
      yaml.should contain("ssh_key_name: cle-specifique-rails01")
      yaml.should contain("override explicite")
    end
  end

  describe ".looks_like_ovh_service_name?" do
    it "reconnaît un service_name OVH standard" do
      Beryl::CLI::Scan.looks_like_ovh_service_name?("ns3156789.ip-51-83-6.eu").should be_true
      Beryl::CLI::Scan.looks_like_ovh_service_name?("ns123.ip-1-2-3.com").should be_true
    end

    it "rejette un FQDN custom" do
      Beryl::CLI::Scan.looks_like_ovh_service_name?("loulou.aloli.net").should be_false
      Beryl::CLI::Scan.looks_like_ovh_service_name?("rails01.example.fr").should be_false
    end
  end
end

describe Beryl::CLI::DnsSetup do
  describe ".derive_ipv6_address" do
    it "ajoute ::1 pour un bloc /64 qui se termine par ::" do
      Beryl::CLI::DnsSetup.derive_ipv6_address("2001:41d0:2:6e01::", "2001:41d0:2:6e01::/64").should eq("2001:41d0:2:6e01::1")
    end

    it "retourne la base pour un format inattendu" do
      Beryl::CLI::DnsSetup.derive_ipv6_address("2001:41d0:2:6e01:1::", "2001:41d0:2:6e01:1::/96").should eq("2001:41d0:2:6e01:1::")
    end
  end

  describe ".default_hostname" do
    it "prend le nom court (avant le premier point)" do
      Beryl::CLI::Scan.default_hostname("rails01.aloli.fr").should eq("rails01")
      Beryl::CLI::Scan.default_hostname("loulou.aloli.net").should eq("loulou")
      Beryl::CLI::Scan.default_hostname("singleword").should eq("singleword")
    end
  end

  describe ".resolve_write_target" do
    it "retourne nil quand ni --write ni --write=FILE" do
      Beryl::CLI::Scan.resolve_write_target(nil, false, "inventory.yml", "h.aloli.fr").should be_nil
    end

    it "priorise --write=FILE sur --write" do
      Beryl::CLI::Scan.resolve_write_target("/tmp/explicit.yml", true, "inv.yml", "h").should eq("/tmp/explicit.yml")
    end

    it "--write seul avec inventaire-fichier : ./hosts/<name>.yml" do
      target = Beryl::CLI::Scan.resolve_write_target(nil, true, "./inventory.yml", "rails01.aloli.fr")
      target.should eq("./hosts/rails01.aloli.fr.yml")
    end

    it "--write seul avec inventaire-dossier : <dir>/hosts/<name>.yml" do
      Dir.mkdir_p("/tmp/beryl-scan-test-inv")
      begin
        target = Beryl::CLI::Scan.resolve_write_target(nil, true, "/tmp/beryl-scan-test-inv", "rails01.aloli.fr")
        target.should eq("/tmp/beryl-scan-test-inv/hosts/rails01.aloli.fr.yml")
      ensure
        Dir.delete("/tmp/beryl-scan-test-inv") rescue nil
      end
    end
  end
end

describe Beryl::Host do
  describe "#ssh_host / #connection" do
    it "utilise ovh.service_name pour un host OVH" do
      host = Beryl::Host.new(
        name: "rails01.aloli.fr",
        provider: "ovh",
        provider_config: {
          "service_name" => YAML::Any.new("ns3156789.ip-51-83-6.eu"),
          "ssh_key_name" => YAML::Any.new("philippe"),
        },
      )
      host.ssh_host.should eq("ns3156789.ip-51-83-6.eu")
      host.ssh_host_is_provider_name?.should be_true
      host.connection.host.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "fallback sur le nom logique si pas de service_name OVH" do
      host = Beryl::Host.new(name: "plain.aloli.fr", provider: "ovh")
      host.ssh_host.should eq("plain.aloli.fr")
      host.ssh_host_is_provider_name?.should be_false
    end

    it "utilise le nom logique pour un provider non-OVH" do
      host = Beryl::Host.new(name: "srv.aloli.fr", provider: "scaleway")
      host.ssh_host.should eq("srv.aloli.fr")
    end

    it "utilise le nom logique si pas de provider" do
      host = Beryl::Host.new(name: "x.aloli.fr")
      host.ssh_host.should eq("x.aloli.fr")
    end
  end
end

describe Beryl do
  describe ".format_ssh_target" do
    it "retourne le nom seul quand ssh_host == name" do
      host = Beryl::Host.new(name: "plain.aloli.fr")
      Beryl.format_ssh_target(host).should eq("plain.aloli.fr")
    end

    it "retourne « name (= ssh_host côté provider) » sinon" do
      host = Beryl::Host.new(
        name: "rails01.aloli.fr",
        provider: "ovh",
        provider_config: {
          "service_name" => YAML::Any.new("ns1.ip-1-2-3.eu"),
        },
      )
      Beryl.format_ssh_target(host).should eq("rails01.aloli.fr (= ns1.ip-1-2-3.eu côté ovh)")
    end
  end
end
