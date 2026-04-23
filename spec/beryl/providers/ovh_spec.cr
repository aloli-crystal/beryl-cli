require "../../spec_helper"
require "../../support/fake_ovh_transport"

describe Beryl::Providers::Ovh do
  describe "#owns?" do
    it "retourne true si le service_name est dans la liste du compte" do
      transport = FakeOvhTransport.new
      transport.stub(
        "GET",
        /dedicated\/server$/,
        status: 200,
        body: %(["ns3156789.ip-51-83-6.eu","ns42.ip-1-2-3.eu"]),
      )
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.owns?("ns3156789.ip-51-83-6.eu").should be_true
    end

    it "retourne false si le service_name n'est pas dans la liste" do
      transport = FakeOvhTransport.new
      transport.stub(
        "GET",
        /dedicated\/server$/,
        status: 200,
        body: %(["ns1.ip-1-2-3.eu"]),
      )
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.owns?("ns9999.ip-99-99-99.eu").should be_false
    end

    it "retourne false si l'API lève (rescue-friendly)" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /dedicated\/server$/, status: 500, body: %({"message":"boom"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.owns?("whatever").should be_false
    end
  end

  describe "#name / #display_name" do
    it "expose un nom court et un nom humain" do
      provider = Beryl::Providers::Ovh.new
      provider.name.should eq("ovh")
      provider.display_name.should eq("OVHcloud")
    end
  end

  describe "#ssh_key_yaml_fragment" do
    it "renvoie { ssh_key_name => label }" do
      provider = Beryl::Providers::Ovh.new
      fragment = provider.ssh_key_yaml_fragment("philippe-aloli-fr")
      fragment["ssh_key_name"].should eq("philippe-aloli-fr")
    end
  end

  describe "#credentials_env_vars" do
    it "APP_KEY + APP_SECRET sont obligatoires, CONSUMER_KEY et ENDPOINT optionnels" do
      # CONSUMER_KEY est marquée optional : beryl init la génère
      # automatiquement via le hook `bootstrap_credentials_if_needed`
      # (POST /auth/credential). ENDPOINT a un défaut `eu`.
      vars = Beryl::Providers::Ovh.new.credentials_env_vars
      required = vars.reject(&.optional).map(&.name)
      required.should eq(["OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET"])
      vars.find { |v| v.name == "OVH_CONSUMER_KEY" }.not_nil!.optional.should be_true
      vars.find { |v| v.name == "OVH_ENDPOINT" }.not_nil!.optional.should be_true
    end
  end

  describe "#capabilities" do
    it "expose :dns et :compute (ADR-014)" do
      ovh = Beryl::Providers::Ovh.new
      ovh.capabilities.sort.should eq([:compute, :dns])
      ovh.capable_of?(:dns).should be_true
      ovh.capable_of?(:compute).should be_true
      ovh.capable_of?(:cdn).should be_false
    end

    it "inclut les modules DnsProvider et ComputeProvider" do
      ovh = Beryl::Providers::Ovh.new
      ovh.is_a?(Beryl::DnsProvider).should be_true
      ovh.is_a?(Beryl::ComputeProvider).should be_true
    end
  end

  describe "#required_access_rules" do
    it "liste les routes OVH à injecter dans la consumer key générée" do
      rules = Beryl::Providers::Ovh.new.required_access_rules
      paths = rules.map { |r| r[:path] }
      paths.should contain("/services/*")         # rename displayName
      paths.should contain("/dedicated/server/*") # rescue/bootstrap/info
      paths.should contain("/domain/zone/*")      # DNS forward
      paths.should contain("/ip/*/reverse")       # DNS reverse
    end
  end

  describe "#credentials_help_details" do
    it "affiche les routes à autoriser dans le navigateur" do
      details = Beryl::Providers::Ovh.new.credentials_help_details.not_nil!
      details.should contain("Beryl générera la consumer key")
      details.should contain("/services/*")
    end
  end

  describe "#bootstrap_credentials_if_needed" do
    it "ne fait rien si OVH_CONSUMER_KEY est déjà présente (idempotent)" do
      env = {
        "OVH_APPLICATION_KEY"    => "k",
        "OVH_APPLICATION_SECRET" => "s",
        "OVH_CONSUMER_KEY"       => "existing",
      }
      result = Beryl::Providers::Ovh.new.bootstrap_credentials_if_needed(env)
      result["OVH_CONSUMER_KEY"].should eq("existing")
    end

    it "lève si APP_KEY ou APP_SECRET manquent" do
      env = {} of String => String
      expect_raises(Exception, /OVH_APPLICATION_KEY/) do
        Beryl::Providers::Ovh.new.bootstrap_credentials_if_needed(env)
      end
    end
  end
end
