require "../../spec_helper"
require "../../support/fake_gandi_transport"

private def gandi(transport : FakeGandiTransport) : Beryl::Providers::Gandi
  Beryl::Providers::Gandi.new(build_fake_gandi_client(transport))
end

describe Beryl::Providers::Gandi do
  it "déclare la capability :dns uniquement" do
    g = Beryl::Providers::Gandi.new
    g.capabilities.should eq([:dns])
    g.capable_of?(:dns).should be_true
    g.capable_of?(:compute).should be_false
    g.name.should eq("gandi")
  end

  it "est available? avec un client injecté" do
    gandi(FakeGandiTransport.new).available?.should be_true
  end

  describe "#ensure_record" do
    it "fait un PUT idempotent du rrset via LiveDNS" do
      t = FakeGandiTransport.new
      gandi(t).ensure_record("popi.fr", "A", "www", "203.0.113.7")
      t.last.method.should eq("PUT")
      t.last.url.should end_with("/domains/popi.fr/records/www/A")
      JSON.parse(t.last.body)["rrset_values"].as_a.map(&.as_s).should eq(["203.0.113.7"])
    end

    it "cible la racine (@) quand le sous-domaine est vide" do
      t = FakeGandiTransport.new
      gandi(t).ensure_record("popi.fr", "AAAA", "", "2001:db8::1")
      t.last.url.should end_with("/records/@/AAAA")
    end
  end

  it "refuse le reverse DNS (PTR géré par l'hébergeur)" do
    expect_raises(Exception, /reverse DNS/) do
      gandi(FakeGandiTransport.new).set_reverse("203.0.113.7", "www.popi.fr")
    end
  end

  it "refresh_zone est un no-op (Gandi propage seul)" do
    t = FakeGandiTransport.new
    gandi(t).refresh_zone("popi.fr")
    t.requests.should be_empty
  end

  it "n'expose aucune clé SSH (DNS-only)" do
    gandi(FakeGandiTransport.new).list_ssh_keys.should be_empty
  end
end
