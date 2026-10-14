require "file_utils"
require "../../spec_helper"
require "../../../src/beryl/cli/fleet_job"

alias OUJ = Beryl::CLI::FleetJob

# Faux enfant `beryl os-upgrade <fqdn> --apply …` : comportement selon le fqdn.
#   ok.*      → à jour          upd.*  → mis à jour (rapporté)
#   crash.*   → sort en 1 SANS rien rapporter (plantage) ; la ligne du journal
#               doit remonter dans l'état
#   fail.*    → échec APRÈS modification (touched) : invalide le canari
#   pre.*     → échec AVANT toute modification (pas de cible…) : ne l'invalide pas
FAKE_CHILD = <<-SH
  #!/bin/sh
  shift                       # "os-upgrade"
  host=$1
  w() { printf '{"state":"%s","detail":"%s","updated_at":"2026-10-14T20:00:00Z","touched":%s}' "$1" "$2" "${3:-false}" > "$BERYL_JOB_STATE"; }
  case "$host" in
    ok.*)    w "à jour" "aucun correctif en attente" ;;
    upd.*)   sleep 0.2; w "mis à jour" "revenu en 15.1-RELEASE-p5" ;;
    crash.*) echo "pkg: fichier verrouillé"; exit 1 ;;
    fail.*)  w "échec" "pas revenu en SSH après redémarrage" true; exit 2 ;;
    pre.*)   w "échec" "15.0-RELEASE : pas de release cible"; exit 1 ;;
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

describe Beryl::CLI::FleetJob do
  it "canari = premier serveur qui a quelque chose à faire, puis parallèle ; un plantage ne bloque personne" do
    with_job_env do |child|
      hosts = %w[ok.a upd.b crash.c upd.d upd.e]
      dir = OUJ.create("os-upgrade", "test", hosts, ["--apply"], 2)
      rc = OUJ.run(dir, child)
      states(dir, hosts).should eq([OUJ::UPTODATE, OUJ::UPGRADED, OUJ::FAILED, OUJ::UPGRADED, OUJ::UPGRADED])
      rc.should eq(2) # un échec → code non nul
      crash = OUJ.read_state(OUJ.state_path(dir, "crash.c")).not_nil!
      crash.detail.should contain("code 1")
      crash.detail.should contain("pkg: fichier verrouillé") # jamais silencieux
    end
  end

  it "canari en échec APRÈS modification → le reste est ANNULÉ, rien d'autre n'est lancé" do
    with_job_env do |child|
      hosts = %w[fail.a upd.b upd.c]
      dir = OUJ.create("os-upgrade", "test", hosts, ["--apply"], 4)
      OUJ.run(dir, child).should eq(2)
      states(dir, hosts).should eq([OUJ::FAILED, OUJ::CANCELLED, OUJ::CANCELLED])
      File.exists?(OUJ.log_path(dir, "upd.b")).should be_false
    end
  end

  it "échec AVANT toute modification (pas de cible, plantage précoce) → n'annule rien, le canari passe au suivant" do
    with_job_env do |child|
      hosts = %w[pre.a crash.b upd.c upd.d]
      dir = OUJ.create("os-upgrade", "test", hosts, ["--apply"], 4)
      OUJ.run(dir, child).should eq(2) # échecs visibles → code non nul
      states(dir, hosts).should eq([OUJ::FAILED, OUJ::FAILED, OUJ::UPGRADED, OUJ::UPGRADED])
      OUJ.read_state(OUJ.state_path(dir, "pre.a")).not_nil!.detail.should contain("pas de release cible")
    end
  end

  it "tous à jour → code 0, aucun canari nécessaire" do
    with_job_env do |child|
      hosts = %w[ok.a ok.b]
      dir = OUJ.create("os-upgrade", "test", hosts, ["--apply"], 4)
      OUJ.run(dir, child).should eq(0)
      states(dir, hosts).should eq([OUJ::UPTODATE, OUJ::UPTODATE])
    end
  end

  it "--status retrouve la dernière tâche et la rapporte terminée" do
    with_job_env do |child|
      dir = OUJ.create("os-upgrade", "test", %w[upd.a], ["--apply"], 1)
      OUJ.run(dir, child)
      OUJ.find("os-upgrade", nil).should eq(dir)
      OUJ.load(dir).finished_at.should_not be_nil
      OUJ.status("os-upgrade", nil).should eq(0)
    end
  end

  it "résumé lisible" do
    s = [OUJ::HostState.new(OUJ::UPGRADED, ""), OUJ::HostState.new(OUJ::FAILED, ""), OUJ::HostState.new(OUJ::UPGRADED, "")]
    OUJ.summary(s.map(&.as(OUJ::HostState?))).should eq("2 mis à jour · 1 échec")
  end
end

