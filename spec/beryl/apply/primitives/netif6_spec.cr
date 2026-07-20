require "../../../spec_helper"
require "../../../support/fake_shell"

private def params(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = v.is_a?(YAML::Any) ? v : YAML::Any.new(v) }
  res
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::Netif6 do
  it "est enregistrée sous `netif6`" do
    Beryl::Apply::Primitive["netif6"]?.should_not be_nil
  end

  describe ".rc_value / .gateway_scoped" do
    it "rc_value : inet6 <addr> prefixlen <n>" do
      Beryl::Apply::Netif6.rc_value("2001:41d0:250:dd00::1", "64")
        .should eq("inet6 2001:41d0:250:dd00::1 prefixlen 64")
    end

    it "gateway_scoped : link-local scopée %iface, globale inchangée, %déjà-là préservée" do
      Beryl::Apply::Netif6.gateway_scoped("fe80::1", "ice0").should eq("fe80::1%ice0")
      Beryl::Apply::Netif6.gateway_scoped("2001:db8::1", "ice0").should eq("2001:db8::1")
      Beryl::Apply::Netif6.gateway_scoped("fe80::1%em0", "ice0").should eq("fe80::1%em0")
    end
  end

  it "pose l'adresse (alias) + route + persiste rc.conf, sans toucher l'IPv4" do
    sh = FakeShell.new
    sh.stub(/route -n get default/, stdout: "ice0\n")
    sh.stub(/ifconfig ice0 2>\/dev\/null/, stdout: "ice0: flags=...\n") # iface existe
    sh.stub(/ifconfig ice0 inet6/, stdout: "")                          # aucune v6 globale encore
    sh.stub(/netstat -rn -f inet6/, stdout: "")                         # pas de route par défaut v6
    sh.stub(/sysrc -n/, stdout: "")                                     # rc.conf vide
    r = Beryl::Apply::Netif6.new.apply(
      sh, params({"address" => "2001:41d0:250:dd00::1"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    # Process.quote met l'arg sysrc (avec espaces) entre quotes → on matche l'intérieur.
    sh.ran?(/ifconfig_ice0_ipv6=inet6 2001:41d0:250:dd00::1 prefixlen 64/).should be_true
    sh.ran?(/ipv6_defaultrouter=fe80::1%ice0/).should be_true
    sh.ran?(/ifconfig ice0 inet6 2001:41d0:250:dd00::1 prefixlen 64 alias/).should be_true
    sh.ran?(/route -6 add default fe80::1%ice0/).should be_true
    # JAMAIS de restart de l'interface (couperait le v4)
    sh.ran?(/service netif restart|ifconfig ice0 down/).should be_false
  end

  it "idempotent : skip si adresse + route + rc.conf déjà en place" do
    sh = FakeShell.new
    sh.stub(/route -n get default/, stdout: "ice0\n")
    sh.stub(/ifconfig ice0 2>\/dev\/null/, stdout: "ice0: flags=...\n")
    # FakeShell renvoie le stub verbatim (pas d'awk) → sortie POST-awk (l'adresse seule)
    sh.stub(/ifconfig ice0 inet6/, stdout: "2001:41d0:250:dd00::1\n")
    sh.stub(/netstat -rn -f inet6/, stdout: "fe80::1%ice0\n")
    sh.stub(/sysrc -n ifconfig_ice0_ipv6/, stdout: "inet6 2001:41d0:250:dd00::1 prefixlen 64\n")
    sh.stub(/sysrc -n ipv6_defaultrouter/, stdout: "fe80::1%ice0\n")
    r = Beryl::Apply::Netif6.new.apply(
      sh, params({"address" => "2001:41d0:250:dd00::1"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "iface explicite honorée (pas d'auto-détection)" do
    sh = FakeShell.new
    sh.stub(/ifconfig igb0 2>\/dev\/null/, stdout: "igb0: flags=...\n")
    sh.stub(/ifconfig igb0 inet6/, stdout: "")
    sh.stub(/netstat -rn -f inet6/, stdout: "")
    sh.stub(/sysrc -n/, stdout: "")
    r = Beryl::Apply::Netif6.new.apply(
      sh, params({"address" => "2001:db8::1", "iface" => "igb0"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/route -6 add default fe80::1%igb0/).should be_true
  end
end
