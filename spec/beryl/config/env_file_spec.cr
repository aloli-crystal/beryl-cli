require "../../spec_helper"
require "../../../src/beryl/config"

describe Beryl::Config::EnvFile do
  describe ".load" do
    it "retourne un EnvFile vide si le fichier n'existe pas" do
      env = Beryl::Config::EnvFile.load("/tmp/inexistant-beryl-env.yml")
      env.domains.should be_empty
    end

    it "parse un fichier à 2 domaines" do
      path = File.tempname("beryl-env-", ".yml")
      File.write(path, <<-YAML)
      aloli.net:
        OVH_APPLICATION_KEY: aaa
        OVH_APPLICATION_SECRET: bbb
        OVH_CONSUMER_KEY: ccc
        SCW_SECRET_KEY: ddd

      quimeo.fr:
        OVH_APPLICATION_KEY: eee
        OVH_APPLICATION_SECRET: fff
      YAML

      begin
        env = Beryl::Config::EnvFile.load(path)
        env.domains.sort.should eq(["aloli.net", "quimeo.fr"])
        env.for_domain("aloli.net")["OVH_APPLICATION_KEY"].should eq("aaa")
        env.for_domain("aloli.net")["SCW_SECRET_KEY"].should eq("ddd")
        env.for_domain("quimeo.fr")["OVH_APPLICATION_KEY"].should eq("eee")
        env.for_domain("inconnu.com").should be_empty
      ensure
        File.delete(path) rescue nil
      end
    end
  end

  describe "#apply_to_env" do
    it "injecte les variables du domaine dans ENV sans écraser celles du shell" do
      path = File.tempname("beryl-env-", ".yml")
      File.write(path, <<-YAML)
      aloli.net:
        BERYL_TEST_NEW: valeur_fichier
        BERYL_TEST_EXISTING: valeur_fichier
      YAML
      ENV["BERYL_TEST_EXISTING"] = "valeur_shell"

      begin
        env = Beryl::Config::EnvFile.load(path)
        env.apply_to_env("aloli.net")

        ENV["BERYL_TEST_NEW"].should eq("valeur_fichier")
        ENV["BERYL_TEST_EXISTING"].should eq("valeur_shell") # préservée
      ensure
        ENV.delete("BERYL_TEST_NEW")
        ENV.delete("BERYL_TEST_EXISTING")
        File.delete(path) rescue nil
      end
    end

    it "ignore un domaine absent du fichier" do
      env = Beryl::Config::EnvFile.new("/tmp/mock", {} of String => Hash(String, String))
      env.apply_to_env("inconnu").should eq(0)
    end
  end

  describe "#save" do
    it "écrit un fichier valide avec chmod 0600" do
      path = File.tempname("beryl-env-write-", ".yml")
      vars = {"OVH_APPLICATION_KEY" => "aaa", "SCW_SECRET_KEY" => "bbb"}
      env = Beryl::Config::EnvFile.new(path, {"aloli.net" => vars})
      env.save

      begin
        File.exists?(path).should be_true
        (File.info(path).permissions.value & 0o777).should eq(0o600)

        reloaded = Beryl::Config::EnvFile.load(path)
        reloaded.for_domain("aloli.net")["OVH_APPLICATION_KEY"].should eq("aaa")
        reloaded.for_domain("aloli.net")["SCW_SECRET_KEY"].should eq("bbb")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "préserve les domaines existants lors du merge d'un nouveau" do
      path = File.tempname("beryl-env-merge-", ".yml")
      begin
        # Premier domaine
        env1 = Beryl::Config::EnvFile.new(path, {"aloli.net" => {"K1" => "v1"}})
        env1.save

        # Relecture + ajout d'un autre domaine
        env2 = Beryl::Config::EnvFile.load(path)
        env2.set_domain("quimeo.fr", {"K2" => "v2"})
        env2.save

        # Relecture finale : les deux sont là
        env3 = Beryl::Config::EnvFile.load(path)
        env3.domains.sort.should eq(["aloli.net", "quimeo.fr"])
      ensure
        File.delete(path) rescue nil
      end
    end

    it "quote les valeurs avec espaces ou caractères spéciaux" do
      path = File.tempname("beryl-env-quote-", ".yml")
      env = Beryl::Config::EnvFile.new(path, {"d" => {"TOKEN" => "avec espaces", "SIMPLE" => "valeur"}})
      env.save

      begin
        content = File.read(path)
        content.should contain(%(TOKEN: "avec espaces"))
        content.should contain("SIMPLE: valeur")
      ensure
        File.delete(path) rescue nil
      end
    end
  end
end
