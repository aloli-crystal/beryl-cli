require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::PkgVersioned do
  it "résout `latest` par la vraie version et installe server + client" do
    shell = FakeShell.new
    shell.stub(/pkg rquery/, stdout: "11.4.2 mariadb114-server\n")
    shell.stub(/pkg info -e/, exit_code: 1) # rien d'installé
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: mariadb, version: latest}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg install -y mariadb114-server mariadb114-client/).should be_true
  end

  it "respecte `only: server` (pas de client)" do
    shell = FakeShell.new
    shell.stub(/pkg info -e/, exit_code: 1)
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: 17, only: server}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg install -y postgresql17-server$/).should be_true
  end

  it "skip si tout est déjà installé" do
    shell = FakeShell.new
    shell.stub(/pkg info -e/, exit_code: 0) # tout présent
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: mariadb, version: 114}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pkg install/).should be_false
  end

  it "échoue proprement si aucun paquet -server dans le dépôt (latest)" do
    shell = FakeShell.new
    shell.stub(/pkg rquery/, stdout: "") # rien trouvé
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: mariadb, version: latest}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end

  it "rafraîchit le catalogue AVANT de chercher la dernière version (dépôt tout juste ajouté)" do
    shell = FakeShell.new
    shell.stub(/pkg rquery/, stdout: "17.6 postgresql17-server\n")
    shell.stub(/pkg info -e/, exit_code: 1)
    prim("pkg-versioned").apply(shell, apply_params({base: "postgresql", only: "server"}.to_yaml), dry_run: true, context: ctx)
    upd = shell.commands.index! { |c| c.includes?("pkg update -q") }
    rq = shell.commands.index! { |c| c.includes?("pkg rquery") }
    upd.should be < rq
  end

  it "`latest` garde la version majeure déjà installée (jamais de montée de majeure par apply)" do
    shell = FakeShell.new
    shell.stub(/pkg query/, stdout: "nginx-1.28.0\npostgresql18-client\npostgresql18-server\n")
    shell.stub(/pkg rquery/, stdout: "19.0 postgresql19-server\n")
    shell.stub(/pkg info -e 'postgresql18-server'|pkg info -e postgresql18-server/, exit_code: 0)
    shell.stub(/pkg info -e 'postgresql18-client'|pkg info -e postgresql18-client/, exit_code: 0)
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: latest}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pkg install/).should be_false
    shell.ran?(/pkg rquery/).should be_false
  end

  it "`latest` complète la majeure en place (client manquant) sans en changer" do
    shell = FakeShell.new
    shell.stub(/pkg query/, stdout: "postgresql18-server\n")
    shell.stub(/pkg info -e/, exit_code: 1)
    prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: latest}"), dry_run: false, context: ctx)
    shell.ran?(/pkg install -y postgresql18-server postgresql18-client/).should be_true
  end

  it "`server_package` : serveur maison, client officiel" do
    shell = FakeShell.new
    shell.stub(/pkg info -e/, exit_code: 1)
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: 18, server_package: postgresql18-server-aloli}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg install -y postgresql18-server-aloli postgresql18-client$/).should be_true
  end

  it "`server_package` : skip si le serveur maison et le client sont en place" do
    shell = FakeShell.new
    shell.stub(/pkg info -e/, exit_code: 0)
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: 18, server_package: postgresql18-server-aloli}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "`server_package` exige une version explicite" do
    shell = FakeShell.new
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, server_package: postgresql18-server-aloli}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    shell.ran?(/pkg install/).should be_false
  end

  it "`server_package` d'une autre majeure : refusé" do
    shell = FakeShell.new
    result = prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: 17, server_package: postgresql18-server-aloli}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    shell.ran?(/pkg install/).should be_false
  end

  it "`latest` reconnaît un serveur maison déjà installé comme majeure en place" do
    shell = FakeShell.new
    shell.stub(/pkg query/, stdout: "postgresql18-client\npostgresql18-server-aloli\n")
    shell.stub(/pkg info -e 'postgresql18-client'|pkg info -e postgresql18-client/, exit_code: 0)
    shell.stub(/pkg info -e/, exit_code: 1)
    prim("pkg-versioned").apply(
      shell, apply_params("{base: postgresql, version: latest, only: client}"), dry_run: false, context: ctx)
    shell.ran?(/pkg rquery/).should be_false
  end
end
