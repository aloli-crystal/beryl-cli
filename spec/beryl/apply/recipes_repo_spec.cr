require "../../spec_helper"
require "../../../src/beryl/apply"

# Recettes du dépôt `beryl-recipes`, quand il est cloné à côté de beryl-cli
# (dossier ombrelle `beryl/`) : chacune doit se charger avec le VRAI chargeur
# de beryl, n'appeler que des primitives connues et ne requérir que des
# recettes du dépôt. Attrape avant le commit une recette que `beryl sync`
# refuserait sur tout le parc (YAML invalide, vu le 27 oct. 2026 sur
# `sshd-vrack-only`). Dépôt absent (CI de beryl-cli seul) : test sauté.
private RECIPES_REPO = File.expand_path(File.join(__DIR__, "..", "..", "..", "..", "beryl-recipes", "recipes"))

private def repo_recipe_files : Array(String)
  Dir.glob(File.join(RECIPES_REPO, "**", "*#{Beryl::Apply::Recipe::SUFFIX}")).sort
end

describe "Recettes du dépôt beryl-recipes" do
  if Dir.exists?(RECIPES_REPO)
    it "se chargent toutes, primitives connues, `requires:` résolus dans le dépôt" do
      files = repo_recipe_files
      files.should_not be_empty
      errors = [] of String
      recipes = files.compact_map do |path|
        Beryl::Apply::Recipe.load(path)
      rescue ex
        errors << ex.message.to_s
        nil
      end
      names = recipes.map(&.name).to_set
      recipes.each do |r|
        r.steps.each do |step|
          errors << "#{r.name} : primitive `#{step.name}` inconnue" unless Beryl::Apply::Primitive[step.name]?
        end
        r.requires.each do |dep|
          errors << "#{r.name} : requiert `#{dep}`, absente du dépôt" unless names.includes?(dep)
        end
      end
      errors.should eq [] of String
    end
  else
    pending "dépôt beryl-recipes absent (#{RECIPES_REPO})"
  end
end
