require "../../spec_helper"
require "../../../src/beryl/cli/ssh_probe"

describe Beryl::CLI::SshProbe do
  describe ".compact_error" do
    it "clé refusée" do
      err = "admin@ns1.ip-1-2-3.eu: Permission denied (publickey,password,keyboard-interactive)."
      Beryl::CLI::SshProbe.compact_error(err, 255).should eq("clé refusée (publickey)")
    end

    it "timeout" do
      Beryl::CLI::SshProbe.compact_error("ssh: connect to host x port 22: Operation timed out", 255).should eq("timeout / injoignable")
    end

    it "repli sur le code de sortie" do
      Beryl::CLI::SshProbe.compact_error("", 3).should eq("SSH exit 3")
    end
  end

  describe ".network_error?" do
    it "vrai pour un refus de connexion (inutile d'essayer d'autres users)" do
      Beryl::CLI::SshProbe.network_error?("connect to host x port 22: Connection refused").should be_true
    end

    it "faux pour une clé refusée (un autre user peut passer)" do
      Beryl::CLI::SshProbe.network_error?("Permission denied (publickey).").should be_false
    end
  end
end
