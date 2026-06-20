require "../../spec_helper"
require "../../../src/beryl/config"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::Config::Zpool do
  describe ".zfs_mode" do
    it "traduit 0/1/5/6/7/10 en modes ZFS" do
      Beryl::Config::Zpool.zfs_mode(0).should eq("stripe")
      Beryl::Config::Zpool.zfs_mode(1).should eq("mirror")
      Beryl::Config::Zpool.zfs_mode(5).should eq("raidz")
      Beryl::Config::Zpool.zfs_mode(6).should eq("raidz2")
      Beryl::Config::Zpool.zfs_mode(7).should eq("raidz3")
      Beryl::Config::Zpool.zfs_mode(10).should eq("mirror_stripe")
    end

    it "lève sur niveau inconnu" do
      expect_raises(Beryl::Config::Zpool::UnknownRaidLevel) do
        Beryl::Config::Zpool.zfs_mode(42)
      end
    end
  end

  describe ".validate!" do
    it "accepte les combinaisons valides" do
      Beryl::Config::Zpool.validate!(0, 1)  # stripe avec 1 disque
      Beryl::Config::Zpool.validate!(1, 2)  # mirror avec 2
      Beryl::Config::Zpool.validate!(5, 3)  # raidz avec 3
      Beryl::Config::Zpool.validate!(6, 4)  # raidz2 avec 4
      Beryl::Config::Zpool.validate!(7, 5)  # raidz3 avec 5
      Beryl::Config::Zpool.validate!(10, 4) # RAID 10 pair
    end

    it "lève si nombre de disques insuffisant" do
      expect_raises(Beryl::Config::Zpool::InvalidDiskCount, /minimum 2/) do
        Beryl::Config::Zpool.validate!(1, 1) # mirror avec 1 disque
      end
      expect_raises(Beryl::Config::Zpool::InvalidDiskCount, /minimum 3/) do
        Beryl::Config::Zpool.validate!(5, 2) # raidz avec 2 disques
      end
    end

    it "lève si RAID 10 avec nombre impair de disques" do
      expect_raises(Beryl::Config::Zpool::InvalidDiskCount, /PAIR/) do
        Beryl::Config::Zpool.validate!(10, 5)
      end
    end
  end
end

describe Beryl::Config::ResolvedHost do
  describe "#zpools (nouvelle syntaxe freebsd.zfs.<nom>)" do
    it "parse plusieurs pools depuis freebsd.zfs" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-pool"))
      rh = root.resolve("backup01.aloli.net")
      pools = rh.zpools
      pools.size.should eq(2)

      zroot = pools.find { |p| p.name == "zroot" }.not_nil!
      zroot.boot.should be_true
      zroot.raid.should eq(0)
      zroot.disks.should eq(["/dev/sda"])

      zdata = pools.find { |p| p.name == "zdata" }.not_nil!
      zdata.boot.should be_false
      zdata.raid.should eq(10)
      zdata.disks.size.should eq(4)
      zdata.mountpoint.should eq("/data")
    end

    it "expose boot_zpool et data_zpools" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-pool"))
      rh = root.resolve("backup01.aloli.net")
      rh.boot_zpool.name.should eq("zroot")
      rh.data_zpools.map(&.name).should eq(["zdata"])
    end

    it "all_declared_disks retourne l'union à plat" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-pool"))
      rh = root.resolve("backup01.aloli.net")
      rh.all_declared_disks.sort.should eq(["/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"])
    end
  end

  describe "#validate_zfs!" do
    it "passe sur une config multi-pool valide" do
      rh = Beryl::Config::Root.load(File.join(FIXTURES, "multi-pool")).resolve("backup01.aloli.net")
      rh.validate_zfs!
    end

    it "lève NoBootPool si aucun pool avec boot: true" do
      rh = Beryl::Config::Root.load(File.join(FIXTURES, "bad-zfs-no-boot")).resolve("bad.aloli.net")
      expect_raises(Beryl::Config::ResolvedHost::NoBootPool, /aucun pool `boot: true`/) do
        rh.validate_zfs!
      end
    end

    it "lève DuplicatedDisk si un disque est dans plusieurs pools" do
      rh = Beryl::Config::Root.load(File.join(FIXTURES, "bad-zfs-duplicate-disk")).resolve("bad.aloli.net")
      expect_raises(Beryl::Config::ResolvedHost::DuplicatedDisk, /plusieurs pools/) do
        rh.validate_zfs!
      end
    end
  end
