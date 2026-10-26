require "../../spec_helper"
require "../../support/fake_ovh_transport"
require "../../../src/beryl/cli/ovh_monitoring"
require "../../../src/beryl/cli/monitoring"

private SN = "ns1.ip-1-2-3.eu"

private def transport_with(body : String) : FakeOvhTransport
  t = FakeOvhTransport.new
  t.stub("GET", /dedicated\/server\/#{Regex.escape(SN)}$/, status: 200, body: body)
  t.stub("PUT", /dedicated\/server\/#{Regex.escape(SN)}$/, status: 200, body: "null")
  t
end

private def puts_of(t : FakeOvhTransport) : Array(String)
  t.requests.select(&.method.==("PUT")).map(&.body)
end

describe Beryl::CLI::OvhMonitoring do
  it "rescue : coupe toujours (déjà coupé : même ordre, sans effet)" do
    t = transport_with(%({"monitoring":false}))
    Beryl::CLI::OvhMonitoring.suspend(build_fake_ovh_client(t), SN).should contain "coupé"
    puts_of(t).should eq [%({"monitoring":false})]
  end

  it "bootstrap / boot-hd : remet toujours en service" do
    t = transport_with(%({"monitoring":false}))
    Beryl::CLI::OvhMonitoring.resume(build_fake_ovh_client(t), SN).should contain "remis en service"
    puts_of(t).should eq [%({"monitoring":true})]
  end

  it "état : actif, coupé, ou illisible si le champ manque" do
    Beryl::CLI::OvhMonitoring.state(build_fake_ovh_client(transport_with(%({"monitoring":true}))), SN).should be_true
    Beryl::CLI::OvhMonitoring.state(build_fake_ovh_client(transport_with(%({"monitoring":false}))), SN).should be_false
    Beryl::CLI::OvhMonitoring.state(build_fake_ovh_client(transport_with(%({"name":"#{SN}"}))), SN).should be_nil
  end
end

describe Beryl::CLI::Monitoring do
  it "lit l'état et la portée dans n'importe quel ordre" do
    Beryl::CLI::Monitoring.split_args(["loulou", "off"]).should eq({"off", "loulou"})
    Beryl::CLI::Monitoring.split_args(["on", "quimeo.net"]).should eq({"on", "quimeo.net"})
    Beryl::CLI::Monitoring.split_args(["quimeo"]).should eq({nil, "quimeo"})
  end

  it "texte d'état" do
    Beryl::CLI::Monitoring.status_text(true).should eq "monitoring actif"
    Beryl::CLI::Monitoring.status_text(false).should eq "monitoring coupé"
    Beryl::CLI::Monitoring.status_text(nil).should contain "illisible"
  end
end
