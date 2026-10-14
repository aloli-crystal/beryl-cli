require "file_utils"
require "../../spec_helper"
require "../../support/fake_shell"

private CENTRAL = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes", "central", "recipes"))

private def central_recipe(name : String) : Beryl::Apply::Recipe
  Beryl::Apply::Recipe.load(File.join(CENTRAL, "#{name}.recipe.yml"))
end

# Primitive de test : enregistre les params reçus (interpolés) et
# annonce `applied`. Enregistrée une fois dans le registre global.
class TestRecorder < Beryl::Apply::Primitive
  class_property last_params = {} of String => YAML::Any

  def name : String
    "test-record"
  end

  def apply(shell : Beryl::Apply::Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Beryl::Apply::Context) : Beryl::Apply::StepResult
    TestRecorder.last_params = params
    Beryl::Apply::StepResult.applied("recorded")
  end
end

Beryl::Apply::Primitive.register(TestRecorder.new)

# Primitive de test : ne change jamais rien (skipped).
class TestNoop < Beryl::Apply::Primitive
  def name : String
    "test-noop"
  end

  def apply(shell : Beryl::Apply::Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Beryl::Apply::Context) : Beryl::Apply::StepResult
    Beryl::Apply::StepResult.skipped("rien à faire")
  end
end

Beryl::Apply::Primitive.register(TestNoop.new)

