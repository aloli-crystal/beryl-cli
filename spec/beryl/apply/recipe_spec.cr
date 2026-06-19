require "../../spec_helper"

private CENTRAL = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes", "central", "recipes"))

private def central(name : String) : String
  File.join(CENTRAL, "#{name}.recipe.yml")
end

describe Beryl::Apply::Recipe do
  describe ".load" do
    it "parse une recette feuille (description + steps)" do
      r = Beryl::Apply::Recipe.load(central("base-packages"))
      r.name.should eq("base-packages")
      r.description.should eq("Packages de base communs à tous les hosts.")
      r.requires.should be_empty
      r.steps.size.should eq(1)
      r.steps.first.name.should eq("pkg-install")
      r.steps.first.params["packages"].as_a.map(&.as_s).should eq(["bash", "git", "curl"])
      r.requires_vrack.should be_false # défaut
    end

    it "parse `requires_vrack: true`" do
      path = File.join(Dir.tempdir, "needs-vrack.recipe.yml")
      File.write(path, "description: x\nrequires_vrack: true\nsteps:\n  - pkg-install: { packages: [git] }\n")
      begin
        Beryl::Apply::Recipe.load(path).requires_vrack.should be_true
      ensure
        File.delete(path)
      end
    end

    it "parse les requires d'une recette agrégat sans steps" do
      r = Beryl::Apply::Recipe.load(central("post-install"))
      r.requires.should eq(["freebsd-updates", "base-packages", "shell-tools"])
      r.steps.should be_empty
    end

    it "parse parameters et arguments" do
      r = Beryl::Apply::Recipe.load(central("recorder"))
      r.parameters.has_key?("greeting").should be_true
      r.arguments["greeting"].as_s.should eq("salut")
    end

    it "lève InvalidRecipe si recipe: ne correspond pas au nom de fichier" do
      expect_raises(Beryl::Apply::Recipe::InvalidRecipe, /ne correspond pas/) do
        Beryl::Apply::Recipe.load(central("bad-name"))
      end
    end
  end
end
