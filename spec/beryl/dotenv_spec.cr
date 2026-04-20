require "../spec_helper"
require "../../src/beryl/dotenv"
require "file_utils"

describe Beryl::Dotenv do
  describe ".parse" do
    it "parse des paires simples KEY=VALUE" do
      h = Beryl::Dotenv.parse("FOO=bar\nBAZ=qux\n")
      h["FOO"].should eq("bar")
      h["BAZ"].should eq("qux")
    end

    it "ignore lignes vides et commentaires" do
      h = Beryl::Dotenv.parse("# commentaire\n\nFOO=bar\n# autre\n")
      h.size.should eq(1)
      h["FOO"].should eq("bar")
    end

    it "accepte le préfixe 'export ' (compat source bash)" do
      h = Beryl::Dotenv.parse("export FOO=bar\n")
      h["FOO"].should eq("bar")
    end

    it "déséchappe les séquences dans les guillemets doubles" do
      h = Beryl::Dotenv.parse(%(LINE="a\\nb\\tc"))
      h["LINE"].should eq("a\nb\tc")
    end

    it "conserve le contenu littéral dans les guillemets simples" do
      h = Beryl::Dotenv.parse(%(LIT='a\\nb'))
      h["LIT"].should eq("a\\nb")
    end

    it "retire les commentaires de fin de ligne sur valeurs non quotées" do
      h = Beryl::Dotenv.parse("FOO=bar # commentaire\n")
      h["FOO"].should eq("bar")
    end

    it "ne retire pas les `#` internes aux valeurs quotées" do
      h = Beryl::Dotenv.parse(%(FOO="bar # contenu"))
      h["FOO"].should eq("bar # contenu")
    end

    it "ignore une ligne sans signe égal" do
      h = Beryl::Dotenv.parse("PAS_DE_EGAL\nFOO=bar\n")
      h.size.should eq(1)
      h["FOO"].should eq("bar")
    end

    it "autorise un signe égal dans la valeur" do
      h = Beryl::Dotenv.parse("SIG=secret=abc=123\n")
      h["SIG"].should eq("secret=abc=123")
    end
  end

  describe ".load" do
    it "silencieux si le fichier n'existe pas" do
      Beryl::Dotenv.load("/tmp/beryl-dotenv-absent-#{Random.rand(100_000)}.env").should eq(0)
    end

    it "pose les variables dans ENV mais n'écrase pas par défaut" do
      path = File.tempfile("beryl-dotenv", ".env") do |f|
        f.print "BERYL_TEST_NEW=poseur\nBERYL_TEST_EXISTING=nouveau\n"
      end
      begin
        ENV.delete("BERYL_TEST_NEW")
        ENV["BERYL_TEST_EXISTING"] = "ancien"

        posed = Beryl::Dotenv.load(path.path)
        posed.should eq(1)
        ENV["BERYL_TEST_NEW"].should eq("poseur")
        ENV["BERYL_TEST_EXISTING"].should eq("ancien")
      ensure
        path.delete
        ENV.delete("BERYL_TEST_NEW")
        ENV.delete("BERYL_TEST_EXISTING")
      end
    end

    it "overwrite: true écrase bien les variables existantes" do
      path = File.tempfile("beryl-dotenv", ".env") do |f|
        f.print "BERYL_TEST_OW=nouveau\n"
      end
      begin
        ENV["BERYL_TEST_OW"] = "ancien"
        Beryl::Dotenv.load(path.path, overwrite: true)
        ENV["BERYL_TEST_OW"].should eq("nouveau")
      ensure
        path.delete
        ENV.delete("BERYL_TEST_OW")
      end
    end
  end
end
