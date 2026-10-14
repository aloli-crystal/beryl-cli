require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::Command do
  it "saute l'étape quand if_set est vide" do
    shell = FakeShell.new
    r = prim("command").apply(shell, apply_params("run: x\nunless: y\nif_set: \"\"\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.commands.should be_empty
  end

  it "exige une garde" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /unless/) do
      prim("command").apply(FakeShell.new, apply_params("run: x\n"), dry_run: false, context: ctx)
    end
  end

  it "saute si la garde réussit" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 0)
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/do-it/).should be_false
  end

  it "lance sous l'utilisateur, avec l'environnement, et montre la sortie" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1)
    shell.stub(/do-it/, stdout: "Invitation : https://x/i/abc\n")
    yaml = "run: do-it\nunless: check-done\nuser: app\nenv_file: /usr/local/etc/app/app.env\nshow_output: true\n"
    r = prim("command").apply(shell, apply_params(yaml), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("https://x/i/abc")
    cmd = shell.commands.find! { |c| c.includes?("do-it") }
    cmd.should start_with("su -m app -c ")
    cmd.should contain("/usr/local/etc/app/app.env")
  end

  it "ne lance rien en dry-run (garde seulement)" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1)
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.commands.size.should eq(1)
  end

  it "rapporte l'échec avec la sortie" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1)
    shell.stub(/do-it/, exit_code: 1, stderr: "amorçage refusé.")
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    r.message.should contain("amorçage refusé")
  end
end
