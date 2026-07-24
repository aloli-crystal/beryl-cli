require "../../../spec_helper"
require "../../../support/fake_shell"

private def p(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = v.is_a?(YAML::Any) ? v : YAML::Any.new(v) }
  res
end

private def peers_yaml(list) : YAML::Any
  YAML::Any.new(list.map { |m|
    inner = {} of YAML::Any => YAML::Any
    m.each { |k, v| inner[YAML::Any.new(k)] = YAML::Any.new(v) }
    YAML::Any.new(inner)
  })
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::WireguardInterface do
  it "est enregistrée sous `wireguard-interface`" do
    Beryl::Apply::Primitive["wireguard-interface"]?.should_not be_nil
  end

  describe ".build_conf" do
    it "produit un conf wg-quick avec Interface + un bloc Peer par pair" do
      conf = Beryl::Apply::WireguardInterface.build_conf(
        "10.100.0.1/24", "51820", "PRIVKEY==",
        [{"name" => "iphone", "public_key" => "PUB1=", "allowed_ips" => "10.100.0.2/32"}])
      conf.should contain("[Interface]")
      conf.should contain("Address = 10.100.0.1/24")
      conf.should contain("ListenPort = 51820")
      conf.should contain("PrivateKey = PRIVKEY==")
      conf.should contain("# iphone")
      conf.should contain("[Peer]")
      conf.should contain("PublicKey = PUB1=")
      conf.should contain("AllowedIPs = 10.100.0.2/32")
    end
  end

  it "lève si la clé privée (coffre) est absente" do
    ENV.delete("WG_ABSENT")
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /clé privée|coffre/) do
      Beryl::Apply::WireguardInterface.new.apply(
        FakeShell.new, p({"address" => "10.100.0.1/24", "private_key_env" => "WG_ABSENT"}), false, ctx)
    end
  end

  it "écrit la conf 0600 + sysrc enable + démarre quand rien n'est en place" do
    ENV["WG_TEST_PK"] = "SECRETKEY=="
    sh = FakeShell.new
    sh.stub(/cat .*wg0\.conf/, stdout: "") # pas de conf
    sh.stub(/ifconfig wg0/, exit_code: 1)  # iface absente
    sh.stub(/sysrc -n wireguard_interfaces/, stdout: "")
    sh.stub(/sysrc -n wireguard_enable/, stdout: "NO\n")
    r = Beryl::Apply::WireguardInterface.new.apply(
      sh, p({"address" => "10.100.0.1/24", "private_key_env" => "WG_TEST_PK",
             "peers" => peers_yaml([{"public_key" => "PUB=", "allowed_ips" => "10.100.0.2/32"}])}),
      false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.writes.any? { |w| w.path == "/usr/local/etc/wireguard/wg0.conf" && w.content.includes?("SECRETKEY==") }.should be_true
    sh.ran?(/sysrc wireguard_enable=YES/).should be_true
    sh.ran?(/service wireguard start wg0/).should be_true
    ENV.delete("WG_TEST_PK")
  end

  it "idempotent : skip si conf identique + iface montée + rc OK" do
    ENV["WG_TEST_PK2"] = "K=="
    desired = Beryl::Apply::WireguardInterface.build_conf(
      "10.100.0.1/24", "51820", "K==", [] of Hash(String, String))
    sh = FakeShell.new
    sh.stub(/cat .*wg0\.conf/, stdout: desired)
    sh.stub(/ifconfig wg0/, exit_code: 0)
    sh.stub(/sysrc -n wireguard_interfaces/, stdout: "wg0\n")
    sh.stub(/sysrc -n wireguard_enable/, stdout: "YES\n")
    r = Beryl::Apply::WireguardInterface.new.apply(
      sh, p({"address" => "10.100.0.1/24", "private_key_env" => "WG_TEST_PK2"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    ENV.delete("WG_TEST_PK2")
  end

  it "lève si un pair n'a pas public_key/allowed_ips" do
    ENV["WG_TEST_PK3"] = "K=="
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /public_key|allowed_ips/) do
      Beryl::Apply::WireguardInterface.new.apply(
        FakeShell.new, p({"address" => "10.100.0.1/24", "private_key_env" => "WG_TEST_PK3",
                          "peers" => peers_yaml([{"name" => "x"}])}), false, ctx)
    end
    ENV.delete("WG_TEST_PK3")
  end
end
