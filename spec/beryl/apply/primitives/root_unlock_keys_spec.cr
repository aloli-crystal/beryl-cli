require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private KEY = "ssh-ed25519 AAAAfoo ops@initech"

private def root_shell(keys : String, gate : String) : FakeShell
  shell = FakeShell.new
  shell.stub(%r{^cat /root/.ssh/authorized_keys}, stdout: keys)
  shell.stub(%r{^cat /usr/local/sbin/beryl-unlock}, stdout: gate)
  shell
end

describe Beryl::Apply::RootUnlockKeys do
  it "écrit les clés restreintes et le script de la porte, root:wheel" do
    shell = root_shell("", "")
    r = prim("root-unlock-keys").apply(shell, apply_params(%({keys: ["#{KEY}"]})), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    keys = shell.writes.find! { |w| w.path == "/root/.ssh/authorized_keys" }
    keys.content.should eq %(restrict,command="/usr/local/sbin/beryl-unlock" #{KEY}\n)
    keys.mode.should eq "0600"
    gate = shell.writes.find! { |w| w.path == Beryl::UnlockGate::PATH }
    gate.content.should eq Beryl::UnlockGate::SCRIPT + "\n"
    gate.mode.should eq "0555"
    shell.ran?(%r{chown root:wheel /root/.ssh/authorized_keys}).should be_true
  end

  it "rien à faire si tout est à jour (fichier du bootstrap compris)" do
    shell = root_shell(Beryl::Apply::RootUnlockKeys.content([KEY]), Beryl::UnlockGate::SCRIPT + "\n")
    r = prim("root-unlock-keys").apply(shell, apply_params(%({keys: ["#{KEY}"]})), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "réécrit un fichier sans fin de ligne finale (bootstrap < 0.6.180), rien en dry-run" do
    old = %(restrict,command="/usr/local/sbin/beryl-unlock" #{KEY})
    shell = root_shell(old, Beryl::UnlockGate::SCRIPT + "\n")
    r = prim("root-unlock-keys").apply(shell, apply_params(%({keys: ["#{KEY}"]})), dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("dry-run")
    shell.writes.should be_empty
  end

  it "refuse une liste vide (root sans accès au déverrouillage)" do
    shell = root_shell("", "")
    r = prim("root-unlock-keys").apply(shell, apply_params(%({keys: []})), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    shell.writes.should be_empty
  end
end
