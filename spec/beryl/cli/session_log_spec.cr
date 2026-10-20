require "../../spec_helper"
require "../../../src/beryl/cli/session_log"

describe Beryl::CLI::SessionLog do
  describe ".strip_flag" do
    it "retire --no-log où qu'il soit" do
      Beryl::CLI::SessionLog.strip_flag(["apply", "loulou", "--no-log", "--apply"]).should eq({["apply", "loulou", "--apply"], true})
      Beryl::CLI::SessionLog.strip_flag(["--no-log", "-c", "/x", "upgrade"]).should eq({["-c", "/x", "upgrade"], true})
    end

    it "laisse argv tel quel sans le drapeau" do
      Beryl::CLI::SessionLog.strip_flag(["upgrade", "aloli.net"]).should eq({["upgrade", "aloli.net"], false})
    end
  end

  describe ".wanted?" do
    it "journalise par défaut les commandes du parc" do
      Beryl::CLI::SessionLog.wanted?("apply", ["loulou"], false, false).should be_true
      Beryl::CLI::SessionLog.wanted?("os-upgrade", ["aloli.net", "--apply"], false, false).should be_true
    end

    it "respecte --no-log" do
      Beryl::CLI::SessionLog.wanted?("apply", ["loulou"], true, false).should be_false
    end

    it "ne relance pas un enfant déjà sous journal" do
      Beryl::CLI::SessionLog.wanted?("apply", ["loulou"], false, true).should be_false
    end

    it "ne journalise ni l'aide ni la saisie de secrets" do
      %w[env init add-provider add-domain help version show list-hosts fmt].each do |cmd|
        Beryl::CLI::SessionLog.wanted?(cmd, [] of String, false, false).should be_false
      end
      Beryl::CLI::SessionLog.wanted?("apply", ["--help"], false, false).should be_false
      Beryl::CLI::SessionLog.wanted?("upgrade", ["-h"], false, false).should be_false
    end

    it "laisse l'orchestrateur d'une tâche détachée à son propre journal" do
      Beryl::CLI::SessionLog.wanted?("upgrade", ["aloli.net", "--job=/tmp/j"], false, false).should be_false
      Beryl::CLI::SessionLog.wanted?("upgrade", ["aloli.net", "--job", "/tmp/j"], false, false).should be_false
    end

    it "sans sous-commande : rien" do
      Beryl::CLI::SessionLog.wanted?(nil, [] of String, false, false).should be_false
    end
  end

  describe ".path" do
    now = Time.local(2026, 10, 20, 21, 45, 0)

    it "date, commande et portée" do
      Beryl::CLI::SessionLog.path("apply", ["loulou.aloli.net", "pkg-repo-aloli"], now, "/logs")
        .should eq("/logs/2026-10-20_214500_apply_loulou.aloli.net.log")
    end

    it "saute les options pour trouver la portée" do
      Beryl::CLI::SessionLog.path("upgrade", ["--apply", "aloli.net"], now, "/logs")
        .should eq("/logs/2026-10-20_214500_upgrade_aloli.net.log")
    end

    it "sans portée : date et commande" do
      Beryl::CLI::SessionLog.path("upgrade", ["--status"], now, "/logs")
        .should eq("/logs/2026-10-20_214500_upgrade.log")
    end

    it "neutralise les caractères dangereux dans le nom" do
      Beryl::CLI::SessionLog.path("apply", ["../../etc/x y"], now, "/logs")
        .should eq("/logs/2026-10-20_214500_apply_.._.._etc_x_y.log")
    end
  end

  describe ".script_args" do
    it "BSD et macOS : script -q -a -F journal commande…" do
      Beryl::CLI::SessionLog.script_args("/l.log", ["/bin/beryl", "apply", "x y"], linux: false)
        .should eq(["-q", "-a", "-F", "/l.log", "/bin/beryl", "apply", "x y"])
    end

    it "Linux : commande en une chaîne -c, code de sortie par -e" do
      Beryl::CLI::SessionLog.script_args("/l.log", ["/bin/beryl", "apply", "x y"], linux: true)
        .should eq(["-q", "-a", "-e", "-c", "/bin/beryl apply 'x y'", "/l.log"])
    end
  end
end
