require "../../spec_helper"
require "../../../src/beryl/cli/fmt"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::CLI::Fmt do
  describe ".host_fqdn" do
    it "dérive le FQDN d'un *.host.yml depuis le chemin" do
      Beryl::CLI::Fmt.host_fqdn("/c/popi/popi.net/ben.host.yml").should eq("ben.popi.net")
    end

    it "serveur d'un groupe : le domaine, pas le groupe (`<domaine>/<groupe>/`)" do
      path = File.join(FIXTURES, "with-group", "initech", "initech.example", "web", "rails01.host.yml")
      Beryl::CLI::Fmt.host_fqdn(path).should eq("rails01.initech.example")
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
      Beryl::CLI::Fmt.in_scope?("/c/initech/_default.yml", "/c", "popi").should be_false
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

describe "Beryl::CLI::Fmt.write" do
  it "écrit un host.yml déjà rangé : clés triées à tous les niveaux, FQDN en tête" do
    dir = File.join(Dir.tempdir, "beryl-fmt-write-#{Random::Secure.hex(6)}")
    path = File.join(dir, "acme", "example.net", "web1.host.yml")
    Dir.mkdir_p(File.dirname(path))
    Beryl::CLI::Fmt.write(path, "ovh:\n  service_name: ns1.eu\n  ipv4: 1.2.3.4\nhardware:\n  cpu: X\n  cores: 4\n")
    File.read(path).should eq("# web1.example.net\n\nhardware:\n  cores: 4\n  cpu: X\n\novh:\n  ipv4: 1.2.3.4\n  service_name: ns1.eu\n")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
