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
    it "liste les 3 variables requises + ENDPOINT optionnel" do
      vars = Beryl::Providers::Ovh.new.credentials_env_vars
      required = vars.reject(&.optional).map(&.name)
      required.should eq(["OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET", "OVH_CONSUMER_KEY"])
      vars.find { |v| v.name == "OVH_ENDPOINT" }.not_nil!.optional.should be_true
    end
  end
end
