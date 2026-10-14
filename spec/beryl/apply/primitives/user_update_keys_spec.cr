require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private def with_home(shell : FakeShell, authorized : String, home = "/home/deploy")
  shell.stub(/getent passwd/, stdout: home)
  shell.stub(/cat .*authorized_keys/, stdout: authorized)
end

describe Beryl::Apply::UserUpdateKeys do
  it "ajoute une clé manquante (set)" do
    shell = FakeShell.new
    with_home(shell, "")
    result = prim("user-update-keys").apply(
      shell,
      apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAfoo deploy@initech"]})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.any? { |w| w.path.ends_with?("authorized_keys") }.should be_true
  end

  it "skip si les clés sont déjà synchronisées (ignore le commentaire)" do
    shell = FakeShell.new
    with_home(shell, "ssh-ed25519 AAAAfoo ancien-commentaire\n")
    result = prim("user-update-keys").apply(
      shell,
      apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAfoo nouveau-commentaire"]})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "skip si l'utilisateur est absent" do
    shell = FakeShell.new
    with_home(shell, "", home: "")
    result = prim("user-update-keys").apply(
      shell,
      apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAfoo x"]})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "GARDE-FOU : refuse de retirer la clé de connexion de beryl" do
    shell = FakeShell.new
    with_home(shell, "ssh-ed25519 AAAAprotected admin\nssh-ed25519 AAAAold old\n")
    expect_raises(Beryl::Apply::UserUpdateKeys::ProtectedKeyRemoval, /beryl utilise/) do
      prim("user-update-keys").apply(
        shell,
        apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAnew new"]})),
        dry_run: false,
        context: ctx(["ssh-ed25519 AAAAprotected"]),
      )
    end
    shell.writes.should be_empty
  end
end
