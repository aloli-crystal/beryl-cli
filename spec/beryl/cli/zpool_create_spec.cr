require "../../spec_helper"
require "../../../src/beryl/cli/zpool_create"

describe Beryl::CLI::ZpoolCreate do
  it "pool clair : partition GPT labellisée, ashift 12, import au démarrage (cache par défaut)" do
    script = Beryl::CLI::ZpoolCreate.create_script("zdata", 0, ["vtbd1"], "/data", false)
    script.should eq <<-SH.chomp
      set -e
      gpart create -s gpt vtbd1
      gpart add -t freebsd-zfs -a 1m -l zdata0 vtbd1
      zpool create -o ashift=12 -m /data zdata /dev/gpt/zdata0
      SH
  end

  it "pool chiffré : clé hex sur stdin (prompt), hors du cache" do
    script = Beryl::CLI::ZpoolCreate.create_script("zdata", 1, ["vtbd1", "vtbd2"], "/data", true)
    script.should contain("gpart add -t freebsd-zfs -a 1m -l zdata1 vtbd2")
    script.should contain(
      "zpool create -o ashift=12 -o cachefile=none -O encryption=on -O keyformat=hex -O keylocation=prompt " \
      "-m /data zdata mirror /dev/gpt/zdata0 /dev/gpt/zdata1"
    )
  end

  it "vdev : mêmes niveaux RAID que bootstrap" do
    Beryl::CLI::ZpoolCreate.vdev(5, ["a", "b", "c"]).should eq("raidz a b c")
    Beryl::CLI::ZpoolCreate.vdev(10, ["a", "b", "c", "d"]).should eq("mirror a b mirror c d")
    expect_raises(ArgumentError) { Beryl::CLI::ZpoolCreate.vdev(4, ["a"]) }
  end
end
