require "../../spec_helper"
require "../../../src/beryl/cli/account_utils"

describe Beryl::CLI::AccountUtils do
  describe ".split_account_path" do
    it "retourne {nil, raw} si aucun slash" do
      r = Beryl::CLI::AccountUtils.split_account_path("ovh")
      r[:account].should be_nil
      r[:object].should eq("ovh")
    end

    it "sépare société/objet sur le premier slash" do
      r = Beryl::CLI::AccountUtils.split_account_path("aloli/ovh")
      r[:account].should eq("aloli")
      r[:object].should eq("ovh")
    end

    it "garde les slashes suivants dans l'objet (rare mais possible)" do
      r = Beryl::CLI::AccountUtils.split_account_path("aloli/a/b")
      r[:account].should eq("aloli")
      r[:object].should eq("a/b")
    end
  end

  describe ".split_host_path" do
    it "0 slash → {nil, nil, raw}" do
      r = Beryl::CLI::AccountUtils.split_host_path("loulou")
      r[:account].should be_nil
      r[:domain].should be_nil
      r[:host].should eq("loulou")
    end

    it "0 slash avec FQDN" do
      r = Beryl::CLI::AccountUtils.split_host_path("loulou.aloli.net")
      r[:account].should be_nil
      r[:domain].should be_nil
      r[:host].should eq("loulou.aloli.net")
    end

    it "1 slash → {account, nil, host}" do
      r = Beryl::CLI::AccountUtils.split_host_path("aloli/loulou")
      r[:account].should eq("aloli")
      r[:domain].should be_nil
      r[:host].should eq("loulou")
    end

    it "1 slash avec FQDN host" do
      r = Beryl::CLI::AccountUtils.split_host_path("aloli/loulou.aloli.net")
      r[:account].should eq("aloli")
      r[:domain].should be_nil
      r[:host].should eq("loulou.aloli.net")
    end

    it "2 slashes → {account, domain, host}" do
      r = Beryl::CLI::AccountUtils.split_host_path("aloli/aloli.net/loulou")
      r[:account].should eq("aloli")
      r[:domain].should eq("aloli.net")
      r[:host].should eq("loulou")
    end

    it "2 slashes avec FQDN externe" do
      r = Beryl::CLI::AccountUtils.split_host_path("aloli/aloli.net/ns3156789.ip-51-83-6.eu")
      r[:account].should eq("aloli")
      r[:domain].should eq("aloli.net")
      r[:host].should eq("ns3156789.ip-51-83-6.eu")
    end

    it "≥ 3 slashes → lève ArgumentError" do
      expect_raises(ArgumentError, /trop de slashes/) do
        Beryl::CLI::AccountUtils.split_host_path("a/b/c/d")
      end
    end
  end
end
