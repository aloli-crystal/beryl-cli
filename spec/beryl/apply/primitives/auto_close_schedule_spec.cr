require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::AutoCloseSchedule do
  it "pose un job at et l'enregistre dans /var/run/beryl/auto-close" do
    shell = FakeShell.new
    shell.stub(/mkdir -p/, exit_code: 0)
    shell.stub(/cat .*atjob/, exit_code: 1) # pas de job existant
    shell.stub(/echo .* | at now/, stdout: "", stderr: "job 42 at Tue Jan  1 10:00:00 2030", exit_code: 0)
    shell.stub(/printf/, exit_code: 0)

    result = prim("auto-close-schedule").apply(
      shell,
      apply_params(%({tag: sshd-public-window, after_hours: 1, recipe: sshd-public-close})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/at now \+ 1 hours/).should be_true
    shell.ran?(/beryl apply --recipe sshd-public-close/).should be_true
  end

  it "supporte after_minutes (granularité fine, ex. dead-man's-switch)" do
    shell = FakeShell.new
    shell.stub(/mkdir -p/, exit_code: 0)
    shell.stub(/cat .*atjob/, exit_code: 1)
    shell.stub(/echo .* | at now/, stdout: "", stderr: "job 7 at soon", exit_code: 0)
    shell.stub(/printf/, exit_code: 0)

    result = prim("auto-close-schedule").apply(
      shell,
      apply_params(%({tag: sshd-overlay-deadman, after_minutes: 2, recipe: sshd-overlay-rollback})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/at now \+ 2 minutes/).should be_true
    shell.ran?(/at now \+ .* hours/).should be_false
  end

  it "supprime le job précédent du même tag avant d'en poser un nouveau" do
    shell = FakeShell.new
    shell.stub(/mkdir -p/, exit_code: 0)
    shell.stub(/cat .*atjob/, stdout: "17\n", exit_code: 0) # job 17 existait
    shell.stub(/atrm 17/, exit_code: 0)
    shell.stub(/echo .* | at now/, stdout: "", stderr: "job 99 at later", exit_code: 0)
    shell.stub(/printf/, exit_code: 0)

    prim("auto-close-schedule").apply(
      shell,
      apply_params(%({tag: sshd-public-window, after_hours: 1, recipe: sshd-public-close})),
      dry_run: false, context: ctx,
    )
    shell.ran?(/atrm 17/).should be_true
  end

  it "fail si at submit retourne une erreur" do
    shell = FakeShell.new
    shell.stub(/mkdir -p/, exit_code: 0)
    shell.stub(/cat .*atjob/, exit_code: 1)
    shell.stub(/echo .* | at now/, stderr: "at: command not found", exit_code: 127)

    result = prim("auto-close-schedule").apply(
      shell,
      apply_params(%({tag: sshd-public-window, after_hours: 1, recipe: sshd-public-close})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end
end
