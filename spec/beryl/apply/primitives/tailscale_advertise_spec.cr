require "../../../spec_helper"
require "../../../support/fake_shell"

private def p(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = v.is_a?(YAML::Any) ? v : YAML::Any.new(v) }
  res
end

private def dom(list : Array(String)) : YAML::Any
  YAML::Any.new(list.map { |d| YAML::Any.new(d) })
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::TailscaleAdvertise do
  it "est enregistrée sous `tailscale-advertise`" do
    Beryl::Apply::Primitive["tailscale-advertise"]?.should_not be_nil
  end

  it "lève si ni exit_node ni routes" do
    sh = FakeShell.new
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /exit_node.*routes|routes/) do
      Beryl::Apply::TailscaleAdvertise.new.apply(sh, p({} of String => YAML::Any), false, ctx)
    end
  end

  it "échoue proprement si tailscaled non connecté" do
    sh = FakeShell.new
    sh.stub(/tailscale status --json/, exit_code: 1)
    r = Beryl::Apply::TailscaleAdvertise.new.apply(sh, p({"exit_node" => true}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end

  it "exit-node : advertise-exit-node quand pas déjà annoncé" do
    sh = FakeShell.new
    sh.stub(/tailscale status --json/, exit_code: 0)
    sh.stub(/tailscale debug prefs/, stdout: %({"AdvertiseRoutes":null}))
    r = Beryl::Apply::TailscaleAdvertise.new.apply(sh, p({"exit_node" => true}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/tailscale set --advertise-exit-node/).should be_true
  end

  it "idempotent : skip si les routes par défaut sont déjà annoncées (exit-node)" do
    sh = FakeShell.new
    sh.stub(/tailscale status --json/, exit_code: 0)
    sh.stub(/tailscale debug prefs/, stdout: %({"AdvertiseRoutes":["0.0.0.0/0","::/0"]}))
    r = Beryl::Apply::TailscaleAdvertise.new.apply(sh, p({"exit_node" => true}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "subnet-router : advertise-routes avec les CIDR" do
    sh = FakeShell.new
    sh.stub(/tailscale status --json/, exit_code: 0)
    sh.stub(/tailscale debug prefs/, stdout: %({"AdvertiseRoutes":null}))
    r = Beryl::Apply::TailscaleAdvertise.new.apply(
      sh, p({"routes" => dom(["192.168.1.0/24", "10.0.0.0/24"])}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/tailscale set --advertise-routes=192.168.1.0\/24,10.0.0.0\/24/).should be_true
  end
end
