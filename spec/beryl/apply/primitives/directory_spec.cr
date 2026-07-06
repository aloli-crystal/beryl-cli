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

describe Beryl::Apply::Directory do
  it "est enregistrée sous `directory`" do
    Beryl::Apply::Primitive["directory"]?.should_not be_nil
  end

  it "norm_mode normalise l'octal (0775 → 775)" do
    Beryl::Apply::Directory.norm_mode("0775").should eq("775")
    Beryl::Apply::Directory.norm_mode("0644").should eq("644")
  end

  it "crée le dossier absent + owner + mode" do
    sh = FakeShell.new
    sh.stub(/test -d/, exit_code: 1)
    sh.stub(/test -e/, exit_code: 1)
    r = Beryl::Apply::Directory.new.apply(
      sh, y({"path" => "/home/platforms", "owner" => "deploy:www", "mode" => "0775"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/mkdir -p .*platforms/).should be_true
    sh.ran?(/chown .*deploy:www/).should be_true
    sh.ran?(/chmod .*0775/).should be_true
  end

  it "skip si déjà conforme" do
    sh = FakeShell.new
    sh.stub(/test -d/, exit_code: 0)
    sh.stub(/stat -f '%Su:%Sg'/, stdout: "deploy:www\n")
    sh.stub(/stat -f '%Lp'/, stdout: "775\n")
    r = Beryl::Apply::Directory.new.apply(
      sh, y({"path" => "/home/platforms", "owner" => "deploy:www", "mode" => "0775"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "refuse un chemin occupé par un non-dossier" do
    sh = FakeShell.new
    sh.stub(/test -d/, exit_code: 1)
    sh.stub(/test -e/, exit_code: 0)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /pas un dossier/) do
      Beryl::Apply::Directory.new.apply(sh, y({"path" => "/etc/hosts"}), false, ctx)
    end
  end
end
