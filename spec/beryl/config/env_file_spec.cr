require "../../spec_helper"
require "../../../src/beryl/config"

# Pour les tests en lecture seule, on utilise des fixtures
# versionnées dans `spec/fixtures/env_file/*.yml`. Pour les tests qui
# ÉCRIVENT (save/merge), on utilise un dossier temporaire dédié.
private FIXTURES_ROOT = File.expand_path(
  File.join(__DIR__, "..", "..", "fixtures", "env_file"),
)

private def fixture(name : String) : String
  File.join(FIXTURES_ROOT, name)
end

describe Beryl::Config::EnvFile do
  describe ".load" do
    it "retourne un EnvFile vide si le fichier n'existe pas" do
      env = Beryl::Config::EnvFile.load(File.join(FIXTURES_ROOT, "NE-EXISTE-PAS.yml"))
      env.accounts.should be_empty
    end

    it "parse un fichier à 2 sociétés avec plusieurs fournisseurs" do
      env = Beryl::Config::EnvFile.load(fixture("two-accounts.yml"))
      env.accounts.sort.should eq(["aloli", "quimeo"])
      env.providers_for("aloli").sort.should eq(["ovh", "scaleway"])
      env.for_account_provider("aloli", "ovh")["OVH_APPLICATION_KEY"].should eq("aaa")
      env.for_account_provider("aloli", "scaleway")["SCW_SECRET_KEY"].should eq("ddd")
      env.for_account_provider("quimeo", "ovh")["OVH_APPLICATION_KEY"].should eq("eee")
      env.for_account_provider("inconnu", "ovh").should be_empty
    end
  end

  describe "#apply_to_env" do
    it "injecte les variables (account, provider) dans ENV sans écraser le shell" do
      ENV["BERYL_TEST_EXISTING"] = "valeur_shell"
      begin
        env = Beryl::Config::EnvFile.load(fixture("apply-test.yml"))
        env.apply_to_env("aloli", "ovh")

        ENV["BERYL_TEST_NEW"].should eq("valeur_fichier")
        ENV["BERYL_TEST_EXISTING"].should eq("valeur_shell") # préservée
      ensure
        ENV.delete("BERYL_TEST_NEW")
        ENV.delete("BERYL_TEST_EXISTING")
      end
    end

    it "ignore un couple (account, provider) absent du fichier" do
      env = Beryl::Config::EnvFile.new("/mock", Beryl::Config::EnvFile::Data.new)
      env.apply_to_env("inconnu", "ovh").should eq(0)
    end
  end

  describe "#apply_all_to_env" do
    it "injecte toutes les vars de tous les fournisseurs d'une société" do
      path = File.join(FIXTURES_ROOT, "apply-all-test.yml")
      File.write(path, <<-YAML
      aloli:
        ovh:
          BERYL_TEST_OVH: a
        scaleway:
          BERYL_TEST_SCW: b
      YAML
      )
      begin
        env = Beryl::Config::EnvFile.load(path)
        count = env.apply_all_to_env("aloli", overwrite: true)
        count.should eq(2)
        ENV["BERYL_TEST_OVH"].should eq("a")
        ENV["BERYL_TEST_SCW"].should eq("b")
      ensure
        ENV.delete("BERYL_TEST_OVH")
        ENV.delete("BERYL_TEST_SCW")
        File.delete(path) rescue nil
      end
    end
  end

  describe "#save" do
    tmp_dir = File.join(FIXTURES_ROOT, "..", "..", "..", "tmp", "env_file_tests")
    Dir.mkdir_p(tmp_dir)

    it "écrit un fichier valide avec chmod 0600" do
      path = File.join(tmp_dir, "save-chmod.yml")
      File.delete(path) if File.exists?(path)
      data = Beryl::Config::EnvFile::Data.new
      data["aloli"] = {"ovh" => {"OVH_APPLICATION_KEY" => "aaa", "SCW_SECRET_KEY" => "bbb"}}
      env = Beryl::Config::EnvFile.new(path, data)
      env.save

      File.exists?(path).should be_true
      (File.info(path).permissions.value & 0o777).should eq(0o600)

      reloaded = Beryl::Config::EnvFile.load(path)
      reloaded.for_account_provider("aloli", "ovh")["OVH_APPLICATION_KEY"].should eq("aaa")
      reloaded.for_account_provider("aloli", "ovh")["SCW_SECRET_KEY"].should eq("bbb")

      File.delete(path) rescue nil
    end

    it "préserve les sociétés existantes lors du merge d'une nouvelle" do
      path = File.join(tmp_dir, "save-merge.yml")
      File.delete(path) if File.exists?(path)
      begin
        # Première société
        data = Beryl::Config::EnvFile::Data.new
        data["aloli"] = {"ovh" => {"K1" => "v1"}}
        env1 = Beryl::Config::EnvFile.new(path, data)
        env1.save

        # Relecture + ajout d'une autre société
        env2 = Beryl::Config::EnvFile.load(path)
        env2.set_account_provider("quimeo", "ovh", {"K2" => "v2"})
        env2.save

        # Relecture finale : les deux sont là
        env3 = Beryl::Config::EnvFile.load(path)
        env3.accounts.sort.should eq(["aloli", "quimeo"])
      ensure
        File.delete(path) rescue nil
      end
    end

    it "quote les valeurs avec espaces ou caractères spéciaux" do
      path = File.join(tmp_dir, "save-quote.yml")
      File.delete(path) if File.exists?(path)
      data = Beryl::Config::EnvFile::Data.new
      data["aloli"] = {"ovh" => {"TOKEN" => "avec espaces", "SIMPLE" => "valeur"}}
      env = Beryl::Config::EnvFile.new(path, data)
      env.save

      content = File.read(path)
      content.should contain(%(TOKEN: "avec espaces"))
      content.should contain("SIMPLE: valeur")
      File.delete(path) rescue nil
    end
  end
end
