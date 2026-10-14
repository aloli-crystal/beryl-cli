require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::ServiceEnable do
  it "active et démarre un service ni activé ni lancé" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    shell.stub(/service nginx onestatus/, exit_code: 1)
    result = prim("service-enable").apply(shell, apply_params("name: nginx"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc nginx_enable=YES/).should be_true
    shell.ran?(/service nginx start/).should be_true
  end

  it "skip si déjà activé et démarré" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "YES")
    shell.stub(/service nginx onestatus/, exit_code: 0)
    result = prim("service-enable").apply(shell, apply_params("name: nginx"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/sysrc nginx_enable=YES/).should be_false
  end

  it "active sans démarrer si start: false" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    shell.stub(/service nginx onestatus/, exit_code: 1)
    result = prim("service-enable").apply(shell, apply_params("{name: nginx, start: false}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc nginx_enable=YES/).should be_true
    shell.ran?(/service nginx start/).should be_false
  end

  it "if_present: skip (sans rien lancer) si le service n'a pas de script rc" do
    shell = FakeShell.new
    shell.stub(%r{test -f /usr/local/etc/rc.d}, exit_code: 1) # pas de script rc (only: client)
    result = prim("service-enable").apply(
      shell, apply_params("{name: mysql-server, if_present: true}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/service .* start/).should be_false
    shell.ran?(/sysrc/).should be_false
  end

  it "pose la variable enable_var quand elle diffère du nom du service" do
    shell = FakeShell.new
    shell.stub(/sysrc -n mysql_enable/, stdout: "NO")
    shell.stub(/onestatus/, exit_code: 1)
    prim("service-enable").apply(
      shell, apply_params("{name: mysql-server, enable_var: mysql_enable, start: false}"), dry_run: false, context: ctx)
    shell.ran?(/sysrc mysql_enable=YES/).should be_true
    shell.ran?(/sysrc mysql-server_enable/).should be_false
  end
end

describe Beryl::Apply::ServiceDisable do
  it "désactive et arrête un service actif" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "YES")
    shell.stub(/service sendmail onestatus/, exit_code: 0)
    result = prim("service-disable").apply(shell, apply_params("name: sendmail"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/sysrc sendmail_enable=NO/).should be_true
    shell.ran?(/service sendmail stop/).should be_true
  end

  it "skip si déjà désactivé et arrêté" do
    shell = FakeShell.new
    shell.stub(/sysrc -n/, stdout: "NO")
    shell.stub(/service sendmail onestatus/, exit_code: 1)
    result = prim("service-disable").apply(shell, apply_params("name: sendmail"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end
end

describe Beryl::Apply::ServiceReload do
  it "recharge un service démarré" do
    shell = FakeShell.new
    shell.stub(/service sshd onestatus/, exit_code: 0)
    result = prim("service-reload").apply(shell, apply_params("name: sshd"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/service sshd reload/).should be_true
  end

  it "skip (ne recharge pas) si le service n'est pas démarré" do
    shell = FakeShell.new
    shell.stub(/service sshd onestatus/, exit_code: 1)
    result = prim("service-reload").apply(shell, apply_params("name: sshd"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/service sshd reload/).should be_false
  end

  it "ne recharge pas en dry-run" do
    shell = FakeShell.new
    shell.stub(/service sshd onestatus/, exit_code: 0)
    result = prim("service-reload").apply(shell, apply_params("name: sshd"), dry_run: true, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/service sshd reload/).should be_false
  end
end

describe Beryl::Apply::ServiceRestart do
  it "skip si le service ne tourne pas" do
    shell = FakeShell.new
    shell.stub(/onestatus/, exit_code: 1)
    r = prim("service-restart").apply(shell, apply_params("name: app\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/restart/).should be_false
  end

  it "redémarre un service qui tourne, détaché de la session" do
    shell = FakeShell.new
    shell.stub(/onestatus/, exit_code: 0)
    r = prim("service-restart").apply(shell, apply_params("name: app\n"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{service app restart </dev/null}).should be_true
  end
end