# Recette écrite dans un fichier temporaire nommé comme elle (`<nom>.recipe.yml`,
# exigé par `Recipe.load`).
private def recipe_from(yaml : String) : Beryl::Apply::Recipe
  name = yaml[/\Arecipe: (\S+)/, 1]
  dir = File.tempname("beryl-recipes")
  Dir.mkdir_p(dir)
  path = File.join(dir, "#{name}.recipe.yml")
  File.write(path, yaml)
  Beryl::Apply::Recipe.load(path)
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Beryl::Apply::Executor do
  it "exécute les steps et agrège le rapport" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "") # rien d'installé → tout à installer
    recipes = [central_recipe("base-packages"), central_recipe("freebsd-updates")]
    report = Beryl::Apply::Executor.new(shell, dry_run: false).run(recipes)
    report.total.should eq(2)
    report.applied.should eq(2)
    report.failed.should eq(0)
    shell.ran?(/pkg install -y/).should be_true
  end

  it "n'applique rien en dry-run" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "")
    report = Beryl::Apply::Executor.new(shell, dry_run: true).run([central_recipe("base-packages")])
    report.applied.should eq(1)
    shell.ran?(/pkg install/).should be_false
  end

  it "mappe une valeur positionnelle sur le paramètre `positional:` (forme `- recipe: val`)" do
    shell = FakeShell.new
    recipe = Beryl::Apply::Recipe.new(
      name: "pos-test",
      description: "",
      requires: [] of String,
      parameters: {} of String => YAML::Any,
      arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new("test-record", {"value" => YAML::Any.new("{{ target }}")})],
      source_path: "/tmp/pos-test.recipe.yml",
      positional: "target",
    )
    args = {"pos-test" => [{Beryl::Apply::Recipe::POSITIONAL_ARG => "htop"}]}
    Beryl::Apply::Executor.new(shell, dry_run: false).run([recipe], args)
    TestRecorder.last_params["value"].as_s.should eq("htop")
  end

  it "from_env : défaut depuis le coffre (ENV), surchargeable positionnellement" do
    begin
      ENV["TEST_RELAY_TO"] = "it@popi.fr"
      shell = FakeShell.new
      recipe = Beryl::Apply::Recipe.new(
        name: "fe-test",
        description: "",
        requires: [] of String,
        parameters: {"dest" => YAML.parse("from_env: TEST_RELAY_TO\ndefault: \"\"")},
        arguments: {} of String => YAML::Any,
        steps: [Beryl::Apply::Step.new("test-record", {"value" => YAML::Any.new("{{ dest }}")})],
        source_path: "/tmp/fe-test.recipe.yml",
        positional: "dest",
      )
      # Recette nue → valeur du coffre.
      Beryl::Apply::Executor.new(shell, dry_run: false).run([recipe], {"fe-test" => [{} of String => String]})
      TestRecorder.last_params["value"].as_s.should eq("it@popi.fr")
      # Valeur positionnelle → surcharge le coffre.
      Beryl::Apply::Executor.new(shell, dry_run: false).run(
        [recipe], {"fe-test" => [{Beryl::Apply::Recipe::POSITIONAL_ARG => "autre@x.fr"}]})
      TestRecorder.last_params["value"].as_s.should eq("autre@x.fr")
    ensure
      ENV.delete("TEST_RELAY_TO")
    end
  end

  it "résout une variable built-in dans un `default:` (ex. ip défaut = {{ vrack_ip }})" do
    shell = FakeShell.new
    recipe = Beryl::Apply::Recipe.new(
      name: "bi-default",
      description: "",
      requires: [] of String,
      parameters: {"ip" => YAML.parse("default: \"{{ vrack_ip }}\"")},
      arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new("test-record", {"value" => YAML::Any.new("{{ ip }}")})],
      source_path: "/tmp/bi-default.recipe.yml",
      positional: nil,
    )
    ctx = Beryl::Apply::Context.new(vars: {"vrack_ip" => "192.168.42.4"})
    Beryl::Apply::Executor.new(shell, dry_run: false, context: ctx).run([recipe])
    TestRecorder.last_params["value"].as_s.should eq("192.168.42.4")
  end

  it "résout une variable built-in dans un argument apply_recipes" do
    shell = FakeShell.new
    recipe = Beryl::Apply::Recipe.new(
      name: "bi-arg",
      description: "",
      requires: [] of String,
      parameters: {} of String => YAML::Any,
      arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new("test-record", {"value" => YAML::Any.new("{{ ip }}")})],
      source_path: "/tmp/bi-arg.recipe.yml",
      positional: nil,
    )
    ctx = Beryl::Apply::Context.new(vars: {"vrack_ip" => "192.168.42.9"})
    Beryl::Apply::Executor.new(shell, dry_run: false, context: ctx).run(
      [recipe], {"bi-arg" => [{"ip" => "{{ vrack_ip }}"}]})
    TestRecorder.last_params["value"].as_s.should eq("192.168.42.9")
  end

  it "interpole {{ var }} DANS les éléments d'une liste (ex. domains)" do
    shell = FakeShell.new
    recipe = Beryl::Apply::Recipe.new(
      name: "list-interp",
      description: "",
      requires: [] of String,
      parameters: {} of String => YAML::Any,
      arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new("test-record",
        {"names" => YAML.parse("[\"{{ hostname }}.globex.example\", \"{{ hostname }}.initech.example\"]")})],
      source_path: "/tmp/list-interp.recipe.yml",
      positional: nil,
    )
    ctx = Beryl::Apply::Context.new(vars: {"hostname" => "pkg"})
    Beryl::Apply::Executor.new(shell, dry_run: false, context: ctx).run([recipe])
    TestRecorder.last_params["names"].as_a.map(&.as_s).should eq(["pkg.globex.example", "pkg.initech.example"])
  end

  it "interpole {{ var }} depuis arguments (qui priment sur parameters.default)" do
    shell = FakeShell.new
    Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("recorder")])
    TestRecorder.last_params["msg"].as_s.should eq("salut le monde")
  end

  it "les arguments fournis par l'hôte (apply_recipes map) priment sur ceux de la recette" do
    shell = FakeShell.new
    # La fixture recorder utilise la variable `greeting` (default bonjour,
    # argument salut). L'argument hôte doit primer → "coucou le monde".
    host_args = {"recorder" => [{"greeting" => "coucou"}]}
    Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("recorder")], host_args)
    TestRecorder.last_params["msg"].as_s.should eq("coucou le monde")
  end

  it "joue une recette N fois pour N jeux d'arguments (fan-out user: [a, b])" do
    shell = FakeShell.new
    host_args = {"recorder" => [{"greeting" => "un"}, {"greeting" => "deux"}]}
    report = Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("recorder")], host_args)
    report.total.should eq(2)                                       # recorder (1 step) joué 2 fois
    TestRecorder.last_params["msg"].as_s.should eq("deux le monde") # dernier combo
  end

  describe "option d'étape if_changed" do
    it "saute l'étape quand rien n'a changé avant dans la recette" do
      r = recipe_from("recipe: t\ndescription: t\nsteps:\n  - test-noop: {}\n  - test-record: { if_changed: true, a: \"1\" }\n")
      TestRecorder.last_params = {} of String => YAML::Any
      report = Beryl::Apply::Executor.new(FakeShell.new).run([r])
      report.applied.should eq(0)
      TestRecorder.last_params.should be_empty # jamais appelée
    end

    it "joue l'étape quand une étape précédente a changé quelque chose" do
      r = recipe_from("recipe: t\ndescription: t\nsteps:\n  - test-record: { a: \"1\" }\n  - test-record: { if_changed: true, a: \"2\" }\n")
      report = Beryl::Apply::Executor.new(FakeShell.new).run([r])
      report.applied.should eq(2)
      TestRecorder.last_params["a"].as_s.should eq("2")
      TestRecorder.last_params.has_key?("if_changed").should be_false # option retirée avant la primitive
    end

    it "le suivi des changements repart de zéro à chaque recette" do
      r1 = recipe_from("recipe: r1\ndescription: t\nsteps:\n  - test-record: { a: \"1\" }\n")
      r2 = recipe_from("recipe: r2\ndescription: t\nsteps:\n  - test-record: { if_changed: true, a: \"2\" }\n")
      report = Beryl::Apply::Executor.new(FakeShell.new).run([r1, r2])
      report.applied.should eq(1)
    end
  end

  it "lève UnknownPrimitive pour un step inconnu" do
    shell = FakeShell.new
    recipe = Beryl::Apply::Recipe.new(
      name: "bidon",
      description: "",
      requires: [] of String,
      parameters: {} of String => YAML::Any,
      arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new(name: "primitive-fantome", params: {} of String => YAML::Any)],
      source_path: "<test>",
    )
    expect_raises(Beryl::Apply::UnknownPrimitive, /primitive-fantome/) do
      Beryl::Apply::Executor.new(shell, dry_run: false).run([recipe])
    end
  end

  it "marque failed et stoppe net sur échec de commande" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "")
    shell.stub(/pkg install/, exit_code: 1, stderr: "boom")
    report = Beryl::Apply::Executor.new(shell, dry_run: false).run([central_recipe("base-packages")])
    report.failed.should eq(1)
  end