end

describe Beryl::Config::EncryptionConfig do
  describe "#validate!" do
    it "accepte ssh_unlock sans tang_urls" do
      Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
      ).validate!
    end

    it "rejette ssh_unlock + tang_urls (incohérent)" do
      cfg = Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
        tang_urls: ["http://tang.local:8888"],
      )
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /incompatible/) do
        cfg.validate!
      end
    end

    it "accepte tang single-URL avec threshold 1" do
      Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::Tang,
        tang_urls: ["http://tang.local:8888"],
        threshold: 1,
      ).validate!
    end

    it "accepte tang multi-URL avec threshold 2 (SSS)" do
      Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::Tang,
        tang_urls: ["http://t1:8888", "http://t2:8888", "http://t3:8888"],
        threshold: 2,
      ).validate!
    end

    it "rejette tang sans URL" do
      cfg = Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::Tang,
      )
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /au moins une URL/) do
        cfg.validate!
      end
    end

    it "rejette threshold > nombre d'URLs" do
      cfg = Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::Tang,
        tang_urls: ["http://t1:8888", "http://t2:8888"],
        threshold: 3,
      )
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /threshold/) do
        cfg.validate!
      end
    end

    it "rejette threshold < 1" do
      cfg = Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::Tang,
        tang_urls: ["http://t1:8888"],
        threshold: 0,
      )
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /threshold/) do
        cfg.validate!
      end
    end

    it "rejette compression invalide" do
      cfg = Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
        compression: "bzip2",
      )
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /compression/) do
        cfg.validate!
      end
    end

    it "accepte les 3 compressions standard" do
      ["lz4", "zstd-3", "off"].each do |c|
        Beryl::Config::EncryptionConfig.new(
          mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
          compression: c,
        ).validate!
      end
    end
  end

  describe "#ssh_unlock? / #tang?" do
    it "discrimine bien les deux modes" do
      cfg_ssh = Beryl::Config::EncryptionConfig.new(mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock)
      cfg_ssh.ssh_unlock?.should be_true
      cfg_ssh.tang?.should be_false

      cfg_tang = Beryl::Config::EncryptionConfig.new(
        mode: Beryl::Config::EncryptionConfig::Mode::Tang,
        tang_urls: ["http://tang:8888"],
      )
      cfg_tang.ssh_unlock?.should be_false
      cfg_tang.tang?.should be_true
    end
  end

  describe ".from_yaml" do
    it "retourne nil si la valeur est nil (pas de chiffrement déclaré)" do
      Beryl::Config::EncryptionConfig.from_yaml(nil, "zpool").should be_nil
    end

    it "retourne nil sur encryption: false (legacy)" do
      yaml_any = YAML::Any.new(false)
      Beryl::Config::EncryptionConfig.from_yaml(yaml_any, "zpool").should be_nil
    end

    it "retourne ssh_unlock sur encryption: true (legacy, défaut Aloli)" do
      yaml_any = YAML::Any.new(true)
      cfg = Beryl::Config::EncryptionConfig.from_yaml(yaml_any, "zpool").not_nil!
      cfg.ssh_unlock?.should be_true
      cfg.tang_urls.should be_empty
      cfg.threshold.should eq(1)
      cfg.compression.should eq("lz4")
    end

    it "retourne ssh_unlock sur encryption.mode: ssh_unlock (forme étendue)" do
      yaml_str = "mode: ssh_unlock\ncompression: zstd-3"
      yaml_any = YAML.parse(yaml_str)
      cfg = Beryl::Config::EncryptionConfig.from_yaml(yaml_any, "zpool").not_nil!
      cfg.ssh_unlock?.should be_true
      cfg.compression.should eq("zstd-3")
    end

    it "retourne tang single-URL avec threshold 1 par défaut" do
      yaml_str = "mode: tang\ntang:\n  urls:\n    - http://tang.local:8888"
      yaml_any = YAML.parse(yaml_str)
      cfg = Beryl::Config::EncryptionConfig.from_yaml(yaml_any, "zpool").not_nil!
      cfg.tang?.should be_true
      cfg.tang_urls.should eq(["http://tang.local:8888"])
      cfg.threshold.should eq(1)
    end

    it "retourne tang multi-URL avec threshold explicite (SSS)" do
      yaml_str = <<-YAML
      mode: tang
      tang:
        urls:
          - http://t1:8888
          - http://t2:8888
          - http://t3:8888
        threshold: 2
      compression: zstd-3
      YAML
      yaml_any = YAML.parse(yaml_str)
      cfg = Beryl::Config::EncryptionConfig.from_yaml(yaml_any, "zpool").not_nil!
      cfg.tang?.should be_true
      cfg.tang_urls.size.should eq(3)
      cfg.threshold.should eq(2)
      cfg.compression.should eq("zstd-3")
    end

    it "lève sur mode inconnu" do
      yaml_str = "mode: vault"
      yaml_any = YAML.parse(yaml_str)
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /mode=.*inconnu/) do
        Beryl::Config::EncryptionConfig.from_yaml(yaml_any, "zpool")
      end
    end
  end
