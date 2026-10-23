require "../../spec_helper"
require "../../../src/beryl/cli/os_upgrade"

describe Beryl::CLI::OsUpgrade do
  describe ".parse_version" do
    it "parse une version avec patchlevel" do
      Beryl::CLI::OsUpgrade.parse_version("15.0-RELEASE-p10").should eq({15, 0, 10})
    end

    it "parse une version sans patchlevel" do
      Beryl::CLI::OsUpgrade.parse_version("15.1-RELEASE").should eq({15, 1, nil})
    end

    it "tolère une chaîne brute X.Y" do
      Beryl::CLI::OsUpgrade.parse_version("14.3").should eq({14, 3, nil})
    end

    it "nil si illisible" do
      Beryl::CLI::OsUpgrade.parse_version("inconnu").should be_nil
    end
  end

  describe ".pending_upgrades?" do
    it "vrai quand pkg annonce des paquets à mettre à jour" do
      output = <<-OUT
        Installed packages to be UPGRADED:
        \tFreeBSD-kernel-generic: 15.1p1 -> 15.1p4 [FreeBSD-base]

        Number of packages to be upgraded: 43

        152 MiB to be downloaded.
        OUT
      Beryl::CLI::OsUpgrade.pending_upgrades?(output).should be_true
    end

    it "faux quand le base est à jour (même si le catalogue dit « up to date »)" do
      output = <<-OUT
        Updating FreeBSD-base repository catalogue...
        FreeBSD-base repository is up to date.
        FreeBSD-base is up to date.
        Checking for upgrades (44 candidates): .......... done
        Processing candidates (44 candidates): .......... done
        Checking integrity... done (0 conflicting)
        Your packages are up to date.
        OUT
      Beryl::CLI::OsUpgrade.pending_upgrades?(output).should be_false
    end
  end

  describe ".kernel_mismatch" do
    it "noyau installé ≠ noyau en service → redémarrage en attente" do
      Beryl::CLI::OsUpgrade.kernel_mismatch("15.1-RELEASE-p5\n15.1-RELEASE-p4\n")
        .should eq({installed: "15.1-RELEASE-p5", running: "15.1-RELEASE-p4"})
    end

    it "nil quand le noyau installé est celui qui tourne" do
      Beryl::CLI::OsUpgrade.kernel_mismatch("15.1-RELEASE-p5\n15.1-RELEASE-p5\n").should be_nil
    end

    it "nil sur une sortie illisible (sonde en échec)" do
      Beryl::CLI::OsUpgrade.kernel_mismatch("").should be_nil
    end
  end

  describe ".base_branch" do
    it "mappe X.Y → base_release_<minor> (pkgbase)" do
      Beryl::CLI::OsUpgrade.base_branch("15.1").should eq("base_release_1")
      Beryl::CLI::OsUpgrade.base_branch("15.0").should eq("base_release_0")
      Beryl::CLI::OsUpgrade.base_branch("14.4").should eq("base_release_4")
    end
  end
  describe ".fleet_table" do
    it "une ligne par hôte, le non installé réduit à sa note" do
      states = [
        Beryl::CLI::OsUpgrade::HostState.new("shingouz.example.net", true, nil, nil, "pas encore installé"),
        Beryl::CLI::OsUpgrade::HostState.new("loulou.example.net", true, "15.1-RELEASE-p5", "15.1", "à jour"),
      ]
      Beryl::CLI::OsUpgrade.fleet_table(states).should eq(
        "  shingouz.example.net : pas encore installé\n" \
        "  loulou.example.net    15.1-RELEASE-p5 → 15.1      à jour")
    end
  end

  describe ".fleet_hint" do
    it "rien quand tout est à jour (ou pas encore installé)" do
      states = [
        Beryl::CLI::OsUpgrade::HostState.new("a", true, "15.1-RELEASE-p5", "15.1", "à jour"),
        Beryl::CLI::OsUpgrade::HostState.new("b", true, nil, nil, "pas encore installé"),
      ]
      Beryl::CLI::OsUpgrade.fleet_hint(states).should be_nil
    end

    it "décompte des seules actions à faire + commandes" do
      states = [
        Beryl::CLI::OsUpgrade::HostState.new("a", true, "15.0-RELEASE-p3", "15.1", "montée dispo"),
        Beryl::CLI::OsUpgrade::HostState.new("b", false, nil, nil, "SSH KO : timeout"),
        Beryl::CLI::OsUpgrade::HostState.new("c", true, "15.1-RELEASE-p5", "15.1", "à jour"),
      ]
      hint = Beryl::CLI::OsUpgrade.fleet_hint(states).not_nil!
      hint.should start_with("→ 1 à monter · 1 injoignable(s) : ")
      hint.should contain("beryl os-upgrade <host> --apply")
    end
  end

  describe ".base_orphans" do
    it "garde les paquets FreeBSD-* devenus inutiles" do
      listing = "FreeBSD-clibs-lib32\nFreeBSD-lib9p\n"
      Beryl::CLI::OsUpgrade.base_orphans(listing).should eq(%w[FreeBSD-clibs-lib32 FreeBSD-lib9p])
    end

    it "jamais le noyau ni un ensemble, même orphelins" do
      listing = "FreeBSD-kernel-generic\nFreeBSD-kernel-generic-dbg\nFreeBSD-set-base\nFreeBSD-clibs-lib32\n"
      Beryl::CLI::OsUpgrade.base_orphans(listing).should eq(%w[FreeBSD-clibs-lib32])
    end

    it "ignore les paquets logiciels (affaire de pkg-autoremove)" do
      Beryl::CLI::OsUpgrade.base_orphans("python312\nperl5\n").should be_empty
    end
  end
end
