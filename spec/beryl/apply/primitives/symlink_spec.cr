require "../../../spec_helper"
require "../../../support/fake_shell"

private def y(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = YAML::Any.new(v) }
  res
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::Symlink do
  it "est enregistrée sous `symlink`" do
    Beryl::Apply::Primitive["symlink"]?.should_not be_nil
  end

  it "crée le lien absent (+ owner)" do
    sh = FakeShell.new
    sh.stub(/test -L/, exit_code: 1)
    sh.stub(/test -e/, exit_code: 1)
    r = Beryl::Apply::Symlink.new.apply(
      sh, y({"path" => "/home/v/shared/platforms", "target" => "/home/platforms", "owner" => "deploy:www"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/ln -sfh .*home\/platforms.* .*shared\/platforms/).should be_true
    sh.ran?(/chown -h .*deploy:www/).should be_true
  end

  it "skip si le lien pointe déjà au bon endroit" do
    sh = FakeShell.new
    sh.stub(/test -L/, exit_code: 0)
    sh.stub(/readlink/, stdout: "/home/platforms\n")
    r = Beryl::Apply::Symlink.new.apply(
      sh, y({"path" => "/home/v/shared/platforms", "target" => "/home/platforms"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "refuse de remplacer un vrai dossier/fichier" do
    sh = FakeShell.new
    sh.stub(/test -L/, exit_code: 1)
    sh.stub(/test -e/, exit_code: 0)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /pas un lien/) do
      Beryl::Apply::Symlink.new.apply(sh, y({"path" => "/home/real", "target" => "/x"}), false, ctx)
    end
  end
end
