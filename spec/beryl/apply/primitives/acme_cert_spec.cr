require "../../../spec_helper"
require "../../../support/fake_shell"

private def dom(list : Array(String)) : YAML::Any
  YAML::Any.new(list.map { |d| YAML::Any.new(d) })
end

private def p(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = v.is_a?(YAML::Any) ? v : YAML::Any.new(v) }
  res
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::AcmeCert do
  it "est enregistrée sous `acme-cert`" do
    Beryl::Apply::Primitive["acme-cert"]?.should_not be_nil
  end

  describe ".issue_script" do
    it "standalone : issue multi-SAN, install --ecc, reloadcmd, trap restart" do
      s = Beryl::Apply::AcmeCert.issue_script(
        ["pkg.quimeo.net", "pkg.aloli.net"], "/ssl/fc.pem", "/ssl/key.pem",
        "service nginx reload", "/home/acme", "letsencrypt", "standalone", nil, "nginx", "ec-256")
      s.should contain("--issue --server letsencrypt -d pkg.quimeo.net -d pkg.aloli.net --standalone --home /home/acme")
      s.should contain("--install-cert -d pkg.quimeo.net --ecc")
      s.should contain("--fullchain-file \"$FC\"")
      s.should contain("--key-file \"$KEY\"")
      s.should contain("--reloadcmd 'service nginx reload'")
      s.should contain("trap 'service nginx onestart >/dev/null 2>&1 || true' EXIT")
      s.should contain("service nginx onestop")
      # 0 (émis) ou 2 (déjà valide côté acme.sh) acceptés
      s.should contain(%([ "$rc" != 0 ] && [ "$rc" != 2 ]))
    end

    it "webroot + RSA : -w <racine>, pas de --standalone, pas de --ecc, sans stop_service" do
      s = Beryl::Apply::AcmeCert.issue_script(
        ["ex.net"], "/fc", "/k", nil, "/h", "letsencrypt", "webroot", "/var/www", nil, "2048")
      s.should contain("-w /var/www")
      s.should_not contain("--standalone")
      s.should_not contain("--ecc")
      s.should_not contain("--reloadcmd")
      # sans stop_service : pas de trap service, garde neutre
      s.should_not contain("onestop")
    end
  end

  it "skip si le cert existe et reste valide (openssl -checkend OK)" do
    sh = FakeShell.new # défaut = succès → checkend passe → idempotent
    r = Beryl::Apply::AcmeCert.new.apply(
      sh, p({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    sh.writes.empty?.should be_true
  end

  it "émet + installe quand le cert est absent/expirant" do
    sh = FakeShell.new
    sh.stub(/checkend/, exit_code: 1) # cert absent ou proche expiration
    r = Beryl::Apply::AcmeCert.new.apply(
      sh, p({"domains" => dom(["pkg.quimeo.net", "pkg.aloli.net"]),
             "fullchain" => "/ssl/fc.pem", "key" => "/ssl/key.pem",
             "reloadcmd" => "service nginx reload", "stop_service" => "nginx"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.writes.any? { |w| w.path == "/tmp/beryl-acme-cert.sh" && w.content.includes?("--issue") }.should be_true
    sh.ran?(/sh \/tmp\/beryl-acme-cert\.sh/).should be_true
  end

  it "dry-run : n'écrit ni ne lance rien" do
    sh = FakeShell.new
    sh.stub(/checkend/, exit_code: 1)
    r = Beryl::Apply::AcmeCert.new.apply(
      sh, p({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k"}), true, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("dry-run")
    sh.writes.empty?.should be_true
    sh.ran?(/beryl-acme-cert/).should be_false
  end

  it "lève si `domains` est vide" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /domains/) do
      Beryl::Apply::AcmeCert.new.apply(FakeShell.new, p({"fullchain" => "/fc", "key" => "/k"}), false, ctx)
    end
  end

  it "lève si `method: webroot` sans `webroot`" do
    sh = FakeShell.new
    sh.stub(/checkend/, exit_code: 1)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /webroot/) do
      Beryl::Apply::AcmeCert.new.apply(
        sh, p({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k", "method" => "webroot"}), false, ctx)
    end
  end
end
