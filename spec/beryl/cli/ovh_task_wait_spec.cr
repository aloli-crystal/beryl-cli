require "../../spec_helper"
require "../../support/fake_ovh_transport"
require "../../../src/beryl/cli/ovh_task_wait"

private SN = "ns1.ip-1-2-3.eu"

private def task_json(id : Int64, status : String) : String
  %({"taskId":#{id},"function":"hardReboot","status":"#{status}","comment":"Reboot asked"})
end

private def task(id : Int64, status : String) : OvhApi::Endpoints::Task
  OvhApi::Endpoints::Task.from_any(JSON.parse(task_json(id, status)))
end

describe Beryl::CLI::OvhTaskWait do
  describe ".wait" do
    it "rend nil quand la tâche aboutit" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /task\/42$/, status: 200, body: task_json(42, "done"))
      client = build_fake_ovh_client(transport)
      Beryl::CLI::OvhTaskWait.wait("spec", client, SN, task(42, "doing"), timeout: 1.second, poll: 10.milliseconds)
        .should be_nil
    end

    it "rend le message d'une tâche en erreur" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /task\/42$/, status: 200, body: task_json(42, "ovhError"))
      client = build_fake_ovh_client(transport)
      msg = Beryl::CLI::OvhTaskWait.wait("spec", client, SN, task(42, "doing"), timeout: 1.second, poll: 10.milliseconds)
      msg.should_not be_nil
      msg.not_nil!.should contain "ovhError"
    end

    it "délai dépassé : dit que le redémarrage continue et qu'il suffit de relancer" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /task\/42$/, status: 200, body: task_json(42, "doing"))
      client = build_fake_ovh_client(transport)
      msg = Beryl::CLI::OvhTaskWait.wait("spec", client, SN, task(42, "doing"), timeout: 50.milliseconds, poll: 10.milliseconds)
      msg.not_nil!.should contain "toujours en doing"
      msg.not_nil!.should contain "relancez la même commande"
    end
  end

  it "attend 15 min par défaut (ADV-3 : 6 à 9 min constatées)" do
    Beryl::CLI::OvhTaskWait::TIMEOUT.should eq 15.minutes
  end

  describe ".already_requested?" do
    it "reconnaît le refus d'OVH (403, reboot déjà demandé)" do
      ex = OvhApi::ApiError.new(%(HTTP 403 : {"message":"A reboot has already been requested"}), 403)
      Beryl::CLI::OvhTaskWait.already_requested?(ex).should be_true
    end

    it "ignore les autres erreurs" do
      Beryl::CLI::OvhTaskWait.already_requested?(OvhApi::ApiError.new("HTTP 403 : forbidden", 403)).should be_false
      Beryl::CLI::OvhTaskWait.already_requested?(OvhApi::ApiError.new("already been requested", 500)).should be_false
      Beryl::CLI::OvhTaskWait.already_requested?(Exception.new("already been requested")).should be_false
    end
  end

  describe ".pending_reboot" do
    it "retrouve la tâche hardReboot en cours la plus récente" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /task\?/, status: 200, body: "[]")
      transport.stub("GET", /task\?.*status=doing/, status: 200, body: "[7, 9]")
      transport.stub("GET", /task\/9$/, status: 200, body: task_json(9, "doing"))
      client = build_fake_ovh_client(transport)
      pending = Beryl::CLI::OvhTaskWait.pending_reboot(client, SN)
      pending.not_nil!.id.should eq 9
      transport.requests.any?(&.url.includes?("function=hardReboot")).should be_true
    end

    it "nil si aucune tâche en cours" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /task\?/, status: 200, body: "[]")
      client = build_fake_ovh_client(transport)
      Beryl::CLI::OvhTaskWait.pending_reboot(client, SN).should be_nil
    end
  end
end