describe "Beryl::CLI::FleetJob pour `upgrade`" do
  it "l'enfant reçoit `upgrade <fqdn> <options>` et l'état est rangé sous jobs/upgrade" do
    dir0 = File.tempname("beryl-job-up")
    Dir.mkdir_p(dir0)
    old = ENV["XDG_STATE_HOME"]?
    ENV["XDG_STATE_HOME"] = dir0
    child = File.join(dir0, "fake")
    File.write(child, "#!/bin/sh\nprintf '{\"state\":\"mis à jour\",\"detail\":\"%s\",\"updated_at\":\"2026-10-14T20:00:00Z\"}' \"$*\" > \"$BERYL_JOB_STATE\"\n")
    File.chmod(child, 0o755)
    dir = OUJ.create("upgrade", "aloli", %w[a.test], ["--apply", "--no-restart"], 2)
    dir.should contain("/jobs/upgrade/")
    OUJ.run(dir, [child]).should eq(0)
    OUJ.read_state(OUJ.state_path(dir, "a.test")).not_nil!.detail.should eq("upgrade a.test --apply --no-restart")
  ensure
    old ? (ENV["XDG_STATE_HOME"] = old) : ENV.delete("XDG_STATE_HOME")
    FileUtils.rm_rf(dir0) if dir0
  end
end

describe "Beryl::CLI::FleetJob, groupes de redémarrage" do
  it "next_runnable saute un serveur dont le groupe est occupé" do
    groups = {"b1" => "bastions", "b2" => "bastions", "o1" => nil}.transform_values(&.as(String?))
    OUJ.next_runnable(%w[b2 o1], groups, Set{"bastions"}).should eq("o1")
    OUJ.next_runnable(%w[b2], groups, Set{"bastions"}).should be_nil
    OUJ.next_runnable(%w[b2 o1], groups, Set(String).new).should eq("b2")
  end

  it "jamais deux bastions à la fois, les autres en parallèle" do
    dir0 = File.tempname("beryl-job-grp")
    Dir.mkdir_p(dir0)
    old = ENV["XDG_STATE_HOME"]?
    ENV["XDG_STATE_HOME"] = dir0
    trace = File.join(dir0, "trace")
    ENV["BERYL_TRACE"] = trace
    child = File.join(dir0, "fake")
    File.write(child, <<-SH)
      #!/bin/sh
      shift
      echo "START $1" >> "$BERYL_TRACE"
      sleep 0.3
      echo "END $1" >> "$BERYL_TRACE"
      printf '{"state":"mis à jour","detail":"ok","updated_at":"2026-10-14T20:00:00Z","touched":true}' > "$BERYL_JOB_STATE"
      SH
    File.chmod(child, 0o755)
    hosts = %w[c0 b1 b2 b3 o1 o2]
    groups = {"b1" => "bastions", "b2" => "bastions", "b3" => "bastions"}
    dir = OUJ.create("os-upgrade", "test", hosts, ["--apply", "--reboot"], 4, groups)
    OUJ.run(dir, [child]).should eq(0)

    active = Set(String).new
    max_bastions = 0
    max_total = 0
    File.read_lines(trace).each do |l|
      ev, h = l.split
      ev == "START" ? active << h : active.delete(h)
      max_bastions = {max_bastions, active.count(&.starts_with?("b"))}.max
      max_total = {max_total, active.size}.max
    end
    max_bastions.should eq(1) # jamais deux bastions ensemble
    max_total.should be > 1   # mais du parallèle pour les autres
    OUJ.load(dir).hosts.find! { |h| h.fqdn == "b2" }.group.should eq("bastions")
  ensure
    ENV.delete("BERYL_TRACE")
    old ? (ENV["XDG_STATE_HOME"] = old) : ENV.delete("XDG_STATE_HOME")
    FileUtils.rm_rf(dir0) if dir0
  end
end

describe "Beryl::CLI::FleetJob, courriel récapitulatif" do
  it "objet et corps : société, sous-commande, résumé, ligne par serveur, groupe" do
    job = OUJ::Job.new("20261014-223206", "os-upgrade", "quimeo", Time.utc, ["--apply", "--reboot"], 4,
      [OUJ::HostRef.new("han.quimeo.net"), OUJ::HostRef.new("zgra.quimeo.net", "bastions")], "quimeo", "/cfg")
    states = [OUJ::HostState.new(OUJ::UPGRADED, "revenu en 15.1-RELEASE-p5"),
              OUJ::HostState.new(OUJ::FAILED, "pas revenu en SSH après redémarrage")].map(&.as(OUJ::HostState?))
    subject, body = OUJ.compose(job, states)
    subject.should eq("[beryl][quimeo] os-upgrade quimeo : 1 mis à jour · 1 échec")
    body.should contain("han.quimeo.net   mis à jour   revenu en 15.1-RELEASE-p5")
    body.should contain("[bastions] pas revenu en SSH après redémarrage")
    body.should contain("beryl os-upgrade --status 20261014-223206")
  end
end

describe "Beryl::CLI::FleetJob, résultat du courriel enregistré" do
  it "l'échec d'envoi est SAUVÉ dans la tâche et affiché par --status (Job est une classe, pas une copie)" do
    with_job_env do |child|
      OUJ.notify = true
      dir = OUJ.create("os-upgrade", "test", %w[upd.a], ["--apply"], 1)
      OUJ.run(dir, child)
      OUJ.load(dir).mail_error.should eq("société inconnue pour cette tâche")
      OUJ.load(dir).finished_at.should_not be_nil
    ensure
      OUJ.notify = nil
    end
  end

  it "pas de courriel quand la décision est « console »" do
    with_job_env do |child|
      OUJ.notify = false
      dir = OUJ.create("os-upgrade", "test", %w[upd.a], ["--apply"], 1)
      OUJ.run(dir, child)
      job = OUJ.load(dir)
      job.mail_error.should be_nil
      job.mailed_to.should be_nil
    ensure
      OUJ.notify = nil
    end
  end
end
