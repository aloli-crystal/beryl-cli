require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::FileAbsent do
  it "skip si le fichier est déjà absent" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 1)
    r = prim("file-absent").apply(shell, apply_params({path: "/etc/x.conf"}.to_yaml), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/rm -f/).should be_false
  end

  it "supprime un fichier présent" do
    shell = FakeShell.new
    shell.stub(/test -d/, exit_code: 1)
    r = prim("file-absent").apply(shell, apply_params({path: "/etc/x.conf"}.to_yaml), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{rm -f /etc/x.conf}).should be_true
  end

  it "refuse un dossier" do
    shell = FakeShell.new
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /dossier/) do
      prim("file-absent").apply(shell, apply_params({path: "/etc"}.to_yaml), dry_run: false, context: ctx)
    end
  end
end
