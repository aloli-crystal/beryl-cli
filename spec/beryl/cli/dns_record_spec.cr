require "../../spec_helper"
require "../../../src/beryl/cli/dns_record"

describe Beryl::CLI::DnsRecord do
  describe ".sub_domain" do
    it "@ et vide désignent le sommet de la zone" do
      Beryl::CLI::DnsRecord.sub_domain("@").should eq("")
      Beryl::CLI::DnsRecord.sub_domain(" _acme-challenge.pkg ").should eq("_acme-challenge.pkg")
    end
  end

  describe ".normalize_target" do
    it "CNAME : nom absolu (point final ajouté)" do
      Beryl::CLI::DnsRecord.normalize_target("CNAME", "_acme-challenge.pkg.example.net")
        .should eq("_acme-challenge.pkg.example.net.")
      Beryl::CLI::DnsRecord.normalize_target("CNAME", "a.example.net.").should eq("a.example.net.")
    end

    it "A / AAAA : adresses validées" do
      Beryl::CLI::DnsRecord.normalize_target("A", "192.0.2.1").should eq("192.0.2.1")
      Beryl::CLI::DnsRecord.normalize_target("AAAA", "2001:db8::1").should eq("2001:db8::1")
      expect_raises(ArgumentError, /IPv4/) { Beryl::CLI::DnsRecord.normalize_target("A", "a.example.net") }
      expect_raises(ArgumentError, /IPv6/) { Beryl::CLI::DnsRecord.normalize_target("AAAA", "192.0.2.1") }
    end

    it "MX : « priorité serveur », serveur absolu" do
      Beryl::CLI::DnsRecord.normalize_target("MX", "10 mx.example.net").should eq("10 mx.example.net.")
      expect_raises(ArgumentError, /priorité/) { Beryl::CLI::DnsRecord.normalize_target("MX", "mx.example.net") }
    end

    it "TXT tel quel ; type inconnu refusé" do
      Beryl::CLI::DnsRecord.normalize_target("TXT", "v=spf1 -all").should eq("v=spf1 -all")
      expect_raises(ArgumentError, /non géré/) { Beryl::CLI::DnsRecord.normalize_target("SRV", "x") }
    end
  end

  it "simulation : zone inconnue → usage" do
    root = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "machine-kind"))
    Beryl::CLI::DnsRecord.run(root, ["inconnue.example", "www", "A", "192.0.2.1"]).should eq(Beryl::CLI::DnsRecord::EXIT_USAGE)
  end

  it "zone sans dns_provider → usage" do
    root = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "machine-kind"))
    Beryl::CLI::DnsRecord.run(root, ["initech.example", "www", "A", "192.0.2.1"]).should eq(Beryl::CLI::DnsRecord::EXIT_USAGE)
  end

  it "simulation : zone connue → plan, aucun appel API" do
    root = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "dns-record"))
    Beryl::CLI::DnsRecord.run(root, ["example.net", "_acme-challenge.pkg", "CNAME", "_acme-challenge.pkg.example.org"]).should eq(Beryl::CLI::DnsRecord::EXIT_OK)
  end

  it "mauvais nombre d'arguments → usage" do
    root = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "dns-record"))
    Beryl::CLI::DnsRecord.run(root, ["example.net", "www", "A"]).should eq(Beryl::CLI::DnsRecord::EXIT_USAGE)
  end
end
