require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::UserSshKey do
  it "génère une clé ed25519 user@fqdn si absente" do
    shell = FakeShell.new
    shell.stub(/getent passwd admin/, stdout: "admin:*:1001:1001::/home/admin:/bin/csh")
    shell.stub(/test -e/, exit_code: 1) # pas de clé
    result = prim("user-ssh-key").apply(
      shell, apply_params("{name: admin, fqdn: han.popi.net}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{ssh-keygen -t ed25519 -C admin@han.popi.net -f /home/admin/.ssh/id_ed25519}).should be_true
    shell.ran?(%r{chmod 600 /home/admin/.ssh/id_ed25519}).should be_true
  end

  it "skip si la clé existe déjà (jamais d'écrasement)" do
    shell = FakeShell.new
    shell.stub(/getent passwd admin/, stdout: "admin:*:1001:1001::/home/admin:/bin/csh")
    shell.stub(/test -e/, exit_code: 0) # clé présente
    result = prim("user-ssh-key").apply(
      shell, apply_params("{name: admin, fqdn: han.popi.net}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/ssh-keygen/).should be_false
  end

  it "skip si le user est absent" do
    shell = FakeShell.new
    shell.stub(/getent passwd ghost/, stdout: "")
    result = prim("user-ssh-key").apply(
      shell, apply_params("{name: ghost, fqdn: x.y}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/ssh-keygen/).should be_false
  end
end
