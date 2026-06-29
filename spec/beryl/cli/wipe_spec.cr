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

    it "sans passes (défaut 0) : pas de réécriture intégrale, métadonnées seules" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda"])
      script.should_not contain("shred")
      script.should_not contain("effacement sécurisé")
      script.should_not contain("/dev/urandom")
    end

    it "avec passes >= 1 : réécrit tout le disque via shred (N passes), un bloc par disque" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda", "/dev/sdb"], 3)
      script.scan(/shred -v -f -n 3 /).size.should eq(2)
      script.should contain("effacement sécurisé : 3 passe(s)")
      # fallback dd urandom présent pour rescue sans shred
      script.should contain("dd if=/dev/urandom")
      # le zap GPT final reste fait après la réécriture
      script.scan(/sgdisk --zap-all/).size.should eq(2)
    end

    it "mode matériel : nvme format + blkdiscard + repli shred, par disque" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/nvme0n1", "/dev/sda"], 0, hardware: true)
      script.should contain("secure-erase matériel de /dev/nvme0n1")
      script.should contain("nvme format")
      script.should contain("blkdiscard -f")
      script.should contain("rotational")
      # repli shred par défaut 1 passe quand passes=0
      script.should contain("shred -v -f -n 1")
      # le zap GPT final reste fait
      script.scan(/sgdisk --zap-all/).size.should eq(2)
    end

    it "mode matériel : passes>0 fixe le nombre de passes du repli HDD" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda"], 3, hardware: true)
      script.should contain("shred -v -f -n 3")
      # pas de bloc overwrite logique pur (c'est le mode matériel qui prime)
      script.should_not contain("effacement sécurisé : 3 passe(s)")
    end

    it "erase_plan : résumé par disque selon le mode (sans dumper le script)" do
      Beryl::CLI::Wipe.erase_plan("/dev/nvme0n1", 0, true).should contain("NVMe")
      Beryl::CLI::Wipe.erase_plan("/dev/sda", 0, true).should contain("blkdiscard")
      Beryl::CLI::Wipe.erase_plan("/dev/sda", 0, true).should contain("shred 1")
      Beryl::CLI::Wipe.erase_plan("/dev/sda", 3, false).should contain("3 passe(s)")
      Beryl::CLI::Wipe.erase_plan("/dev/sda", 0, false).should contain("métadonnées")
    end

    it "parallel : un sous-shell par disque + wait, pools détruits avant" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda", "/dev/sdb"], 1, false, parallel: true)
      script.should contain("__pids=")
      script.scan(/\) &\n__pids="\$__pids \$!"/).size.should eq(2)
      script.should contain("wait \"$__p\"")
      script.should contain("exit $__rc")
      # la destruction des pools reste UNIQUE et avant (hors sous-shells)
      script.scan(/zpool destroy/).size.should eq(1)
    end

    it "parallel ignoré pour un seul disque (rien à paralléliser)" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda"], 1, false, parallel: true)
      script.should_not contain("__pids=")
      script.should_not contain("wait \"$__p\"")
    end

    it "sequential (défaut générateur) : pas de sous-shells même à plusieurs disques" do
      script = Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda", "/dev/sdb"], 1, false)
      script.should_not contain("__pids=")
    end

    it "refuse un nombre de passes négatif" do
      expect_raises(ArgumentError, /passes négatif/) do
        Beryl::CLI::Wipe.wipe_script_multi(["/dev/sda"], -1)
      end
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
