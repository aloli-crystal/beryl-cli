require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::AutoCloseCancel do
  it "annule le job at du tag (atrm + suppression du fichier de tag)" do
    shell = FakeShell.new
    shell.stub(/cat .*atjob/, stdout: "42\n", exit_code: 0) # job 42 existe
    shell.stub(/atrm 42/, exit_code: 0)
    shell.stub(/rm -f/, exit_code: 0)

    result = prim("auto-close-cancel").apply(
      shell,
      apply_params(%({tag: sshd-overlay-deadman})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/atrm 42/).should be_true
    shell.ran?(/rm -f .*sshd-overlay-deadman/).should be_true
  end

  it "skip (sans erreur) si aucun job ne porte ce tag" do
    shell = FakeShell.new
    shell.stub(/cat .*atjob/, stdout: "", exit_code: 1) # pas de job

    result = prim("auto-close-cancel").apply(
      shell,
      apply_params(%({tag: sshd-overlay-deadman})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/atrm/).should be_false
  end

  it "dry-run : n'exécute rien de destructif" do
    shell = FakeShell.new
    result = prim("auto-close-cancel").apply(
      shell,
      apply_params(%({tag: sshd-overlay-deadman})),
      dry_run: true, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/atrm/).should be_false
  end
end
