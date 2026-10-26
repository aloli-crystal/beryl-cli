require "../../spec_helper"
require "../../../src/beryl/cli/session_log"

describe Beryl::CLI::SessionLog do
  describe ".strip_flag" do
    it "retire --no-log où qu'il soit" do
      Beryl::CLI::SessionLog.strip_flag(["sync", "loulou", "--no-log", "--apply"]).should eq({["sync", "loulou", "--apply"], true})
      Beryl::CLI::SessionLog.strip_flag(["--no-log", "-c", "/x", "upgrade"]).should eq({["-c", "/x", "upgrade"], true})
    end

    it "laisse argv tel quel sans le drapeau" do
      Beryl::CLI::SessionLog.strip_flag(["upgrade", "aloli.net"]).should eq({["upgrade", "aloli.net"], false})
    end
  end

  describe ".wanted?" do
    it "journalise par défaut les commandes du parc" do
      Beryl::CLI::SessionLog.wanted?("sync", ["loulou"], false, false).should be_true
      Beryl::CLI::SessionLog.wanted?("os-upgrade", ["aloli.net", "--apply"], false, false).should be_true
    end

    it "respecte --no-log" do
      Beryl::CLI::SessionLog.wanted?("sync", ["loulou"], true, false).should be_false
    end

    it "ne relance pas un enfant déjà sous journal" do
      Beryl::CLI::SessionLog.wanted?("sync", ["loulou"], false, true).should be_false
    end

    it "ne journalise ni l'aide ni la saisie de secrets" do
      %w[env init add-provider add-domain help version show list-hosts fmt].each do |cmd|
        Beryl::CLI::SessionLog.wanted?(cmd, [] of String, false, false).should be_false
      end
      Beryl::CLI::SessionLog.wanted?("sync", ["--help"], false, false).should be_false
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

    it "date, heure, commande en essai à blanc et portée" do
      Beryl::CLI::SessionLog.path("sync", ["loulou.aloli.net", "pkg-repo-aloli"], now, "/logs")
        .should eq("/logs/2026-10-20--21-45-00--sync-dry-run--loulou.aloli.net.log")
    end

    it "commande qui agit : sans dry-run ; la portée saute les options" do
      Beryl::CLI::SessionLog.path("upgrade", ["--apply", "aloli.net"], now, "/logs")
        .should eq("/logs/2026-10-20--21-45-00--upgrade--aloli.net.log")
    end

    it "sans portée : date, heure et commande" do
      Beryl::CLI::SessionLog.path("upgrade", ["--status"], now, "/logs")
        .should eq("/logs/2026-10-20--21-45-00--upgrade-status.log")
    end

    it "neutralise les caractères dangereux dans le nom" do
      Beryl::CLI::SessionLog.path("sync", ["../../etc/x y", "--apply"], now, "/logs")
        .should eq("/logs/2026-10-20--21-45-00--sync--.._.._etc_x_y.log")
    end
  end

  describe ".label" do
    it "essai à blanc par défaut des commandes à --apply" do
      %w[sync upgrade os-upgrade wipe bootstrap rescue scan].each do |cmd|
        Beryl::CLI::SessionLog.label(cmd, ["x"]).should eq("#{cmd}-dry-run")
      end
    end

    it "--apply : le nom seul" do
      Beryl::CLI::SessionLog.label("os-upgrade", ["aloli.net", "--apply"]).should eq("os-upgrade")
    end

    it "scan -W / --write-to implique --apply" do
      Beryl::CLI::SessionLog.label("scan", ["loulou", "-W", "/x.yml"]).should eq("scan")
      Beryl::CLI::SessionLog.label("scan", ["loulou", "--write-to=/x.yml"]).should eq("scan")
    end

    it "--status : lecture de l'état d'une tâche" do
      Beryl::CLI::SessionLog.label("upgrade", ["--status"]).should eq("upgrade-status")
    end

    it "monitoring : dry-run seulement avec on/off sans --apply" do
      Beryl::CLI::SessionLog.label("monitoring", ["quimeo"]).should eq("monitoring")
      Beryl::CLI::SessionLog.label("monitoring", ["quimeo", "off"]).should eq("monitoring-dry-run")
      Beryl::CLI::SessionLog.label("monitoring", ["quimeo", "off", "--apply"]).should eq("monitoring")
    end

    it "vrack : dry-run seulement pour un rôle imposé sans --apply" do
      Beryl::CLI::SessionLog.label("vrack", ["be"]).should eq("vrack")
      Beryl::CLI::SessionLog.label("vrack", ["be", "--attach"]).should eq("vrack-dry-run")
      Beryl::CLI::SessionLog.label("vrack", ["be", "--attach", "--apply"]).should eq("vrack")
      Beryl::CLI::SessionLog.label("vrack", ["be", "--via=zgra"]).should eq("vrack-dry-run")
      Beryl::CLI::SessionLog.label("vrack", ["be", "--public", "--apply"]).should eq("vrack")
    end

    it "commande sans --apply : son nom" do
      Beryl::CLI::SessionLog.label("update", ["aloli.net"]).should eq("update")
      Beryl::CLI::SessionLog.label("info", ["loulou"]).should eq("info")
    end
  end

  describe ".config" do
    it "réglages du shard session-log : BERYL_SESSION_LOG (lue par log_step), 90 jours" do
      c = Beryl::CLI::SessionLog.config("/logs")
      c.app.should eq("beryl")
      c.env_var.should eq("BERYL_SESSION_LOG")
      c.keep_days.should eq(90)
      c.dir.should eq("/logs")
    end
  end
end
