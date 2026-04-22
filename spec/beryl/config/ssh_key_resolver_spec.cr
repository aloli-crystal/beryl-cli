require "../../spec_helper"
require "../../../src/beryl/config"

# Fixtures ssh_keys versionnées (fichiers .pub factices).
private SSH_FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "ssh_keys"))

describe Beryl::Config do
  describe ".resolve_ssh_key" do
    it "retourne tel quel une clé inline (ssh-ed25519 ...)" do
      line = "ssh-ed25519 AAAA... philippe@aloli.fr"
      Beryl::Config.resolve_ssh_key(line, ssh_dir: SSH_FIXTURES).should eq(line)
    end

    it "retourne tel quel une clé inline (ssh-rsa ...)" do
      line = "ssh-rsa AAAAB3... foo@bar"
      Beryl::Config.resolve_ssh_key(line, ssh_dir: SSH_FIXTURES).should eq(line)
    end

    it "strip les espaces autour d'une clé inline" do
      Beryl::Config.resolve_ssh_key("  ssh-ed25519 AAAA key  ", ssh_dir: SSH_FIXTURES).should eq("ssh-ed25519 AAAA key")
    end

    it "lit un fichier .pub depuis ssh_dir pour un nom de fichier" do
      content = Beryl::Config.resolve_ssh_key("philippe.aloli.fr.pub", ssh_dir: SSH_FIXTURES)
      content.should start_with("ssh-ed25519")
      content.should contain("philippe@aloli.fr")
    end

    it "ignore les commentaires en tête du fichier .pub" do
      content = Beryl::Config.resolve_ssh_key("dev2.pub", ssh_dir: SSH_FIXTURES)
      content.should start_with("ssh-ed25519")
      content.should_not start_with("#")
    end

    it "lève SshKeyNotFound si le fichier est absent" do
      expect_raises(Beryl::Config::SshKeyNotFound, /introuvable/) do
        Beryl::Config.resolve_ssh_key("inexistante.pub", ssh_dir: SSH_FIXTURES)
      end
    end
  end

  describe ".resolve_ssh_keys" do
    it "résout une liste mixte (nom de fichier + inline)" do
      result = Beryl::Config.resolve_ssh_keys(
        ["philippe.aloli.fr.pub", "ssh-ed25519 AAAA inline"],
        ssh_dir: SSH_FIXTURES,
      )
      result[0].should contain("philippe@aloli.fr")
      result[1].should eq("ssh-ed25519 AAAA inline")
    end
  end
end

describe Beryl::Config::Root do
  describe "chargement avec clés par nom de fichier" do
    it "résout la clé domaine et les clés de host depuis les .pub" do
      fixtures_config = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "ssh-key-by-filename"))
      root = Beryl::Config::Root.load(fixtures_config, ssh_dir: SSH_FIXTURES)
      rh = root.resolve("rails01.aloli.net")
      users = rh.freebsd_hash[YAML::Any.new("users")].as_a

      admin = users.find { |u| u.as_h[YAML::Any.new("name")].as_s == "admin" }.not_nil!
      admin_keys = admin.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
      # admin hérite UNIQUEMENT de la clé domaine (lue depuis
      # philippe.aloli.fr.pub).
      admin_keys.size.should eq(1)
      admin_keys.first.should contain("philippe@aloli.fr")

      deploy = users.find { |u| u.as_h[YAML::Any.new("name")].as_s == "deploy" }.not_nil!
      deploy_keys = deploy.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
      # deploy a la clé domaine + dev2.pub référencée par le host
      deploy_keys.size.should eq(2)
      deploy_keys[0].should contain("philippe@aloli.fr")
      deploy_keys[1].should contain("dev2@aloli.fr")
    end
  end
end
