require "../../spec_helper"
require "../../../src/beryl/cli/machine_kind"
require "../../../src/beryl/cli/rescue"
require "../../../src/beryl/cli/vrack"

private FIXTURE = File.expand_path(
  File.join(__DIR__, "..", "..", "fixtures", "config", "machine-kind"),
)

describe Beryl::CLI::MachineKind do
  it "laisse passer un serveur dédié (kind absent)" do
    host = Beryl::Config::Root.load(FIXTURE).resolve("netbast")
    Beryl::CLI::MachineKind.refuse_vps(host, "rescue").should be_false
  end

  it "refuse un VPS" do
    host = Beryl::Config::Root.load(FIXTURE).resolve("vpsbox")
    Beryl::CLI::MachineKind.refuse_vps(host, "rescue").should be_true
  end

  it "rescue : un VPS est refusé AVANT tout appel API" do
    no_api = -> : OvhApi::Client { raise "API OVH appelée pour un VPS" }
    code = Beryl::CLI::Rescue.run(FIXTURE, ["vpsbox"], ovh_client_factory: no_api,
      dns_resolver: ->(_h : String) { true })
    code.should eq(Beryl::CLI::Rescue::EXIT_BAD_PROVIDER)
  end

  it "vrack : un VPS est refusé" do
    Beryl::CLI::Vrack.run(FIXTURE, ["vpsbox"]).should eq(Beryl::CLI::Vrack::EXIT_USAGE)
  end
end
