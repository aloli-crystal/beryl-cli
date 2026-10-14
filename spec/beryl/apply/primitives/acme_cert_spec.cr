require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private def dom(list : Array(String)) : YAML::Any
  YAML::Any.new(list.map { |d| YAML::Any.new(d) })
end

private def params(h)
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
        "service nginx reload", "/home/acme", "letsencrypt", "standalone", nil, "nginx", "ec-256", nil, nil)
      s.should contain("--issue --server letsencrypt -d pkg.quimeo.net -d pkg.aloli.net --standalone --home /home/acme")
      s.should contain("--install-cert -d pkg.quimeo.net --ecc")
      s.should contain("--fullchain-file /ssl/fc.pem --key-file /ssl/key.pem")
      s.should contain("--reloadcmd 'service nginx reload'")
      s.should contain("trap 'service nginx onestart >/dev/null 2>&1 || true' EXIT")
      s.should contain("service nginx onestop")
      # 0 (émis) ou 2 (déjà valide côté acme.sh) acceptés
      s.should contain(%([ "$rc" != 0 ] && [ "$rc" != 2 ]))
    end

    it "hooks persistés (pre/post) sur --issue, pour le renouvellement du cron" do
      s = Beryl::Apply::AcmeCert.issue_script(
        ["pkg.quimeo.net"], "/fc", "/k", "service nginx reload", "/h", "letsencrypt",
        "standalone", nil, nil, "ec-256", "service nginx stop", "service nginx start")
      s.should contain("--pre-hook 'service nginx stop'")
      s.should contain("--post-hook 'service nginx start'")
    end

    it "webroot + RSA : -w <racine>, pas de --standalone, pas de --ecc, sans stop_service" do
      s = Beryl::Apply::AcmeCert.issue_script(
        ["ex.net"], "/fc", "/k", nil, "/h", "letsencrypt", "webroot", "/var/www", nil, "2048", nil, nil)
      s.should contain("-w /var/www")
      s.should_not contain("--standalone")
      s.should_not contain("--ecc")
      s.should_not contain("--reloadcmd")
      # sans stop_service : pas de trap service, garde neutre
      s.should_not contain("onestop")
    end

    it "dns : --dns <provider> + exports des credentials, sans --standalone" do
      s = Beryl::Apply::AcmeCert.issue_script(
        ["example.review", "*.example.review"], "/fc", "/k", "service nginx reload", "/h",
        "letsencrypt", "dns", nil, nil, "ec-256", nil, nil, "dns_ovh",
        {"OVH_AK" => "ak", "OVH_END_POINT" => "ovh-eu"})
      s.should contain("--dns dns_ovh")
      s.should_not contain("--standalone")
      s.should contain("export OVH_AK=ak")
      s.should contain("export OVH_END_POINT=ovh-eu")
      s.should contain("-d '*.example.review'")
    end
  end

  describe ".ovh_end_point" do
    it "traduit le format beryl (eu) vers celui d'acme.sh (ovh-eu)" do
      Beryl::Apply::AcmeCert.ovh_end_point("eu").should eq("ovh-eu")
      Beryl::Apply::AcmeCert.ovh_end_point(nil).should eq("ovh-eu")
      Beryl::Apply::AcmeCert.ovh_end_point("kimsufi_eu").should eq("kimsufi-eu")
      Beryl::Apply::AcmeCert.ovh_end_point("ovh-ca").should eq("ovh-ca")
    end
  end

  describe ".dns_credentials" do
    it "traduit les noms beryl vers ceux d'acme.sh (+ endpoint dérivé)" do
      c = Beryl::Apply::AcmeCert.dns_credentials("dns_ovh", {
        "OVH_APPLICATION_KEY" => "AK", "OVH_APPLICATION_SECRET" => "AS",
        "OVH_CONSUMER_KEY" => "CK", "OVH_ENDPOINT" => "eu",
      })
      c["OVH_AK"].should eq("AK")
      c["OVH_AS"].should eq("AS")
      c["OVH_CK"].should eq("CK")
      c["OVH_END_POINT"].should eq("ovh-eu")
    end

    it "renvoie vide si le provider DNS n'est pas câblé" do
      Beryl::Apply::AcmeCert.dns_credentials("dns_cloudflare", {"X" => "y"}).empty?.should be_true
    end
  end

  it "skip si le cert existe et reste valide (openssl -checkend OK)" do
    sh = FakeShell.new # défaut = succès → checkend passe → idempotent
    r = Beryl::Apply::AcmeCert.new.apply(
      sh, params({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    sh.writes.empty?.should be_true
  end

  it "émet + installe quand le cert est absent/expirant" do
    sh = FakeShell.new
    sh.stub(/checkend/, exit_code: 1) # cert absent ou proche expiration
    r = Beryl::Apply::AcmeCert.new.apply(
      sh, params({"domains" => dom(["pkg.quimeo.net", "pkg.aloli.net"]),
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
      sh, params({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k"}), true, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("dry-run")
    sh.writes.empty?.should be_true
    sh.ran?(/beryl-acme-cert/).should be_false
  end

  it "lève si `domains` est vide" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /domains/) do
      Beryl::Apply::AcmeCert.new.apply(FakeShell.new, params({"fullchain" => "/fc", "key" => "/k"}), false, ctx)
    end
  end

  it "lève si `method: webroot` sans `webroot`" do
    sh = FakeShell.new
    sh.stub(/checkend/, exit_code: 1)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /webroot/) do
      Beryl::Apply::AcmeCert.new.apply(
        sh, params({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k", "method" => "webroot"}), false, ctx)
    end
  end

  it "lève si `method: dns` sans `dns_provider`" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /dns_provider/) do
      Beryl::Apply::AcmeCert.new.apply(
        FakeShell.new,
        params({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k", "method" => "dns"}), false, ctx)
    end
  end

  it "lève si `method: dns` est combiné à `stop_service` (coupure inutile)" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /stop_service/) do
      Beryl::Apply::AcmeCert.new.apply(
        FakeShell.new,
        params({"domains" => dom(["a.net"]), "fullchain" => "/fc", "key" => "/k",
                "method" => "dns", "dns_provider" => "dns_ovh", "stop_service" => "nginx"}), false, ctx)
    end
  end

  describe ".failure_summary" do
    it "garde les lignes d'erreur d'acme.sh, pas le lien final vers le wiki" do
      output = <<-OUT
        [Mon Oct  5 15:21:44 CEST 2026] Using CA: https://acme-v02.api.letsencrypt.org/directory
        [Mon Oct  5 15:21:46 CEST 2026] Error add txt for domain:_acme-challenge.qwerty.example.net
        [Mon Oct  5 15:21:47 CEST 2026] Please add '--debug' or '--log' to see more information.
        [Mon Oct  5 15:21:47 CEST 2026] See: https://github.com/acmesh-official/acme.sh/wiki/How-to-debug-acme.sh
        OUT
      s = Beryl::Apply::AcmeCert.failure_summary(output, "", 1)
      s.should eq("Error add txt for domain:_acme-challenge.qwerty.example.net")
    end

    it "repli : dernières lignes quand aucune ne ressemble à une erreur" do
      Beryl::Apply::AcmeCert.failure_summary("a\nb\nc\nd\n", "", 1).should eq("b | c | d")
      Beryl::Apply::AcmeCert.failure_summary("", "", 3).should eq("échec (code 3)")
    end
  end

  it "conventions du port : CERT_HOME passé à acme.sh, pas de copie sans chemins explicites" do
    s = Beryl::Apply::AcmeCert.issue_script(
      ["a.example.net"], nil, nil, "sudo service nginx reload", "/var/db/acme/.acme.sh",
      "letsencrypt", "dns", nil, nil, "ec-256", nil, nil, "dns_ovh")
    s.should contain("--home /var/db/acme/.acme.sh --cert-home /var/db/acme/certs")
    s.should contain("--install-cert -d a.example.net --ecc")
    s.should contain("--reloadcmd 'sudo service nginx reload'")
    s.should_not contain("--fullchain-file")
    s.should_not contain("--log") # journal via LOG_FILE d'account.conf (recette acme)
  end

  it "chemin du fullchain dans CERT_HOME (suffixe _ecc pour une clé EC)" do
    Beryl::Apply::AcmeCert.cert_home_fullchain("/var/db/acme/certs", "a.example.net", "ec-256")
      .should eq("/var/db/acme/certs/a.example.net_ecc/fullchain.cer")
    Beryl::Apply::AcmeCert.cert_home_fullchain("/var/db/acme/certs", "a.example.net", "4096")
      .should eq("/var/db/acme/certs/a.example.net/fullchain.cer")
  end

  describe ".domain_flags (mode alias DNS)" do
    it "sans alias : simples -d" do
      Beryl::Apply::AcmeCert.domain_flags(["a.example.net", "b.example.net"], {} of String => String)
        .should eq("-d a.example.net -d b.example.net")
    end

    it "mélange : alias pour un domaine, `no` pour les autres (wiki acme.sh, section 5)" do
      flags = Beryl::Apply::AcmeCert.domain_flags(["pkg.example.net", "pkg.example.org"],
        {"pkg.example.org" => "pkg.example.net"})
      flags.should eq("-d pkg.example.net --challenge-alias no -d pkg.example.org --challenge-alias pkg.example.net")
    end
  end

  it "refuse un alias pour un domaine absent de `domains`" do
    shell = FakeShell.new
    params = apply_params({domains: ["a.example.net"], method: "dns", dns_provider: "dns_ovh",
                           challenge_aliases: [{domain: "b.example.org", alias: "a.example.net"}]}.to_yaml)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /absent/) do
      prim("acme-cert").apply(shell, params, dry_run: true, context: ctx)
    end
  end
end
