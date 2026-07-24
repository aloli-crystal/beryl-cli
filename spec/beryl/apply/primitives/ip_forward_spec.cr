require "../../../spec_helper"
require "../../../support/fake_shell"

private def p(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = v.is_a?(YAML::Any) ? v : YAML::Any.new(v) }
  res
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::IpForward do
  it "est enregistrée sous `ip-forward`" do
    Beryl::Apply::Primitive["ip-forward"]?.should_not be_nil
  end

  describe ".knobs" do
    it "v4 seul vs v4+v6" do
      Beryl::Apply::IpForward.knobs(false).should eq([{"gateway_enable", "net.inet.ip.forwarding"}])
      Beryl::Apply::IpForward.knobs(true).map(&.[](0)).should eq(["gateway_enable", "ipv6_gateway_enable"])
    end
  end

  it "active v4+v6 : sysrc (persist) + sysctl (immédiat)" do
    sh = FakeShell.new
    sh.stub(/sysrc -n/, stdout: "NO\n") # rien d'activé
    sh.stub(/sysctl -n/, stdout: "0\n")
    r = Beryl::Apply::IpForward.new.apply(sh, p({} of String => YAML::Any), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/sysrc gateway_enable=YES/).should be_true
    sh.ran?(/sysrc ipv6_gateway_enable=YES/).should be_true
    sh.ran?(/sysctl net.inet.ip.forwarding=1/).should be_true
    sh.ran?(/sysctl net.inet6.ip6.forwarding=1/).should be_true
  end

  it "idempotent : skip si déjà actif (sysrc YES + sysctl 1)" do
    sh = FakeShell.new
    sh.stub(/sysrc -n/, stdout: "YES\n")
    sh.stub(/sysctl -n/, stdout: "1\n")
    r = Beryl::Apply::IpForward.new.apply(sh, p({} of String => YAML::Any), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "ipv6:false → ne touche que l'IPv4" do
    sh = FakeShell.new
    sh.stub(/sysrc -n/, stdout: "NO\n")
    sh.stub(/sysctl -n/, stdout: "0\n")
    r = Beryl::Apply::IpForward.new.apply(sh, p({"ipv6" => false}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/sysrc gateway_enable=YES/).should be_true
    sh.ran?(/ipv6_gateway_enable/).should be_false
  end
end
