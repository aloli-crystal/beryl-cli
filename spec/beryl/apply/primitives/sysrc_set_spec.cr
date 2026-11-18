require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::SysrcSet do
  it "pose la variable si différente" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    result = prim("sysrc-set").apply(shell, apply_params(%({key: clear_tmp_enable, value: "YES"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc clear_tmp_enable=YES/).should be_true
  end

  it "skip si déjà à la valeur cible" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "YES")
    result = prim("sysrc-set").apply(shell, apply_params(%({key: clear_tmp_enable, value: "YES"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "gère une variable non posée (exit non nul)" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, exit_code: 1)
    result = prim("sysrc-set").apply(shell, apply_params(%({key: dumpdev, value: "NO"})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc dumpdev=NO/).should be_true
  end

  it "if_set vide : étape sautée, rien posé" do
    shell = FakeShell.new
    result = prim("sysrc-set").apply(shell, apply_params(%({key: postgresql_data, value: "", if_set: ""})), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.commands.should be_empty
  end
end
