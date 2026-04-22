require "../../spec_helper"
require "../../../src/beryl/cli/wipe"

describe Beryl::CLI::Wipe do
  describe ".wipe_script_multi" do
    it "lève si la liste de disques est vide" do
      expect_raises(ArgumentError, /disks vide/) do
        Beryl::CLI::Wipe.wipe_script_multi([] of String)
      end
    end

    it "génère une seule étape `zpool destroy` globale (pas une par disque)" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda", "/dev/sdb", "/dev/sdc"])
      # zpool destroy uniquement dans l'entête, pas répété par disque
      script.scan(/zpool destroy/).size.should eq(1)
    end

    it "émet un bloc par disque avec labelclear + sgdisk + dd" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda", "/dev/sdb"])
      script.should contain("--- wipe /dev/sda ---")
      script.should contain("--- wipe /dev/sdb ---")
      script.scan(/sgdisk --zap-all/).size.should eq(2)
      script.scan(/dd if=\/dev\/zero/).size.should eq(2)
    end

    it "wipe_script (single) délègue à wipe_script_multi([disk])" do
      single = Beryl::CLI::Wipe.wipe_script("/dev/sda")
      multi = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda"])
      single.should eq(multi)
    end

    it "quote proprement les chemins (injection shell)" do
      # Process.quote applique des quotes single quand nécessaire.
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda"])
      script.should contain("/dev/sda")
      # Pas de backticks, pas de $() nus autour du chemin.
      script.should_not contain("`/dev/sda`")
    end
  end
end
