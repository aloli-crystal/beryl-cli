require "../../spec_helper"
require "../../support/fake_scaleway_transport"

describe Beryl::Providers::Scaleway do
  describe "#owns?" do
    it "retourne true si un server a l'id fourni" do
      transport = FakeScalewayTransport.new
      transport.stub(
        "GET",
        /baremetal\/v1\/zones\/.+\/servers/,
        status: 200,
        body: %({
          "servers": [
            {"id":"11111111-2222-3333-4444-555555555555","name":"loulou","status":"ready",
             "zone":"fr-par-2","hostname":"loulou","ips":[],"tags":[],"description":"","offer_id":"x","organization_id":"o","project_id":"p"}
          ],
          "total_count": 1
        }),
      )
      provider = Beryl::Providers::Scaleway.new(build_fake_scaleway_client(transport))
      provider.owns?("11111111-2222-3333-4444-555555555555").should be_true
    end

    it "retourne true si un server a le nom fourni" do
      transport = FakeScalewayTransport.new
      transport.stub(
        "GET",
        /baremetal\/v1\/zones\/.+\/servers/,
        status: 200,
        body: %({
          "servers": [
            {"id":"aaaa","name":"loulou","status":"ready","zone":"fr-par-2",
             "hostname":"loulou","ips":[],"tags":[],"description":"","offer_id":"x","organization_id":"o","project_id":"p"}
          ],
          "total_count": 1
        }),
      )
      provider = Beryl::Providers::Scaleway.new(build_fake_scaleway_client(transport))
      provider.owns?("loulou").should be_true
    end

    it "retourne false si ni id ni nom ne correspond" do
      transport = FakeScalewayTransport.new
      transport.stub(
        "GET",
        /servers/,
        status: 200,
        body: %({"servers":[],"total_count":0}),
      )
      provider = Beryl::Providers::Scaleway.new(build_fake_scaleway_client(transport))
      provider.owns?("inconnu").should be_false
    end

    it "retourne false si l'API lève (rescue-friendly)" do
      transport = FakeScalewayTransport.new
      transport.stub("GET", /servers/, status: 500, body: %({"message":"boom"}))
      provider = Beryl::Providers::Scaleway.new(build_fake_scaleway_client(transport))
      provider.owns?("anything").should be_false
    end
  end

  describe "#name / #display_name" do
    it "expose un nom court et un nom humain" do
      provider = Beryl::Providers::Scaleway.new
      provider.name.should eq("scaleway")
      provider.display_name.should eq("Scaleway Elastic Metal")
    end
  end

  describe "#ssh_key_yaml_fragment" do
    it "renvoie { ssh_key_ids => [uuid] } si un UUID est passé" do
      provider = Beryl::Providers::Scaleway.new
      uuid = "11111111-2222-3333-4444-555555555555"
      fragment = provider.ssh_key_yaml_fragment(uuid)
      fragment["ssh_key_ids"].should eq([uuid])
    end
  end

  describe "#credentials_env_vars" do
    it "liste SCW_SECRET_KEY requis + ZONE/PROJECT_ID optionnels" do
      vars = Beryl::Providers::Scaleway.new.credentials_env_vars
      vars.reject(&.optional).map(&.name).should eq(["SCW_SECRET_KEY"])
      optional = vars.select(&.optional).map(&.name)
      optional.should contain("SCW_DEFAULT_ZONE")
      optional.should contain("SCW_DEFAULT_PROJECT_ID")
    end
  end
end
