require "../../spec_helper"
require "../../support/fake_shell"
require "../../support/apply_helpers"

describe "Beryl::Apply::Primitive.probe?" do
  it "oui (0) / non (1) comme avant" do
    shell = FakeShell.new
    shell.stub(/test -e \/oui/, exit_code: 0)
    shell.stub(/test -e \/non/, exit_code: 1)
    Beryl::Apply::Primitive.probe?(shell, "test -e /oui").should be_true
    Beryl::Apply::Primitive.probe?(shell, "test -e /non").should be_false
  end

  it "une réponse « non » sur stderr reste un non" do
    shell = FakeShell.new
    shell.stub(/zfs list/, exit_code: 1, stderr: "cannot open 'zroot/x': dataset does not exist\n")
    Beryl::Apply::Primitive.probe?(shell, "zfs list -H -o name zroot/x").should be_false
  end

  it "lève ProbeFailed si la commande est introuvable (127) ou le shell en erreur" do
    shell = FakeShell.new
    shell.stub(/pkg info/, exit_code: 127, stderr: "sh: pkg: not found\n")
    shell.stub(/grep -qx/, exit_code: 1, stderr: "Unmatched '.\n")
    expect_raises(Beryl::Apply::Primitive::ProbeFailed, /code 127.*pkg: not found/) do
      Beryl::Apply::Primitive.probe?(shell, "pkg info -e zsh")
    end
    expect_raises(Beryl::Apply::Primitive::ProbeFailed, /Unmatched/) do
      Beryl::Apply::Primitive.probe?(shell, "grep -qx a /etc/sysctl.conf")
    end
  end

  it "read_probe : sortie rendue telle quelle, sauf sonde cassée" do
    shell = FakeShell.new
    shell.stub(/sysrc -n a/, stdout: "YES\n")
    shell.stub(/sysrc -n b/, exit_code: 126, stderr: "sh: /usr/sbin/sysrc: Permission denied\n")
    Beryl::Apply::Primitive.read_probe(shell, "sysrc -n a").stdout.should eq("YES\n")
    expect_raises(Beryl::Apply::Primitive::ProbeFailed, /code 126/) do
      Beryl::Apply::Primitive.read_probe(shell, "sysrc -n b")
    end
  end

  it "une sonde cassée met l'étape en FAILED en dry-run, plus de « would apply » muet" do
    shell = FakeShell.new
    shell.stub(/test -d/, exit_code: 127, stderr: "sh: test: not found\n")
    recipe = Beryl::Apply::Recipe.new(
      name: "dossiers", description: "", requires: [] of String,
      parameters: {} of String => YAML::Any, arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new("directory", apply_params("path: /var/db/app\n"))],
      source_path: "dossiers.recipe.yml",
    )
    report = Beryl::Apply::Executor.new(shell, dry_run: true).run([recipe])
    report.failed.should eq(1)
    report.applied.should eq(0)
    report.entries.first.result.message.should contain("sonde `test -d")
  end
end