end

describe Beryl::Config::Pool do
  describe "#encrypted?" do
    it "retourne false si encryption: nil" do
      p = Beryl::Config::Pool.new(
        name: "zroot", boot: true, raid: 0, disks: ["/dev/sda"],
      )
      p.encrypted?.should be_false
    end

    it "retourne true si encryption: <config>" do
      p = Beryl::Config::Pool.new(
        name: "zdata", boot: false, raid: 0, disks: ["/dev/sdb"],
        encryption: Beryl::Config::EncryptionConfig.new(
          mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
        ),
      )
      p.encrypted?.should be_true
    end
  end

  describe "#validate!" do
    it "rejette encryption sur un pool boot" do
      p = Beryl::Config::Pool.new(
        name: "zroot", boot: true, raid: 0, disks: ["/dev/sda"],
        encryption: Beryl::Config::EncryptionConfig.new(
          mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
        ),
      )
      expect_raises(Beryl::Config::BootPoolEncryptionUnsupported) do
        p.validate!
      end
    end

    it "propage l'erreur de validation de l'EncryptionConfig" do
      p = Beryl::Config::Pool.new(
        name: "zdata", boot: false, raid: 0, disks: ["/dev/sdb"],
        mountpoint: "/data",
        encryption: Beryl::Config::EncryptionConfig.new(
          mode: Beryl::Config::EncryptionConfig::Mode::Tang, # sans URL → invalide
        ),
      )
      expect_raises(Beryl::Config::InvalidEncryptionConfig, /au moins une URL/) do
        p.validate!
      end
    end
  end

  describe "#profile / #system_datasets (architecture C+)" do
    it "dérive le profil `standard` : 3 datasets chiffrés + /var/log clair zstd-3" do
      p = Beryl::Config::Pool.new(
        name: "zroot", boot: true, raid: 0, disks: ["/dev/nvme0n1"],
        encryption: Beryl::Config::EncryptionConfig.new(
          mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
        ),
        profile: "standard",
      )
      ds = p.system_datasets
      ds.map(&.mountpoint).should eq(["/home", "/opt", "/usr/local/etc", "/var/log"])
      ds.select(&.encrypted).map(&.mountpoint).should eq(["/home", "/opt", "/usr/local/etc"])
      zlog = ds.find { |d| d.mountpoint == "/var/log" }.not_nil!
      zlog.encrypted.should be_false
      zlog.compression.should eq("zstd-3")
      # Encryptionroot partagé : un seul unlock ouvre les 3.
      p.encryption_root.should eq("zroot/encrypted")
      ds.select(&.encrypted).all? { |d| d.name.starts_with?("zroot/encrypted/") }.should be_true
    end

    it "pas de profil → aucun dataset dérivé, pas d'encryptionroot" do
      p = Beryl::Config::Pool.new(name: "zroot", boot: true, raid: 0, disks: ["/dev/sda"])
      p.system_datasets.should be_empty
      p.encryption_root.should be_nil
    end

    it "AUTORISE encryption sur le pool boot AVEC profile (chiffre les datasets, pas le /)" do
      p = Beryl::Config::Pool.new(
        name: "zroot", boot: true, raid: 0, disks: ["/dev/sda"],
        encryption: Beryl::Config::EncryptionConfig.new(
          mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock,
        ),
        profile: "standard",
      )
      p.validate! # ne lève PAS (≠ pool boot chiffré sans profil)
    end
  end
end
