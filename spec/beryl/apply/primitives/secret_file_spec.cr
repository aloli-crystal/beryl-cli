require "digest/sha256"
require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::SecretFile do
  it "injecte la paire [user, password] de l'ENV et écrit le fichier rendu" do
    begin
      ENV["T_USER"] = "it@popi.net"
      ENV["T_PW"] = "s3cr3t"
      rendered = "it@popi.net|ssl0.ovh.net:s3cr3t\n"
      shell = FakeShell.new
      shell.stub(/sha256 -q/, stdout: "") # fichier absent
      result = prim("secret-file").apply(
        shell,
        apply_params({path:    "/usr/local/etc/dma/auth.conf",
                      env:     {"@@USER@@" => "T_USER", "@@SECRET@@" => "T_PW"},
                      content: "@@USER@@|ssl0.ovh.net:@@SECRET@@\n"}.to_yaml),
        dry_run: false, context: ctx)
      result.outcome.should eq(Beryl::Apply::Outcome::Applied)
      shell.writes.size.should eq(1)
      shell.writes.first.content.should eq(rendered)
      shell.ran?(/chmod 0600/).should be_true # mode sensible par défaut
    ensure
      ENV.delete("T_USER")
      ENV.delete("T_PW")
    end
  end

  it "skip si le contenu distant (valeurs incluses) est déjà à jour" do
    begin
      ENV["T_USER"] = "it@popi.net"
      ENV["T_PW"] = "s3cr3t"
      rendered = "it@popi.net|ssl0.ovh.net:s3cr3t\n"
      shell = FakeShell.new
      shell.stub(/sha256 -q/, stdout: Digest::SHA256.hexdigest(rendered))
      shell.stub(/stat -f %Lp/, stdout: "600") # mode déjà 0600
      result = prim("secret-file").apply(
        shell,
        apply_params({path: "/usr/local/etc/dma/auth.conf", mode: "0600",
                      env: {"@@USER@@" => "T_USER", "@@SECRET@@" => "T_PW"},
                      content: "@@USER@@|ssl0.ovh.net:@@SECRET@@\n"}.to_yaml),
        dry_run: false, context: ctx)
      result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      shell.writes.should be_empty
    ensure
      ENV.delete("T_USER")
      ENV.delete("T_PW")
    end
  end

  it "échoue (sans rien écrire) si une variable d'env est absente" do
    begin
      ENV["T_USER"] = "it@popi.net"
      ENV.delete("T_PW")
      shell = FakeShell.new
      result = prim("secret-file").apply(
        shell,
        apply_params({path:    "/tmp/x",
                      env:     {"@@USER@@" => "T_USER", "@@SECRET@@" => "T_PW"},
                      content: "@@USER@@:@@SECRET@@\n"}.to_yaml),
        dry_run: false, context: ctx)
      result.outcome.should eq(Beryl::Apply::Outcome::Failed)
      shell.writes.should be_empty
    ensure
      ENV.delete("T_USER")
    end
  end

  it "ne fait JAMAIS apparaître une valeur secrète dans le message" do
    begin
      ENV["T_USER"] = "it@popi.net"
      ENV["T_PW"] = "s3cr3t-unique-42"
      shell = FakeShell.new
      shell.stub(/sha256 -q/, stdout: "")
      result = prim("secret-file").apply(
        shell,
        apply_params({path:    "/tmp/x",
                      env:     {"@@USER@@" => "T_USER", "@@SECRET@@" => "T_PW"},
                      content: "@@USER@@:@@SECRET@@\n"}.to_yaml),
        dry_run: false, context: ctx)
      result.message.should_not contain("s3cr3t-unique-42")
    ensure
      ENV.delete("T_USER")
      ENV.delete("T_PW")
    end
  end

  it "échoue si un placeholder est absent du contenu" do
    begin
      ENV["T_USER"] = "it@popi.net"
      ENV["T_PW"] = "s3cr3t"
      shell = FakeShell.new
      result = prim("secret-file").apply(
        shell,
        apply_params({path:    "/tmp/x",
                      env:     {"@@USER@@" => "T_USER", "@@SECRET@@" => "T_PW"},
                      content: "@@USER@@ sans le second placeholder\n"}.to_yaml),
        dry_run: false, context: ctx)
      result.outcome.should eq(Beryl::Apply::Outcome::Failed)
      shell.writes.should be_empty
    ensure
      ENV.delete("T_USER")
      ENV.delete("T_PW")
    end
  end

  it "échoue si le sous-map `env` est absent" do
    shell = FakeShell.new
    result = prim("secret-file").apply(
      shell,
      apply_params({path: "/tmp/x", content: "rien\n"}.to_yaml),
      dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    shell.writes.should be_empty
  end
end
