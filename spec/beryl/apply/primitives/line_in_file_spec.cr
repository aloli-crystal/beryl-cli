require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

ALIASES = "# root:\tme@my.domain\n\nMAILER-DAEMON: postmaster\npostmaster: root\n"

describe Beryl::Apply::LineInFile do
  describe ".ensure_line" do
    it "ajoute la ligne à la fin quand rien ne correspond (commentaire ignoré)" do
      result = Beryl::Apply::LineInFile.ensure_line(ALIASES, "root: a@example.net", "^root:")
      result.should eq(ALIASES + "root: a@example.net\n")
    end

    it "remplace la ligne qui correspond et garde le reste dans l'ordre" do
      src = "a: 1\nroot: old@x\nb: 2\n"
      Beryl::Apply::LineInFile.ensure_line(src, "root: new@x", "^root:").should eq("a: 1\nroot: new@x\nb: 2\n")
    end

    it "retire les doublons qui correspondent" do
      src = "root: x\na\nroot: y\n"
      Beryl::Apply::LineInFile.ensure_line(src, "root: z", "^root:").should eq("root: z\na\n")
    end

    it "ne change rien si la ligne est déjà là (avec ou sans match)" do
      src = "a\nroot: z\n"
      Beryl::Apply::LineInFile.ensure_line(src, "root: z", "^root:").should eq(src)
      Beryl::Apply::LineInFile.ensure_line(src, "a", nil).should eq(src)
    end

    it "sans match : ajoute si absente" do
      Beryl::Apply::LineInFile.ensure_line("a\n", "b", nil).should eq("a\nb\n")
    end
  end

  it "échoue si le fichier n'existe pas" do
    shell = FakeShell.new
    shell.stub(/cat /, exit_code: 1)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /introuvable/) do
      prim("line-in-file").apply(shell, apply_params({path: "/etc/x", line: "a"}.to_yaml), dry_run: false, context: ctx)
    end
  end

  it "skip si la ligne est déjà présente" do
    shell = FakeShell.new
    shell.stub(/cat /, stdout: "root: z\n")
    r = prim("line-in-file").apply(shell, apply_params({path: "/etc/x", line: "root: z", match: "^root:"}.to_yaml), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "écrit puis restaure mode et propriétaire" do
    shell = FakeShell.new
    shell.stub(/cat /, stdout: ALIASES)
    shell.stub(/stat -f/, stdout: "644 root:wheel\n")
    r = prim("line-in-file").apply(shell, apply_params({path: "/etc/mail/aliases", line: "root: a@x", match: "^root:"}.to_yaml), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.size.should eq(1)
    shell.ran?(/chmod 644/).should be_true
    shell.ran?(/chown root:wheel/).should be_true
  end
end

describe "Beryl::Apply::LineInFile en dry-run après un file-write simulé" do
  it "lit le contenu qu'un file-write précédent aurait écrit, sans échouer" do
    shell = FakeShell.new
    shell.stub(/cat /, exit_code: 1)
    context = ctx
    w = prim("file-write").apply(shell, apply_params({path: "/home/deploy/.zshenv", content: "export A=1\n"}.to_yaml), dry_run: true, context: context)
    w.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r = prim("line-in-file").apply(shell, apply_params({path: "/home/deploy/.zshenv", line: "export B=2"}.to_yaml), dry_run: true, context: context)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("fichier écrit par une étape précédente")
    context.dry_files["/home/deploy/.zshenv"].should eq("export A=1\nexport B=2\n")
    shell.ran?(/cat /).should be_false
    shell.writes.should be_empty
  end

  it "skip si le contenu simulé a déjà la ligne" do
    shell = FakeShell.new
    context = ctx
    prim("file-write").apply(shell, apply_params({path: "/etc/x", content: "a\n"}.to_yaml), dry_run: true, context: context)
    r = prim("line-in-file").apply(shell, apply_params({path: "/etc/x", line: "a"}.to_yaml), dry_run: true, context: context)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "hors dry-run, ignore tout contenu simulé et lit le serveur" do
    shell = FakeShell.new
    shell.stub(/cat /, exit_code: 1)
    context = ctx
    context.dry_files["/etc/x"] = "a\n"
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /introuvable/) do
      prim("line-in-file").apply(shell, apply_params({path: "/etc/x", line: "b"}.to_yaml), dry_run: false, context: context)
    end
  end
end
