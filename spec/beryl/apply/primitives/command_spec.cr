require "file_utils"
require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::Command do
  it "saute l'étape quand if_set est vide" do
    shell = FakeShell.new
    r = prim("command").apply(shell, apply_params("run: x\nunless: y\nif_set: \"\"\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.commands.should be_empty
  end

  it "exige une garde" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /unless/) do
      prim("command").apply(FakeShell.new, apply_params("run: x\n"), dry_run: false, context: ctx)
    end
  end

  it "saute si la garde réussit" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 0)
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/do-it/).should be_false
  end

  it "lance sous l'utilisateur, avec l'environnement, et montre la sortie" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1)
    shell.stub(/do-it/, stdout: "Invitation : https://x/i/abc\n")
    yaml = "run: do-it\nunless: check-done\nuser: app\nenv_file: /usr/local/etc/app/app.env\nshow_output: true\n"
    r = prim("command").apply(shell, apply_params(yaml), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("https://x/i/abc")
    cmd = shell.commands.find! { |c| FakeShell.readable(c).includes?("do-it") }
    cmd.should start_with("su -m app -c ")
    FakeShell.readable(cmd).should contain("/usr/local/etc/app/app.env")
  end

  it "ne lance rien en dry-run (garde seulement)" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1)
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.commands.size.should eq(1)
  end

  it "rapporte l'échec avec la sortie" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1)
    shell.stub(/do-it/, exit_code: 1, stderr: "amorçage refusé.")
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    r.message.should contain("amorçage refusé")
  end
end

# Shell LOCAL qui fait lire chaque ligne par `csh -f -c`, comme le shell de
# connexion d'`admin` sur les serveurs (qwerty, 14 oct. 2026). Un faux `sudo`
# (`exec "$@"`) en tête du PATH laisse passer toute la chaîne
# Command → SudoShell → ligne envoyée.
private class CshShell < Beryl::Apply::Shell
  getter lines = [] of String

  def initialize(@bin : String)
  end

  def exec(command : String, raise_on_error : Bool = true) : SSH::Result
    @lines << command
    sout = IO::Memory.new
    err = IO::Memory.new
    env = {"PATH" => "#{@bin}:#{ENV["PATH"]}"}
    st = Process.run("csh", ["-f", "-c", command], env: env, output: sout, error: err)
    SSH::Result.new(sout.to_s, err.to_s, st.exit_code)
  end

  def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
    raise "inutile ici"
  end
end

private def with_csh(&)
  dir = File.tempname("beryl-csh")
  Dir.mkdir_p(File.join(dir, "bin"))
  sudo = File.join(dir, "bin", "sudo")
  File.write(sudo, "#!/bin/sh\nexec \"$@\"\n")
  File.chmod(sudo, 0o755)
  yield CshShell.new(File.join(dir, "bin")), dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "Beryl::Apply::Command sous un shell de connexion csh" do
  it "joue garde et commande multi-lignes (case … '*'*) ;; esac, $(…))" do
    with_csh do |csh, dir|
      marker = File.join(dir, "marker")
      yaml = <<-YAML
        unless: |
          v=$(printf '%s' "a'b")
          case "$v" in
            *"'"*) test -f #{marker} ;;
            *) exit 3 ;;
          esac
        run: |
          w=$(echo ok)
          case "$w" in
            '*'*) echo "étoile" > #{marker} ;;
            *) echo "fait : $w" > #{marker} ;;
          esac
        YAML
      shell = Beryl::Apply::SudoShell.new(csh)
      r = prim("command").apply(shell, apply_params(yaml), dry_run: false, context: ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      File.read(marker).should eq("fait : ok\n")
      csh.lines.each(&.includes?('\n').should(be_false))
      # Rejeu : la garde est satisfaite → skip.
      prim("command").apply(shell, apply_params(yaml), dry_run: false, context: ctx)
        .outcome.should eq(Beryl::Apply::Outcome::Skipped)
    end
  end

  it "l'ancienne ligne (`sudo sh -c '<multi-ligne>'`) casse bien sous csh" do
    with_csh do |csh, _dir|
      res = csh.exec("sudo sh -c #{Process.quote("case x in\n  *) echo $(echo y) ;;\nesac")}")
      res.success?.should be_false
      res.stderr.should match(Beryl::Apply::Command::SHELL_ERROR_RE)
      Beryl::Apply::Command.broken_guard?(res.exit_code, res.stderr).should be_true
    end
  end

  it "met en FAILED (et non « would apply » muet) une garde introuvable" do
    with_csh do |csh, _dir|
      shell = Beryl::Apply::SudoShell.new(csh)
      yaml = "run: \"echo jamais\"\nunless: \"commande-introuvable-beryl --check\"\n"
      r = prim("command").apply(shell, apply_params(yaml), dry_run: true, context: ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Failed)
      r.message.should contain("garde `unless` cassée (code 127)")
      csh.lines.size.should eq(1)
    end
  end
end

describe "Beryl::Apply::Command, garde qui échoue" do
  it "garde cassée (csh) → FAILED en dry-run, rien lancé" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1, stderr: "Unmatched '.\n")
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    r.message.should contain("Unmatched")
    shell.ran?(/do-it/).should be_false
  end

  it "garde cassée → FAILED en --apply aussi, sans lancer `run`" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 2, stderr: "sh: Syntax error: \";;\" unexpected\n")
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    shell.ran?(/do-it/).should be_false
  end

  it "garde qui répond non sur stderr (psql, base absente) → would apply, stderr visible" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 1, stderr: "psql: error: FATAL:  database \"app\" does not exist\n")
    r = prim("command").apply(shell, apply_params("run: do-it\nunless: check-done\n"), dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("garde : psql: error: FATAL:  database \"app\" does not exist")
  end

  it "le rapport de l'apply (dry-run) compte la garde cassée en failed" do
    shell = FakeShell.new
    shell.stub(/check-done/, exit_code: 127, stderr: "sh: check-done: not found\n")
    recipe = Beryl::Apply::Recipe.new(
      name: "amorce", description: "", requires: [] of String,
      parameters: {} of String => YAML::Any, arguments: {} of String => YAML::Any,
      steps: [Beryl::Apply::Step.new("command", apply_params("run: do-it\nunless: check-done\n"))],
      source_path: "amorce.recipe.yml",
    )
    report = Beryl::Apply::Executor.new(shell, dry_run: true).run([recipe])
    report.failed.should eq(1)
    report.applied.should eq(0)
  end
end