end

describe "Beryl::Apply::Executor — requires en forme map" do
  it "transmet les arguments imposés à la dépendance" do
    dep = recipe_from(<<-YAML)
      recipe: dep-web
      parameters:
        package: { type: string, default: lite }
      steps:
        - test-record: { pkg: "{{ package }}" }
      YAML
    user = recipe_from(<<-YAML)
      recipe: app-web
      requires:
        - dep-web: { package: full }
      YAML
    Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([dep, user])
    TestRecorder.last_params["pkg"].as_s.should eq("full")
  end

  it "laisse l'hôte surcharger un argument imposé" do
    dep = recipe_from(<<-YAML)
      recipe: dep-web
      parameters:
        package: { type: string, default: lite }
      steps:
        - test-record: { pkg: "{{ package }}" }
      YAML
    user = recipe_from(<<-YAML)
      recipe: app-web
      requires:
        - dep-web: { package: full }
      YAML
    args = {"dep-web" => [{"package" => "autre"}]}
    Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([dep, user], args)
    TestRecorder.last_params["pkg"].as_s.should eq("autre")
  end

  it "refuse deux valeurs imposées différentes" do
    dep = recipe_from("recipe: dep-web\nsteps: []\n")
    a = recipe_from("recipe: app-a\nrequires:\n  - dep-web: { package: full }\n")
    b = recipe_from("recipe: app-b\nrequires:\n  - dep-web: { package: lite }\n")
    expect_raises(Beryl::Apply::ConflictingRequiredArgs, /package/) do
      Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([dep, a, b])
    end
  end
end

describe "Beryl::Apply::Executor — garde « une recette par fichier »" do
  it "refuse deux recettes qui écrivent le même fichier, avant toute exécution" do
    a = recipe_from("recipe: site-a\nsteps:\n  - file-write: { path: /usr/local/etc/nginx/nginx.conf, content: a }\n")
    b = recipe_from("recipe: site-b\nsteps:\n  - file-write: { path: /usr/local/etc/nginx/nginx.conf, content: b }\n")
    shell = FakeShell.new
    expect_raises(Beryl::Apply::DuplicatePath, /site-a.*site-b/) do
      Beryl::Apply::Executor.new(shell, dry_run: true).run([a, b])
    end
    shell.commands.should be_empty
  end

  it "refuse deux jeux d'arguments qui visent le même fichier" do
    r = recipe_from(<<-YAML)
      recipe: site-x
      parameters:
        name: { type: string, default: "" }
      steps:
        - file-write: { path: /usr/local/etc/monit.d/site.conf, content: "{{ name }}" }
      YAML
    args = {"site-x" => [{"name" => "a"}, {"name" => "b"}]}
    expect_raises(Beryl::Apply::DuplicatePath, /jeu d'arguments/) do
      Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([r], args)
    end
  end

  it "accepte des chemins distincts par jeu d'arguments" do
    r = recipe_from(<<-YAML)
      recipe: site-y
      parameters:
        name: { type: string, default: "" }
      steps:
        - test-record: { path: "/usr/local/etc/nginx/conf.d/{{ name }}.conf" }
      YAML
    args = {"site-y" => [{"name" => "a"}, {"name" => "b"}]}
    report = Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([r], args)
    report.total.should eq(2)
  end
end

describe "Beryl::Apply::Executor — deferred" do
  it "joue une seule fois en fin d'apply une étape demandée par deux recettes" do
    a = recipe_from("recipe: sonde-a\nsteps:\n  - test-record: { what: a }\n  - test-noop: { name: monit, deferred: true }\n  - test-record: { what: a2 }\n")
    b = recipe_from("recipe: sonde-b\nsteps:\n  - test-noop: { name: monit, deferred: true }\n")
    report = Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([a, b])
    report.entries.map(&.step).should eq(["test-record", "test-record", "test-noop"])
  end

  it "respecte if_changed avant de reporter" do
    a = recipe_from("recipe: sonde-c\nsteps:\n  - test-noop: {}\n  - test-record: { deferred: true, if_changed: true }\n")
    report = Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([a])
    report.entries.map(&.result.outcome).should eq([Beryl::Apply::Outcome::Skipped, Beryl::Apply::Outcome::Skipped])
  end

  it "retire deferred des params transmis" do
    a = recipe_from("recipe: sonde-d\nsteps:\n  - test-record: { name: monit, deferred: true }\n")
    Beryl::Apply::Executor.new(FakeShell.new, dry_run: true).run([a])
    TestRecorder.last_params.has_key?("deferred").should be_false
  end
end
