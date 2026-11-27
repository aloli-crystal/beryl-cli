require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private def with_home(shell : FakeShell, authorized : String, home = "/home/deploy", mirror : String? = nil)
  shell.stub(/getent passwd/, stdout: home)
  shell.stub(/cat .*authorized_keys/, stdout: authorized)
  # Pas de copie en clair (/home non chiffré) sauf `mirror` donné.
  if mirror
    shell.stub(%r{^cat /etc/ssh/authorized_keys/}, stdout: mirror)
  else
    shell.stub(%r{^test -d /etc/ssh/authorized_keys$}, exit_code: 1)
  end
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

  it "/home chiffré : copie en clair resynchronisée même si ~/.ssh est à jour" do
    shell = FakeShell.new
    with_home(shell, "ssh-ed25519 AAAAfoo x\n", mirror: "ssh-ed25519 AAAAold x\n")
    result = prim("user-update-keys").apply(
      shell,
      apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAfoo x"]})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    w = shell.writes.find! { |x| x.path == "/etc/ssh/authorized_keys/deploy" }
    w.content.should eq("ssh-ed25519 AAAAfoo x\n")
    shell.ran?(%r{chown root:wheel /etc/ssh/authorized_keys/deploy}).should be_true
  end

  it "/home chiffré : copie en clair identique → rien à faire" do
    shell = FakeShell.new
    with_home(shell, "ssh-ed25519 AAAAfoo x\n", mirror: "ssh-ed25519 AAAAfoo x\n")
    result = prim("user-update-keys").apply(
      shell,
      apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAfoo x"]})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end
end

describe "user-update-keys : clés retirées nommées" do
  it "nomme la clé retirée (commentaire) dans le message, dès l'essai à blanc" do
    shell = FakeShell.new
    with_home(shell, "ssh-ed25519 AAAAkeep ops@initech\nssh-ed25519 AAAAgone stagiaire@laptop\n")
    result = prim("user-update-keys").apply(
      shell,
      apply_params(%({user: deploy, keys: ["ssh-ed25519 AAAAkeep ops@initech"]})),
      dry_run: true, context: ctx,
    )
    result.message.should contain("-1 clé(s) (retirées : stagiaire@laptop)")
    shell.writes.should be_empty
  end
end
