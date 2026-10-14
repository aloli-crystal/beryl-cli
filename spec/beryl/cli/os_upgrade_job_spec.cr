require "file_utils"
require "../../spec_helper"
require "../../../src/beryl/cli/os_upgrade_job"

alias OUJ = Beryl::CLI::OsUpgradeJob

# Faux enfant `beryl os-upgrade <fqdn> --apply …` : comportement selon le fqdn.
#   ok.*      → à jour          upd.*  → mis à jour (rapporté)
#   crash.*   → sort en 1 SANS rien rapporter (plantage) ; la ligne du journal
#               doit remonter dans l'état
FAKE_CHILD = <<-SH
  #!/bin/sh
  shift                       # "os-upgrade"
  host=$1
  w() { printf '{"state":"%s","detail":"%s","updated_at":"2026-10-14T20:00:00Z"}' "$1" "$2" > "$BERYL_JOB_STATE"; }
  case "$host" in
    ok.*)    w "à jour" "aucun correctif en attente" ;;
    upd.*)   sleep 0.2; w "mis à jour" "revenu en 15.1-RELEASE-p5" ;;
    crash.*) echo "pkg: fichier verrouillé"; exit 1 ;;
  esac
  SH

private def with_job_env(&)
  dir = File.tempname("beryl-job")
  Dir.mkdir_p(dir)
  old = ENV["XDG_STATE_HOME"]?
  ENV["XDG_STATE_HOME"] = dir
  child = File.join(dir, "fake-beryl")
  File.write(child, FAKE_CHILD)
  File.chmod(child, 0o755)
  yield [child]
ensure
  old ? (ENV["XDG_STATE_HOME"] = old) : ENV.delete("XDG_STATE_HOME")
  FileUtils.rm_rf(dir) if dir
end

private def states(dir : String, fqdns : Array(String)) : Array(String)
  fqdns.map { |f| OUJ.read_state(OUJ.state_path(dir, f)).not_nil!.state }
end

describe Beryl::CLI::OsUpgradeJob do
  it "canari = premier serveur qui a quelque chose à faire, puis parallèle ; un plantage ne bloque personne" do
    with_job_env do |child|
      hosts = %w[ok.a upd.b crash.c upd.d upd.e]
      dir = OUJ.create("test", hosts, reboot: true, to: nil, parallel: 2)
      rc = OUJ.run(dir, child)
      states(dir, hosts).should eq([OUJ::UPTODATE, OUJ::UPGRADED, OUJ::FAILED, OUJ::UPGRADED, OUJ::UPGRADED])
      rc.should eq(2) # un échec → code non nul
      crash = OUJ.read_state(OUJ.state_path(dir, "crash.c")).not_nil!
      crash.detail.should contain("code 1")
      crash.detail.should contain("pkg: fichier verrouillé") # jamais silencieux
    end
  end

  it "canari en échec → le reste est ANNULÉ, rien d'autre n'est lancé" do
    with_job_env do |child|
      hosts = %w[crash.a upd.b upd.c]
      dir = OUJ.create("test", hosts, reboot: true, to: nil, parallel: 4)
      OUJ.run(dir, child).should eq(2)
      states(dir, hosts).should eq([OUJ::FAILED, OUJ::CANCELLED, OUJ::CANCELLED])
      File.exists?(OUJ.log_path(dir, "upd.b")).should be_false
    end
  end

  it "tous à jour → code 0, aucun canari nécessaire" do
    with_job_env do |child|
      hosts = %w[ok.a ok.b]
      dir = OUJ.create("test", hosts, reboot: false, to: nil, parallel: 4)
      OUJ.run(dir, child).should eq(0)
      states(dir, hosts).should eq([OUJ::UPTODATE, OUJ::UPTODATE])
    end
  end

  it "--status retrouve la dernière tâche et la rapporte terminée" do
    with_job_env do |child|
      dir = OUJ.create("test", %w[upd.a], reboot: true, to: nil, parallel: 1)
      OUJ.run(dir, child)
      OUJ.find(nil).should eq(dir)
      OUJ.load(dir).finished_at.should_not be_nil
      OUJ.status(nil).should eq(0)
    end
  end

  it "résumé lisible" do
    s = [OUJ::HostState.new(OUJ::UPGRADED, ""), OUJ::HostState.new(OUJ::FAILED, ""), OUJ::HostState.new(OUJ::UPGRADED, "")]
    OUJ.summary(s.map(&.as(OUJ::HostState?))).should eq("2 mis à jour · 1 échec")
  end
end
