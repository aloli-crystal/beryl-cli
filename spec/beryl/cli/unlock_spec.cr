require "../../spec_helper"
require "../../../src/beryl/cli/unlock"

private def action(service : String, act : String) : Beryl::Config::ServiceAction
  Beryl::Config::ServiceAction.new(service, act)
end

describe Beryl::CLI::Unlock do
  describe ".with_cron_restart" do
    it "ajoute `cron restart` en dernier si zroot/encrypted était verrouillé" do
      after = [action("unbound", "restart"), action("nginx", "restart")]
      Beryl::CLI::Unlock.with_cron_restart(after, true).should eq(
        [action("unbound", "restart"), action("nginx", "restart"), action("cron", "restart")])
    end

    it "relance cron même sans after_unlock (--skip-after-unlock)" do
      Beryl::CLI::Unlock.with_cron_restart([] of Beryl::Config::ServiceAction, true).should eq([action("cron", "restart")])
    end

    it "ne touche à rien si zroot/encrypted était déjà ouvert (pools data seuls)" do
      after = [action("mysql-server", "restart")]
      Beryl::CLI::Unlock.with_cron_restart(after, false).should eq(after)
    end

    it "garde l'action cron déclarée dans after_unlock, sans la doubler" do
      after = [action("cron", "restart"), action("nginx", "restart")]
      Beryl::CLI::Unlock.with_cron_restart(after, true).should eq(after)
    end
  end
end
