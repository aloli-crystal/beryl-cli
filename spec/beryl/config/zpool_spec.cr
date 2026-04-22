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
