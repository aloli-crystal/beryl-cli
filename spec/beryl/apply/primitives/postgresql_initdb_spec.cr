require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

# Shell où le cluster n'existe qu'APRÈS `service postgresql oneinitdb`
# (si `creates` est vrai) : simule un initdb qui fonctionne… ou pas.
private class InitdbShell < FakeShell
  def initialize(@creates : Bool)
    @initdb_ran = false
  end

  def exec(command : String, raise_on_error : Bool = true) : SSH::Result
    if command.includes?("service postgresql oneinitdb")
      @commands << command
      @initdb_ran = true
      return SSH::Result.new("", "", 0)
    end
    if command.includes?("ls /var/db/postgres")
      @commands << command
      return SSH::Result.new("", "", @initdb_ran && @creates ? 0 : 1)
    end
    super
  end
end

describe Beryl::Apply::PostgresqlInitdb do
  it "lance initdb si le cluster n'est pas initialisé" do
    shell = InitdbShell.new(creates: true)
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/service postgresql oneinitdb/).should be_true
  end

  it "utilise oneinitdb (service pas encore activé : initdb serait ignoré par rc.subr)" do
    shell = InitdbShell.new(creates: true)
    prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    shell.ran?(/service postgresql oneinitdb/).should be_true
    shell.ran?(/service postgresql initdb/).should be_false
  end

  it "échoue si initdb rend 0 sans avoir créé le cluster" do
    shell = InitdbShell.new(creates: false)
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("n'a pas créé le cluster")
  end

  it "skip si le cluster est déjà initialisé (idempotent)" do
    shell = FakeShell.new
    shell.stub(%r{ls /var/db/postgres}, exit_code: 0)
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/initdb/).should be_false
  end

  it "skip si le serveur PostgreSQL n'est pas installé (only: client)" do
    shell = FakeShell.new
    shell.stub(%r{test -f /usr/local/etc/rc.d/postgresql}, exit_code: 1)
    result = prim("postgresql-initdb").apply(shell, apply_params("{}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/initdb/).should be_false
  end
end
