require "digest/sha256"
require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::SecretFile do
  it "injecte la paire [user, password] de l'ENV et écrit le fichier rendu" do
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

  it "skip si le contenu distant (valeurs incluses) est déjà à jour" do
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

  it "échoue (sans rien écrire) si une variable d'env est absente" do
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

  it "ne fait JAMAIS apparaître une valeur secrète dans le message" do
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

  it "échoue si un placeholder est absent du contenu" do
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

private def host_ctx(host : String) : Beryl::Apply::Context
  Beryl::Apply::Context.new(vars: {"hostname" => host})
end

private def tok_params(per_host : Bool) : Hash(String, YAML::Any)
  h = {"path" => "/usr/local/etc/app/agent.token", "env" => {"@@T@@" => "T_TOKEN"}, "content" => "@@T@@\n"} of String => String | Hash(String, String) | Bool
  h["per_host"] = true if per_host
  apply_params(h.to_yaml)
end

describe "Beryl::Apply::SecretFile — variables par serveur" do
  it "préfère la variante du serveur à la valeur commune" do
    ENV["T_TOKEN"] = "commun"
    ENV["T_TOKEN__LOULOU"] = "loulou"
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: "")
    prim("secret-file").apply(shell, tok_params(false), dry_run: false, context: host_ctx("loulou"))
    shell.writes.first.content.should eq("loulou\n")
  ensure
    ENV.delete("T_TOKEN")
    ENV.delete("T_TOKEN__LOULOU")
  end

  it "se replie sur la valeur commune sans variante" do
    ENV["T_TOKEN"] = "commun"
    shell = FakeShell.new
    shell.stub(/sha256 -q/, stdout: "")
    prim("secret-file").apply(shell, tok_params(false), dry_run: false, context: host_ctx("tika"))
    shell.writes.first.content.should eq("commun\n")
  ensure
    ENV.delete("T_TOKEN")
  end

  it "per_host : refuse la valeur commune et nomme la variable attendue" do
    ENV["T_TOKEN"] = "commun"
    r = prim("secret-file").apply(FakeShell.new, tok_params(true), dry_run: false, context: host_ctx("bibou"))
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    r.message.should contain("T_TOKEN__BIBOU")
  ensure
    ENV.delete("T_TOKEN")
  end

  it "if_absent (restauration d'une clé) : fichier présent → JAMAIS réécrit" do
    ENV["T_KEY"] = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 0) # la clé en service existe
    result = prim("secret-file").apply(
      shell,
      apply_params({path: "/usr/local/etc/ssl/keys/poudriere.key", mode: "0400", owner: "root:wheel",
                    if_absent: true, env: {"@@KEY@@" => "T_KEY"}, content: "@@KEY@@"}.to_yaml),
      dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  ensure
    ENV.delete("T_KEY")
  end

  it "if_absent : variable absente du coffre → ÉCHEC même si le fichier existe (sauvegarde manquante signalée)" do
    shell = FakeShell.new
    shell.stub(/test -e/, exit_code: 0)
    result = prim("secret-file").apply(
      shell,
      apply_params({path: "/usr/local/etc/ssl/keys/poudriere.key", if_absent: true,
                    env: {"@@KEY@@" => "T_KEY_ABSENTE"}, content: "@@KEY@@"}.to_yaml),
      dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("T_KEY_ABSENTE")
  end

  it "nom du serveur normalisé (majuscules, tirets → _)" do
    Beryl::Apply.host_secret_name("X", "pkg-01").should eq("X__PKG_01")
  end
end
