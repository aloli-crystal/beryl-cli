require "digest/sha256"
require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::FileWrite do
  it "skip si le contenu distant est identique" do
    content = "ligne 1\nligne 2\n"
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: Digest::SHA256.hexdigest(content))
    result = prim("file-write").apply(shell, apply_params({path: "/tmp/x", content: content}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "écrit + chmod si le fichier est absent" do
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: "")
    result = prim("file-write").apply(shell, apply_params({path: "/tmp/x", content: "abc\n", mode: "0644"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.size.should eq(1)
    shell.ran?(/chmod 0644/).should be_true
  end

  it "crée le répertoire parent avant d'écrire (mkdir -p)" do
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: "")
    prim("file-write").apply(
      shell,
      apply_params({path: "/usr/local/etc/ssl/certs/popi.cert", content: "x\n", mode: "0644"}.to_yaml),
      dry_run: false, context: ctx)
    shell.ran?(%r{mkdir -p /usr/local/etc/ssl/certs}).should be_true
  end

  it "corrige le propriétaire même si le contenu est à jour" do
    content = "abc\n"
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: Digest::SHA256.hexdigest(content))
    shell.stub(/stat -f %Su/, stdout: "root")
    result = prim("file-write").apply(shell, apply_params({path: "/tmp/x", content: content, owner: "deploy"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.should be_empty
    shell.ran?(/chown deploy/).should be_true
  end

  it "re-pose owner après une écriture, même si l'owner correspondait déjà" do
    content = "nouveau\n"
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: "ancien-hash-different") # contenu change → écriture
    shell.stub(/stat -f %Su/, stdout: "deploy")              # owner déjà deploy (correspond)
    result = prim("file-write").apply(shell, apply_params({path: "/home/deploy/.zshrc", content: content, owner: "deploy"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.size.should eq(1)
    # write_file recrée le fichier en root → chown DOIT être rejoué.
    shell.ran?(%r{chown deploy /home/deploy/.zshrc}).should be_true
  end

  it "file-template se comporte comme file-write" do
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: "")
    result = prim("file-template").apply(shell, apply_params({path: "/tmp/x", content: "z\n"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.size.should eq(1)
  end
end
