require "../../spec_helper"
require "../../../src/beryl/cli/reboot"

describe Beryl::CLI::Reboot do
  describe ".reboot_command" do
    it "passe par sudo -n hors root, avec la commande du système" do
      Beryl::CLI::Reboot.reboot_command("Linux", root: false)
        .should eq %(sh -c 'sudo -n nohup sh -c "sleep 2; systemctl reboot" >/dev/null 2>&1 &')
      Beryl::CLI::Reboot.reboot_command("FreeBSD", root: false)
        .should eq %(sh -c 'sudo -n nohup sh -c "sleep 2; shutdown -r now" >/dev/null 2>&1 &')
    end

    it "se passe de sudo en root" do
      Beryl::CLI::Reboot.reboot_command("FreeBSD", root: true).should_not contain "sudo"
    end

    it "enveloppe la commande dans sh -c (shell de connexion csh)" do
      Beryl::CLI::Reboot.reboot_command("FreeBSD", root: false).should start_with "sh -c '"
    end
  end

  describe ".poll_status" do
    it "dit ce que montre chaque tentative" do
      Beryl::CLI::Reboot.poll_status("a1", nil).should eq "pas de réponse (redémarrage en cours)"
      Beryl::CLI::Reboot.poll_status("a1", "a1").should eq "répond encore sur l'ancien démarrage"
      Beryl::CLI::Reboot.poll_status("a1", "b2").should eq "redémarrée"
    end
  end

  describe ".rebooted?" do
    it "exige un identifiant de démarrage différent" do
      Beryl::CLI::Reboot.rebooted?("a1", "a1").should be_false
      Beryl::CLI::Reboot.rebooted?("a1", "b2").should be_true
    end

    it "attend une réponse de la machine" do
      Beryl::CLI::Reboot.rebooted?("a1", nil).should be_false
      Beryl::CLI::Reboot.rebooted?("a1", "").should be_false
    end

    it "se contente d'une réponse si l'identifiant d'avant est inconnu (machine figée, --hard)" do
      Beryl::CLI::Reboot.rebooted?(nil, "b2").should be_true
    end
  end
end
