require "file_utils"
require "../../spec_helper"
require "../../support/fake_shell"
require "../../../src/beryl/cli/tang_enroll"

# Bloc `encryption:` (indentation d'une clé de pool), Tang ou ssh_unlock.
private def enc(tang : Bool) : String
  return "      encryption:\n        mode: ssh_unlock\n" unless tang
  "      encryption:\n        mode: tang\n        tang:\n          threshold: 2\n" \
  "          urls: [http://t1:8888, http://t2:8888, http://t3:8888]\n"
end

# Config jetable : un serveur `backup01`, zroot `profile: standard` et pool
# data en Tang (ou zroot en ssh_unlock si `zroot_tang` est faux).
private def tang_host(zroot_tang : Bool = true) : Beryl::Config::ResolvedHost
  dir = File.tempname("beryl-tang-enroll")
  dom = File.join(dir, "initech", "initech.example")
  Dir.mkdir_p(dom)
  File.write(File.join(dir, "initech", "initech.example.domain.yml"), "ssh_keys:\n  - ssh-ed25519 AAAA test\n")
  yaml = "freebsd:\n  hostname: backup01\n  zfs:\n" \
         "    zbackups:\n      disks: [/dev/sdc, /dev/sdd, /dev/sde, /dev/sdf]\n      mountpoint: /backups\n      raid: 6\n" +
         enc(true) +
         "    zroot:\n      boot: true\n      disks: [/dev/sda, /dev/sdb]\n      profile: standard\n      raid: 1\n" +
         enc(zroot_tang)
  File.write(File.join(dom, "backup01.host.yml"), yaml)
  Beryl::Config::Root.load(dir).resolve("backup01")
end

describe Beryl::CLI::TangEnroll do
  describe ".units" do
    it "zroot/encrypted (profile: standard en Tang) d'abord, puis les pools data en Tang" do
      Beryl::CLI::TangEnroll.units(tang_host).map(&.[0]).should eq(["zroot/encrypted", "zbackups"])
    end

    it "zroot en ssh_unlock : seuls les pools data" do
      Beryl::CLI::TangEnroll.units(tang_host(zroot_tang: false)).map(&.[0]).should eq(["zbackups"])
    end
  end

  describe ".missing" do
    it "unités absentes de clevis_zfs_datasets" do
      Beryl::CLI::TangEnroll.missing(["zroot/encrypted", "zbackups"], "zbackups\n").should eq(["zroot/encrypted"])
      Beryl::CLI::TangEnroll.missing(["zroot/encrypted", "zbackups"], "zbackups  zroot/encrypted").should be_empty
      Beryl::CLI::TangEnroll.missing(["zbackups"], "").should eq(["zbackups"])
    end
  end

  describe ".after_sync" do
    it "déjà enrôlé : rien (la clé n'est pas renvoyée)" do
      sh = FakeShell.new
      sh.stub(/sysrc -n clevis_zfs_datasets/, stdout: "zroot/encrypted zbackups\n")
      Beryl::CLI::TangEnroll.after_sync("/nonexistent", tang_host, sh, false).should eq(0)
      sh.ran?(/keylocation|clevis-zfs bind/).should be_false
    end

    it "client Tang absent : rien" do
      sh = FakeShell.new
      sh.stub(/test -x/, exit_code: 1)
      Beryl::CLI::TangEnroll.after_sync("/nonexistent", tang_host, sh, false).should eq(0)
      sh.ran?(/sysrc/).should be_false
    end

    it "essai à blanc : annonce seulement" do
      sh = FakeShell.new
      sh.stub(/sysrc -n clevis_zfs_datasets/, stdout: "zbackups\n")
      Beryl::CLI::TangEnroll.after_sync("/nonexistent", tang_host, sh, true).should eq(0)
      sh.ran?(/keylocation|clevis-zfs bind/).should be_false
    end
  end
end
