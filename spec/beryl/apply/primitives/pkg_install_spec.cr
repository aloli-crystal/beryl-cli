require "../../../spec_helper"
require "../../../support/fake_shell"

private def params(yaml : String) : Hash(String, YAML::Any)
  h = {} of String => YAML::Any
  YAML.parse(yaml).as_h.each { |k, v| h[k.as_s] = v }
  h
end

private def pkg_install : Beryl::Apply::Primitive
  Beryl::Apply::Primitive["pkg-install"]?.not_nil!
end

describe Beryl::Apply::PkgInstall do
  it "skip si tous les packages sont déjà installés" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "bash\ncurl\ngit\n")
    result = pkg_install.apply(shell, params("packages: [bash, git]"), dry_run: false, context: Beryl::Apply::Context.new)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/pkg install/).should be_false
  end

  it "installe uniquement le delta manquant" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "bash\n")
    result = pkg_install.apply(shell, params("packages: [bash, git, curl]"), dry_run: false, context: Beryl::Apply::Context.new)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    result.message.should contain("git")
    result.message.should contain("curl")
    result.message.should_not contain("bash")
    shell.ran?(/pkg install -y/).should be_true
  end

  it "n'installe rien en dry-run mais annonce le delta" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "")
    result = pkg_install.apply(shell, params("packages: [git]"), dry_run: true, context: Beryl::Apply::Context.new)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    result.message.should contain("dry-run")
    shell.ran?(/pkg install/).should be_false
  end

  it "skip proprement si aucun package déclaré" do
    shell = FakeShell.new
    result = pkg_install.apply(shell, params("packages: []"), dry_run: false, context: Beryl::Apply::Context.new)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end

  it "accepte un paquet seul en string (recette générique pkg-add)" do
    shell = FakeShell.new
    shell.stub(/pkg info/, stdout: "")
    result = pkg_install.apply(shell, params("packages: htop"), dry_run: false, context: Beryl::Apply::Context.new)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/pkg install -y htop/).should be_true
  end

  it "FreeBSD : un pkg install -r par dépôt, celui que pkg choisit dans son plan" do
    shell = FakeShell.new
    shell.stub(/pkg info -q/, stdout: "")
    shell.stub(/pkg install -n/, stdout: <<-OUT)
    New packages to be INSTALLED:
    \tgmp: 6.3.0 [aloli]
    \tmpfr: 4.2.2,1 [aloli]
    \tnginx-lite-aloli: 1.28.0 [aloli]
    \tsmartmontools: 7.5_2 [FreeBSD-ports]
    OUT
    r = Beryl::Apply::Primitive["pkg-install"]?.not_nil!.apply(shell,
      {"packages" => YAML.parse("[smartmontools, nginx-lite-aloli, outil]")}, dry_run: false,
      context: Beryl::Apply::Context.new)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/^pkg install -r FreeBSD-ports -y smartmontools$/).should be_true
    shell.ran?(/^pkg install -r aloli -y nginx-lite-aloli$/).should be_true
    shell.ran?(/^pkg install -y outil$/).should be_true
    shell.ran?(/gmp|mpfr/).should be_false
  end
end
