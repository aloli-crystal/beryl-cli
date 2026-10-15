require "../../spec_helper"
require "../../support/fake_shell"
require "../../../src/beryl/cli/build_status"

private def failed_remote : String
  <<-OUT
    @@NOW 2000
    @@FILE .beryl-build-15.log 1900 100
    @@FILE .beryl-build-15.overlays 1000 20
    @@BEGIN .beryl-build-15.overlays
    maison 2c8175fc1bca02ea902de27d492c0e017d546b9a
    @@BEGIN .beryl-build-15.log.events
    [00:00:01] Logs: /logs/bulk/fbsd151amd64-default/B1
    [00:01:00] [01] [00:00:50] Finished   www/site | site-1: Failed: configure
    @@BEGIN poudriere-status
    @@END
    OUT
end

describe Beryl::CLI::BuildStatus do
  describe ".show" do
    it "UNE commande de lecture (script composé), rendu texte, code 1 si le dernier build a échoué" do
      shell = FakeShell.new
      shell.stub(/@@NOW/, stdout: failed_remote)
      io = IO::Memory.new
      code, reports = Beryl::CLI::BuildStatus.show(shell, "pkg.example.net", "/pk", nil, false, "duration", false, io)
      code.should eq(1)
      reports.map(&.major).should eq(["15"])
      shell.commands.size.should eq(1)
      shell.commands.first.should contain("poudriere status -H -f -l")
      shell.writes.should be_empty
      io.to_s.should contain("ÉCHEC")
      io.to_s.should contain("journal : /logs/bulk/fbsd151amd64-default/B1/logs/errors/site-1.log")
    end

    it "--major restreint la lecture ; jamais construit → code 0" do
      shell = FakeShell.new
      shell.stub(/@@NOW/, stdout: "@@NOW 1\n@@BEGIN poudriere-status\n@@END\n")
      io = IO::Memory.new
      code, _ = Beryl::CLI::BuildStatus.show(shell, "h", "/pk", "16", false, "duration", false, io)
      code.should eq(0)
      shell.commands.first.should contain(".beryl-build-16.lock")
      io.to_s.should contain("Majeur 16 — jamais construit")
    end

    it "--json : sortie machine" do
      shell = FakeShell.new
      shell.stub(/@@NOW/, stdout: failed_remote)
      io = IO::Memory.new
      code, _ = Beryl::CLI::BuildStatus.show(shell, "h", "/pk", nil, false, "duration", true, io)
      code.should eq(1)
      JSON.parse(io.to_s)["majors"][0]["state"].should eq("failed")
    end

    it "répertoire des paquets absent → code 2" do
      shell = FakeShell.new
      shell.stub(/@@NOW/, stdout: "@@NOPKGDIR\n")
      code, _ = Beryl::CLI::BuildStatus.show(shell, "h", "/absent", nil, false, "duration", false, IO::Memory.new)
      code.should eq(2)
    end

    it "lecture SSH en échec sans sortie → code 2" do
      shell = FakeShell.new
      shell.stub(/@@NOW/, exit_code: 255, stderr: "Connection refused")
      code, _ = Beryl::CLI::BuildStatus.show(shell, "h", "/pk", nil, false, "duration", false, IO::Memory.new)
      code.should eq(2)
    end
  end

  describe ".run" do
    it "usage : hôte absent, --major ou --sort invalides → 2" do
      Beryl::CLI::BuildStatus.run("/nonexistent", [] of String).should eq(2)
      Beryl::CLI::BuildStatus.run("/nonexistent", ["h", "--major=quinze"]).should eq(2)
      Beryl::CLI::BuildStatus.run("/nonexistent", ["h", "--sort=taille"]).should eq(2)
    end
  end
end
