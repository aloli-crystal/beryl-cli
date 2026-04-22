require "../../spec_helper"
require "../../../src/beryl/config"

# Pour les tests en lecture seule, on utilise des fixtures
# versionnées dans `spec/fixtures/env_file/*.yml`. Pour les tests qui
# ÉCRIVENT (save/merge), on utilise un dossier temporaire dédié au
# test qu'on nettoie après : versionner un fichier « après save »
# n'aurait pas de sens (la valeur écrite dépend de ce qu'on vient
# d'injecter en mémoire).
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
      env.domains.should be_empty
    end

    it "parse un fichier à 2 domaines" do
      env = Beryl::Config::EnvFile.load(fixture("two-domains.yml"))
      env.domains.sort.should eq(["aloli.net", "quimeo.fr"])
      env.for_domain("aloli.net")["OVH_APPLICATION_KEY"].should eq("aaa")
      env.for_domain("aloli.net")["SCW_SECRET_KEY"].should eq("ddd")
      env.for_domain("quimeo.fr")["OVH_APPLICATION_KEY"].should eq("eee")
      env.for_domain("inconnu.com").should be_empty
    end
  end

  describe "#apply_to_env" do
    it "injecte les variables du domaine dans ENV sans écraser celles du shell" do
      ENV["BERYL_TEST_EXISTING"] = "valeur_shell"
      begin
        env = Beryl::Config::EnvFile.load(fixture("apply-test.yml"))
        env.apply_to_env("aloli.net")

        ENV["BERYL_TEST_NEW"].should eq("valeur_fichier")
        ENV["BERYL_TEST_EXISTING"].should eq("valeur_shell") # préservée
      ensure
        ENV.delete("BERYL_TEST_NEW")
        ENV.delete("BERYL_TEST_EXISTING")
      end
    end

    it "ignore un domaine absent du fichier" do
      env = Beryl::Config::EnvFile.new("/mock", {} of String => Hash(String, String))
      env.apply_to_env("inconnu").should eq(0)
    end
  end

  describe "#save" do
    # Les tests d'écriture utilisent un chemin généré dans un
    # sous-dossier tmp/ sous le dépôt — ce n'est pas `/tmp` système
    # et c'est scoped au dépôt courant. `.gitignore` masque ce
    # dossier.
    tmp_dir = File.join(FIXTURES_ROOT, "..", "..", "..", "tmp", "env_file_tests")
    Dir.mkdir_p(tmp_dir)

    it "écrit un fichier valide avec chmod 0600" do
      path = File.join(tmp_dir, "save-chmod.yml")
      File.delete(path) if File.exists?(path)
      vars = {"OVH_APPLICATION_KEY" => "aaa", "SCW_SECRET_KEY" => "bbb"}
      env = Beryl::Config::EnvFile.new(path, {"aloli.net" => vars})
      env.save

      File.exists?(path).should be_true
      (File.info(path).permissions.value & 0o777).should eq(0o600)

      reloaded = Beryl::Config::EnvFile.load(path)
      reloaded.for_domain("aloli.net")["OVH_APPLICATION_KEY"].should eq("aaa")
      reloaded.for_domain("aloli.net")["SCW_SECRET_KEY"].should eq("bbb")

      File.delete(path) rescue nil
    end

    it "préserve les domaines existants lors du merge d'un nouveau" do
      path = File.join(tmp_dir, "save-merge.yml")
      File.delete(path) if File.exists?(path)
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
      path = File.join(tmp_dir, "save-quote.yml")
      File.delete(path) if File.exists?(path)
      env = Beryl::Config::EnvFile.new(path, {"d" => {"TOKEN" => "avec espaces", "SIMPLE" => "valeur"}})
      env.save

      content = File.read(path)
      content.should contain(%(TOKEN: "avec espaces"))
      content.should contain("SIMPLE: valeur")
      File.delete(path) rescue nil
    end
  end
end
