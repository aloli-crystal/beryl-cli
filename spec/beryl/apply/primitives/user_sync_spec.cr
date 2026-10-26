require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::UserSync do
  it "ajoute le user aux groupes manquants (additif)" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy") # pas encore dans wheel
    result = prim("user-sync").apply(
      shell, apply_params("{name: deploy, secondary_groups: [wheel]}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pw groupmod wheel -m deploy/).should be_true
  end

  it "skip si déjà membre des groupes voulus" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy wheel") # déjà dans wheel, rien d'autre
    result = prim("user-sync").apply(
      shell, apply_params("{name: deploy, secondary_groups: [wheel]}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw groupmod/).should be_false
  end

  it "groupes déclarés EXACTS : retire des groupes secondaires non listés (compte existant)" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:80::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "www wheel operator") # principal www
    result = prim("user-sync").apply(
      shell, apply_params("{name: deploy, primary_group: www, secondary_groups: []}"), dry_run: false, context: ctx)
    result.message.should contain "-wheel"
    shell.ran?(/pw groupmod wheel -d deploy/).should be_true
    shell.ran?(/pw groupmod operator -d deploy/).should be_true
    shell.ran?(/groupmod www -d/).should be_false # jamais le groupe principal
  end

  it "groupes NON déclarés : laissés tels quels" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:80::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "www wheel")
    prim("user-sync").apply(shell, apply_params("{name: deploy}"), dry_run: false, context: ctx)
    shell.ran?(/pw groupmod/).should be_false
  end

  it "ne retire jamais wheel du compte par lequel beryl se connecte" do
    shell = FakeShell.new
    shell.stub(/getent passwd admin/, stdout: "admin:*:1001:80::/home/admin:/bin/sh")
    shell.stub(/id -Gn admin/, stdout: "www wheel")
    context = Beryl::Apply::Context.new(vars: {"connect_user" => "admin"})
    result = prim("user-sync").apply(
      shell, apply_params("{name: admin, secondary_groups: []}"), dry_run: false, context: context)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    result.message.should contain "wheel conservé"
    shell.ran?(/groupmod wheel -d/).should be_false
  end

  it "groupe principal déclaré : posé aussi sur un compte existant" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy wheel")
    prim("user-sync").apply(
      shell, apply_params("{name: deploy, primary_group: www, secondary_groups: [wheel]}"), dry_run: false, context: ctx)
    shell.ran?(/pw usermod deploy -g www/).should be_true
    shell.ran?(/groupmod deploy -d/).should be_false # l'ancien principal n'est pas un groupe secondaire à retirer
  end

  it "accepte l'alias `groups` (= secondary_groups)" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy")
    prim("user-sync").apply(
      shell, apply_params("{name: deploy, groups: [wheel]}"), dry_run: false, context: ctx)
    shell.ran?(/pw groupmod wheel -m deploy/).should be_true
  end

  it "ne change PAS le shell d'un user existant (laissé aux recettes, anti-flap)" do
    shell = FakeShell.new
    shell.stub(/getent passwd deploy/, stdout: "deploy:*:1001:1001::/home/deploy:/bin/csh")
    shell.stub(/id -Gn deploy/, stdout: "deploy wheel") # groupes déjà ok
    result = prim("user-sync").apply(
      shell, apply_params("{name: deploy, secondary_groups: [wheel], shell: /usr/local/bin/zsh}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw usermod.*-s/).should be_false
  end

  it "crée le compte absent avec ses groupes et shell" do
    shell = FakeShell.new
    shell.stub(/getent passwd nouveau/, stdout: "") # absent
    result = prim("user-sync").apply(
      shell, apply_params("{name: nouveau, secondary_groups: [wheel], shell: /bin/sh}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{pw useradd -n nouveau -m -G wheel -s /bin/sh}).should be_true
  end

  it "supprime le compte avec state: absent (home conservé)" do
    shell = FakeShell.new
    shell.stub(/getent passwd vieux/, stdout: "vieux:*:1005:1005::/home/vieux:/bin/sh")
    result = prim("user-sync").apply(
      shell, apply_params("{name: vieux, state: absent}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pw userdel vieux/).should be_true
    shell.ran?(/-r/).should be_false # pas de suppression du home
  end

  it "skip absent si le compte n'existe déjà plus" do
    shell = FakeShell.new
    shell.stub(/getent passwd vieux/, stdout: "")
    result = prim("user-sync").apply(
      shell, apply_params("{name: vieux, state: absent}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pw userdel/).should be_false
  end
end
