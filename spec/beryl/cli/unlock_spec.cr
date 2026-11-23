require "../../spec_helper"
require "../../../src/beryl/cli/unlock"

private def action(service : String, act : String) : Beryl::Config::ServiceAction
  Beryl::Config::ServiceAction.new(service, act)
end

describe Beryl::CLI::Unlock do
  describe ".with_base_reloads" do
    it "ajoute `syslogd reload` puis `cron restart` en dernier si zroot/encrypted était verrouillé" do
      after = [action("unbound", "restart"), action("nginx", "restart")]
      Beryl::CLI::Unlock.with_base_reloads(after, true).should eq(
        [action("unbound", "restart"), action("nginx", "restart"), action("syslogd", "reload"), action("cron", "restart")])
    end

    it "les ajoute même sans after_unlock (--skip-after-unlock)" do
      Beryl::CLI::Unlock.with_base_reloads([] of Beryl::Config::ServiceAction, true).should eq(
        [action("syslogd", "reload"), action("cron", "restart")])
    end

    it "ne touche à rien si zroot/encrypted était déjà ouvert (pools data seuls)" do
      after = [action("mysql-server", "restart")]
      Beryl::CLI::Unlock.with_base_reloads(after, false).should eq(after)
    end

    it "garde l'action déclarée dans after_unlock, sans la doubler" do
      after = [action("cron", "restart"), action("nginx", "restart")]
      Beryl::CLI::Unlock.with_base_reloads(after, true).should eq(after + [action("syslogd", "reload")])
    end
  end
end
