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
      env.accounts.sort.should eq(["aloli", "popi"])
      env.providers_for("aloli").sort.should eq(["ovh", "scaleway"])
      env.for_account_provider("aloli", "ovh")["OVH_APPLICATION_KEY"].should eq("aaa")
      env.for_account_provider("aloli", "scaleway")["SCW_SECRET_KEY"].should eq("ddd")
      env.for_account_provider("popi", "ovh")["OVH_APPLICATION_KEY"].should eq("eee")
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
        env2.set_account_provider("popi", "ovh", {"K2" => "v2"})
        env2.save

        # Relecture finale : les deux sont là
        env3 = Beryl::Config::EnvFile.load(path)
        env3.accounts.sort.should eq(["aloli", "popi"])
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

  describe ".parse_vault_toml" do
    it "parse un coffre TOML à un seul provider" do
      providers = Beryl::Config::EnvFile.parse_vault_toml(<<-TOML
        [ovh]
        OVH_APPLICATION_KEY = "aaa"
        OVH_APPLICATION_SECRET = "bbb"
        OVH_CONSUMER_KEY = "ccc"
        TOML
      )
      providers.keys.should eq(["ovh"])
      providers["ovh"]["OVH_APPLICATION_KEY"].should eq("aaa")
      providers["ovh"]["OVH_APPLICATION_SECRET"].should eq("bbb")
    end

    it "parse plusieurs providers triés et sépare correctement" do
      providers = Beryl::Config::EnvFile.parse_vault_toml(<<-TOML
        [ovh]
        OVH_APPLICATION_KEY = "aaa"

        [scaleway]
        SCW_SECRET_KEY = "xxx"

        [dedibox]
        DEDIBOX_TOKEN = "ddd"
        TOML
      )
      providers.keys.sort.should eq(["dedibox", "ovh", "scaleway"])
      providers["scaleway"]["SCW_SECRET_KEY"].should eq("xxx")
      providers["dedibox"]["DEDIBOX_TOKEN"].should eq("ddd")
    end

    it "retourne un hash vide pour un TOML vide" do
      Beryl::Config::EnvFile.parse_vault_toml("").should be_empty
    end

    it "ignore les non-strings (laisser passer un futur TOML plus riche sans crasher)" do
      providers = Beryl::Config::EnvFile.parse_vault_toml(<<-TOML
        [ovh]
        OVH_APPLICATION_KEY = "ok"
        SOME_INT = 42
        TOML
      )
      providers["ovh"].keys.should eq(["OVH_APPLICATION_KEY"])
      providers["ovh"]["OVH_APPLICATION_KEY"].should eq("ok")
    end
  end

  describe ".serialize_account_to_toml" do
    it "produit du TOML déterministe trié par provider puis par variable" do
      providers = {
        "scaleway" => {"SCW_SECRET_KEY" => "zzz"},
        "ovh"      => {"OVH_CONSUMER_KEY" => "ccc", "OVH_APPLICATION_KEY" => "aaa"},
      } of String => Hash(String, String)
      toml = Beryl::Config::EnvFile.serialize_account_to_toml(providers)

      # OVH avant Scaleway (alphabétique).
      ovh_idx = toml.index!("[ovh]")
      scw_idx = toml.index!("[scaleway]")
      ovh_idx.should be < scw_idx

      # APP_KEY avant CONSUMER_KEY dans [ovh].
      app_idx = toml.index!("OVH_APPLICATION_KEY")
      con_idx = toml.index!("OVH_CONSUMER_KEY")
      app_idx.should be < con_idx
    end

    it "round-trip : parse(serialize(x)) == x pour des chaînes simples" do
      providers = {
        "ovh"      => {"OVH_APPLICATION_KEY" => "aaa", "OVH_APPLICATION_SECRET" => "bbb"},
        "scaleway" => {"SCW_SECRET_KEY" => "xxx"},
      } of String => Hash(String, String)
      toml = Beryl::Config::EnvFile.serialize_account_to_toml(providers)
      parsed = Beryl::Config::EnvFile.parse_vault_toml(toml)
      parsed.should eq(providers)
    end

    it "échappe correctement les guillemets et antislashes" do
      providers = {
        "ovh" => {"WEIRD" => %(value with "quotes" and \\backslash)},
      } of String => Hash(String, String)
      toml = Beryl::Config::EnvFile.serialize_account_to_toml(providers)
      parsed = Beryl::Config::EnvFile.parse_vault_toml(toml)
      parsed["ovh"]["WEIRD"].should eq(%(value with "quotes" and \\backslash))
    end
  end

  describe "#set_account / #clear_account" do
    it "remplace en bloc une section société" do
      env = Beryl::Config::EnvFile.new("/mock", Beryl::Config::EnvFile::Data.new)
      env.set_account("aloli", {"ovh" => {"K" => "v"}} of String => Hash(String, String))
      env.providers_for("aloli").should eq(["ovh"])

      # set_account écrase complètement
      env.set_account("aloli", {"scaleway" => {"K2" => "v2"}} of String => Hash(String, String))
      env.providers_for("aloli").should eq(["scaleway"])
    end

    it "clear_account supprime toute trace de la société" do
      env = Beryl::Config::EnvFile.new("/mock", Beryl::Config::EnvFile::Data.new)
      env.set_account_provider("aloli", "ovh", {"K" => "v"})
      env.set_account_provider("popi", "ovh", {"K" => "v"})
      env.clear_account("aloli")
      env.accounts.should eq(["popi"])
    end
  end
end
