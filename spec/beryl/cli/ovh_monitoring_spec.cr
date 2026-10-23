require "../../spec_helper"
require "../../support/fake_ovh_transport"
require "../../../src/beryl/cli/ovh_monitoring"
require "../../../src/beryl/cli/monitoring"

private SN = "ns1.ip-1-2-3.eu"

private def with_state_dir(&)
  dir = File.tempname("beryl-ovh-monitoring")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def transport_with(monitoring : Bool) : FakeOvhTransport
  t = FakeOvhTransport.new
  t.stub("GET", /dedicated\/server\/#{Regex.escape(SN)}$/, status: 200, body: %({"name":"#{SN}","monitoring":#{monitoring}}))
  t.stub("PUT", /dedicated\/server\/#{Regex.escape(SN)}$/, status: 200, body: "null")
  t
end

private def puts_of(t : FakeOvhTransport) : Array(String)
  t.requests.select(&.method.==("PUT")).map(&.body)
end

describe Beryl::CLI::OvhMonitoring do
  it "rescue : coupe un monitoring actif et pose le marqueur" do
    with_state_dir do |dir|
      t = transport_with(true)
      msg = Beryl::CLI::OvhMonitoring.suspend(build_fake_ovh_client(t), SN, dir)
      msg.not_nil!.should contain "coupé"
      puts_of(t).should eq [%({"monitoring":false})]
      File.exists?(Beryl::CLI::OvhMonitoring.marker(SN, dir)).should be_true
    end
  end

  it "rescue : rien si le monitoring est déjà coupé (pas de marqueur : beryl ne le rétablira pas)" do
    with_state_dir do |dir|
      t = transport_with(false)
      Beryl::CLI::OvhMonitoring.suspend(build_fake_ovh_client(t), SN, dir).should be_nil
      puts_of(t).should be_empty
      File.exists?(Beryl::CLI::OvhMonitoring.marker(SN, dir)).should be_false
    end
  end

  it "boot-hd : rétablit ce que rescue a coupé, et retire le marqueur" do
    with_state_dir do |dir|
      t = transport_with(true)
      client = build_fake_ovh_client(t)
      Beryl::CLI::OvhMonitoring.suspend(client, SN, dir)
      Beryl::CLI::OvhMonitoring.resume(client, SN, dir).not_nil!.should contain "rétabli"
      puts_of(t).last.should eq %({"monitoring":true})
      File.exists?(Beryl::CLI::OvhMonitoring.marker(SN, dir)).should be_false
    end
  end

  it "boot-hd : ne touche pas un monitoring que beryl n'a pas coupé" do
    with_state_dir do |dir|
      t = transport_with(false)
      Beryl::CLI::OvhMonitoring.resume(build_fake_ovh_client(t), SN, dir).should be_nil
      puts_of(t).should be_empty
    end
  end

  it "réglage à la main : prime sur la coupure de rescue (marqueur retiré)" do
    with_state_dir do |dir|
      t = transport_with(true)
      client = build_fake_ovh_client(t)
      Beryl::CLI::OvhMonitoring.suspend(client, SN, dir)
      Beryl::CLI::OvhMonitoring.set_by_hand(client, SN, false, dir)
      Beryl::CLI::OvhMonitoring.suspended_at(SN, dir).should be_nil
      Beryl::CLI::OvhMonitoring.resume(client, SN, dir).should be_nil
    end
  end
end

describe Beryl::CLI::Monitoring do
  it "lit l'état et la portée dans n'importe quel ordre" do
    Beryl::CLI::Monitoring.split_args(["loulou", "off"]).should eq({"off", "loulou"})
    Beryl::CLI::Monitoring.split_args(["on", "quimeo.net"]).should eq({"on", "quimeo.net"})
    Beryl::CLI::Monitoring.split_args(["quimeo"]).should eq({nil, "quimeo"})
  end

  it "dit qui a coupé le monitoring" do
    Beryl::CLI::Monitoring.status_text(true, nil).should eq "monitoring actif"
    Beryl::CLI::Monitoring.status_text(false, nil).should eq "monitoring coupé"
    Beryl::CLI::Monitoring.status_text(false, "2026-10-23T17:00:00+02:00").should contain "coupé par beryl rescue"
  end
end
