require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private def pg_params(extra = "")
  apply_params("name: partiduo_admin\nowner: partiduo-admin\n#{extra}")
end

describe Beryl::Apply::PostgresqlDatabase do
  it "skip si le rôle et la base existent" do
    shell = FakeShell.new
    shell.stub(/pg_roles/, stdout: "1\n")
    shell.stub(/pg_database/, stdout: "partiduo-admin\n")
    r = prim("postgresql-database").apply(shell, pg_params, dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/createuser|createdb/).should be_false
  end

  it "crée le rôle puis la base" do
    shell = FakeShell.new
    shell.stub(/pg_roles/, stdout: "")
    shell.stub(/pg_database/, stdout: "")
    r = prim("postgresql-database").apply(shell, pg_params, dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/createuser partiduo-admin/).should be_true
    shell.ran?(/createdb --owner=partiduo-admin --encoding=UTF8 partiduo_admin/).should be_true
  end

  it "ne touche à rien en dry-run" do
    shell = FakeShell.new
    shell.stub(/pg_roles/, stdout: "")
    shell.stub(/pg_database/, stdout: "")
    r = prim("postgresql-database").apply(shell, pg_params, dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/createuser|createdb/).should be_false
  end

  it "dry-run sur un serveur pas encore démarré : annoncé, pas d'échec" do
    shell = FakeShell.new
    shell.stub(/psql/, exit_code: 2)
    r = prim("postgresql-database").apply(shell, pg_params, dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
  end

  it "refuse une base qui appartient à un autre rôle" do
    shell = FakeShell.new
    shell.stub(/pg_roles/, stdout: "1\n")
    shell.stub(/pg_database/, stdout: "postgres\n")
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /appartient/) do
      prim("postgresql-database").apply(shell, pg_params, dry_run: false, context: ctx)
    end
  end

  it "refuse un nom qui sortirait du SQL" do
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /invalide/) do
      prim("postgresql-database").apply(FakeShell.new, apply_params("name: \"x'; DROP\"\nowner: a\n"), dry_run: false, context: ctx)
    end
  end
end

describe Beryl::Apply::PostgresqlRole do
  it "crée le rôle avec CREATEDB" do
    shell = FakeShell.new
    shell.stub(/rolcreatedb/, stdout: "")
    r = prim("postgresql-role").apply(shell, apply_params("name: partiduo\ncreatedb: true\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/createuser --createdb --no-superuser partiduo/).should be_true
  end

  it "skip si le rôle a déjà CREATEDB" do
    shell = FakeShell.new
    shell.stub(/rolcreatedb/, stdout: "t\n")
    r = prim("postgresql-role").apply(shell, apply_params("name: partiduo\ncreatedb: true\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "ajoute CREATEDB à un rôle existant qui ne l'a pas" do
    shell = FakeShell.new
    shell.stub(/rolcreatedb/, stdout: "f\n")
    r = prim("postgresql-role").apply(shell, apply_params("name: partiduo\ncreatedb: true\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/ALTER ROLE/).should be_true
  end

  it "ne touche à rien en dry-run" do
    shell = FakeShell.new
    shell.stub(/rolcreatedb/, stdout: "")
    prim("postgresql-role").apply(shell, apply_params("name: partiduo\ncreatedb: true\n"), dry_run: true, context: ctx)
    shell.ran?(/createuser|ALTER/).should be_false
  end
end
