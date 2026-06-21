require "../../spec_helper"
require "../../../src/beryl/cli/fmt"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::CLI::Fmt do
  describe ".host_fqdn" do
    it "dérive le FQDN d'un *.host.yml depuis le chemin" do
      Beryl::CLI::Fmt.host_fqdn("/c/popi/popi.net/ben.host.yml").should eq("ben.popi.net")
    end

    it "nil pour un fichier structurel (pas d'en-tête FQDN)" do
      Beryl::CLI::Fmt.host_fqdn("/c/popi/_default.yml").should be_nil
      Beryl::CLI::Fmt.host_fqdn("/c/popi/popi.net.domain.yml").should be_nil
    end
  end

  describe ".in_scope?" do
    it "société : matche tous les fichiers sous la société" do
      Beryl::CLI::Fmt.in_scope?("/c/popi/_default.yml", "/c", "popi").should be_true
      Beryl::CLI::Fmt.in_scope?("/c/popi/popi.net/ben.host.yml", "/c", "popi").should be_true
      Beryl::CLI::Fmt.in_scope?("/c/aloli/_default.yml", "/c", "popi").should be_false
    end

    it "domaine : matche les fichiers du domaine (dossier ou *.domain.yml)" do
      Beryl::CLI::Fmt.in_scope?("/c/popi/popi.net/_default.yml", "/c", "popi.net").should be_true
      Beryl::CLI::Fmt.in_scope?("/c/popi/popi.net.domain.yml", "/c", "popi.net").should be_true
    end

    it "host : par nom court OU fqdn" do
      h = "/c/popi/popi.net/ben.host.yml"
      Beryl::CLI::Fmt.in_scope?(h, "/c", "ben").should be_true
      Beryl::CLI::Fmt.in_scope?(h, "/c", "ben.popi.net").should be_true
      Beryl::CLI::Fmt.in_scope?(h, "/c", "obi").should be_false
    end
  end

  describe ".config_files" do
    it "inclut host + structurels, EXCLUT les secrets (.env*)" do
      bases = Beryl::CLI::Fmt.config_files(FIXTURES).map { |f| File.basename(f) }
      bases.should contain("_default.yml")
      bases.any?(&.ends_with?(".host.yml")).should be_true
      bases.none?(&.starts_with?(".env")).should be_true
    end
  end
end
