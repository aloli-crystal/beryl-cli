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
    sh.stub(/if \[ -d/, stdout: "absent\n\n")
    r = Beryl::Apply::Directory.new.apply(
      sh, y({"path" => "/home/platforms", "owner" => "deploy:www", "mode" => "0775"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/mkdir -p .*platforms/).should be_true
    sh.ran?(/chown .*deploy:www/).should be_true
    sh.ran?(/chmod .*0775/).should be_true
  end

  it "skip si déjà conforme" do
    sh = FakeShell.new
    sh.stub(/if \[ -d/, stdout: "dir\n775 deploy:www\n")
    r = Beryl::Apply::Directory.new.apply(
      sh, y({"path" => "/home/platforms", "owner" => "deploy:www", "mode" => "0775"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "owner sans groupe : compare le seul propriétaire (pas de chown à chaque passage)" do
    sh = FakeShell.new
    sh.stub(/if \[ -d/, stdout: "dir\n700 postgres:postgres\n")
    r = Beryl::Apply::Directory.new.apply(
      sh, y({"path" => "/home/backups", "owner" => "postgres", "mode" => "0700"}), true, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "owner sans groupe : chown si le propriétaire diffère" do
    sh = FakeShell.new
    sh.stub(/if \[ -d/, stdout: "dir\n755 root:wheel\n")
    r = Beryl::Apply::Directory.new.apply(sh, y({"path" => "/home/backups", "owner" => "postgres"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/chown .*postgres .*backups/).should be_true
  end

  it "refuse un chemin occupé par un non-dossier" do
    sh = FakeShell.new
    sh.stub(/if \[ -d/, stdout: "other\n644 root:wheel\n")
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /pas un dossier/) do
      Beryl::Apply::Directory.new.apply(sh, y({"path" => "/etc/hosts"}), false, ctx)
    end
  end
end
