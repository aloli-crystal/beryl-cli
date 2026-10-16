require "../../spec_helper"

private RECIPES_ROOT = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes"))
private CENTRAL_DIR  = File.join(RECIPES_ROOT, "central", "recipes")

private def resolve(*names : String) : Array(Beryl::Apply::Recipe)
  Beryl::Apply::Resolver.new(CENTRAL_DIR).resolve(names.to_a)
end

describe Beryl::Apply::Resolver do
  it "retourne une liste vide si aucune recette d'entrée" do
    Beryl::Apply::Resolver.new(CENTRAL_DIR).resolve([] of String).should be_empty
  end

  it "résout la fermeture transitive et trie en ordre topologique" do
    order = resolve("post-install").map(&.name)
    # base-packages avant ses dépendants ; post-install en dernier.
    order.should eq(["base-packages", "freebsd-updates", "shell-tools", "post-install"])
  end

  it "dédup une recette requise par plusieurs (base-packages une seule fois)" do
    resolve("post-install").map(&.name).count("base-packages").should eq(1)
  end

  it "résout plusieurs recettes d'entrée (apply_recipes cumulés)" do
    # Deux entrées indépendantes → union dédupliquée, ordre topo global.
    names = resolve("shell-tools", "freebsd-updates").map(&.name)
    names.should contain("base-packages")
    names.should contain("shell-tools")
    names.should contain("freebsd-updates")
  end

  it "détecte un cycle de dépendances" do
    expect_raises(Beryl::Apply::Resolver::Cycle, /cycle-a|cycle-b/) do
      resolve("cycle-a")
    end
  end

  it "lève RecipeNotFound en nommant le requérant" do
    expect_raises(Beryl::Apply::Resolver::RecipeNotFound, /requise par `needs-missing`/) do
      resolve("needs-missing")
    end
  end

  describe "chemin de recherche (privé société > générique)" do
    private_dir = File.join(RECIPES_ROOT, "private", "recipes")

    it "le dossier privé (en tête) SURCHARGE une recette générique du même nom" do
      recipes = Beryl::Apply::Resolver.new([private_dir, CENTRAL_DIR]).resolve(["base-packages"])
      recipes.size.should eq(1)
      bp = recipes.first
      bp.name.should eq("base-packages")
      bp.description.should contain("PRIVE") # version privée, pas la générique
      bp.source_path.should contain("/private/")
    end

    it "résout une recette PRIVÉE absente du générique (+ sa dépendance générique en fallback)" do
      recipes = Beryl::Apply::Resolver.new([private_dir, CENTRAL_DIR]).resolve(["private-only"])
      recipes.map(&.name).should eq(["base-packages", "private-only"]) # dep d'abord
    end

    it "tombe sur le générique (fallback) pour une recette absente du privé" do
      recipes = Beryl::Apply::Resolver.new([private_dir, CENTRAL_DIR]).resolve(["shell-tools"])
      recipes.map(&.name).should contain("shell-tools")
      recipes.find! { |r| r.name == "shell-tools" }.source_path.should contain("/central/")
    end

    it "RecipeNotFound liste TOUS les dossiers cherchés" do
      expect_raises(Beryl::Apply::Resolver::RecipeNotFound, /private.*\n.*central|central.*\n.*private/m) do
        Beryl::Apply::Resolver.new([private_dir, CENTRAL_DIR]).resolve(["inexistante-xyz"])
      end
    end
  end
end

# Dossier temporaire de recettes (nom → contenu YAML), pour les specs `order:`.
private def with_recipes(files : Hash(String, String), &)
  dir = File.join(Dir.tempdir, "beryl-order-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  files.each { |name, yaml| File.write(File.join(dir, "#{name}.recipe.yml"), yaml) }
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "Beryl::Apply::Resolver — order:" do
  it "sans order:, deux dépendances indépendantes sortent par ordre alphabétique" do
    with_recipes({
      "nginx"  => "steps: []\n",
      "repo"   => "steps: []\n",
      "maison" => "requires: [nginx, repo]\nsteps: []\n",
    }) do |dir|
      Beryl::Apply::Resolver.new(dir).resolve(["maison"]).map(&.name).should eq(["nginx", "repo", "maison"])
    end
  end

  it "order: fait passer le dépôt avant la recette qui installe son paquet" do
    with_recipes({
      "nginx"  => "steps: []\n",
      "repo"   => "steps: []\n",
      "maison" => "requires: [nginx, repo]\norder: [repo, nginx]\nsteps: []\n",
    }) do |dir|
      Beryl::Apply::Resolver.new(dir).resolve(["maison"]).map(&.name).should eq(["repo", "nginx", "maison"])
    end
  end

  it "order: s'applique aussi quand une autre recette requiert la même dépendance" do
    with_recipes({
      "nginx"  => "steps: []\n",
      "repo"   => "steps: []\n",
      "maison" => "requires: [nginx, repo]\norder: [repo, nginx]\nsteps: []\n",
      "site"   => "requires: [nginx]\nsteps: []\n",
    }) do |dir|
      names = Beryl::Apply::Resolver.new(dir).resolve(["site", "maison"]).map(&.name)
      names.index!("repo").should be < names.index!("nginx")
    end
  end

  it "order: contraire à un requires → Cycle" do
    with_recipes({
      "nginx"  => "requires: [repo]\nsteps: []\n",
      "repo"   => "steps: []\n",
      "maison" => "requires: [nginx, repo]\norder: [nginx, repo]\nsteps: []\n",
    }) do |dir|
      expect_raises(Beryl::Apply::Resolver::Cycle) do
        Beryl::Apply::Resolver.new(dir).resolve(["maison"])
      end
    end
  end

  it "order: accepte les dépendances en forme map de requires:" do
    with_recipes({
      "nginx"  => "parameters:\n  package:\n    type: string\n    default: x\nsteps: []\n",
      "repo"   => "steps: []\n",
      "maison" => "requires:\n  - nginx: { package: y }\n  - repo\norder: [repo, nginx]\nsteps: []\n",
    }) do |dir|
      Beryl::Apply::Resolver.new(dir).resolve(["maison"]).map(&.name).should eq(["repo", "nginx", "maison"])
    end
  end

  it "refuse un nom de order: absent de requires:" do
    with_recipes({"maison" => "requires: [repo]\norder: [repo, nginx]\nsteps: []\n"}) do |dir|
      expect_raises(Beryl::Apply::Recipe::InvalidRecipe, /`order: nginx` absent de `requires:`/) do
        Beryl::Apply::Recipe.load(File.join(dir, "maison.recipe.yml"))
      end
    end
  end

  it "refuse un doublon dans order:" do
    with_recipes({"maison" => "requires: [repo]\norder: [repo, repo]\nsteps: []\n"}) do |dir|
      expect_raises(Beryl::Apply::Recipe::InvalidRecipe, /en double/) do
        Beryl::Apply::Recipe.load(File.join(dir, "maison.recipe.yml"))
      end
    end
  end
end
