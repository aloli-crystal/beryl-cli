require "../../../spec_helper"
require "../../../support/fake_shell"

private def params(yaml : String) : Hash(String, YAML::Any)
  h = {} of String => YAML::Any
  YAML.parse(yaml).as_h.each { |k, v| h[k.as_s] = v }
  h
end

private def pkg_upgrade : Beryl::Apply::Primitive
  Beryl::Apply::Primitive["pkg-upgrade"]?.not_nil!
end

private def ctx
  Beryl::Apply::Context.new
end

private PARAMS = <<-YAML
  packages: [partiduo-app, partiduo-app-devel]
  restart: [partiduo, partiduo_devel]
  YAML

# Les deux paquets installés, partiduo-app en retard ; partiduo activé,
# partiduo_devel non activé.
private def outdated_shell : FakeShell
  sh = FakeShell.new
  sh.stub(/pkg info -e/, exit_code: 0)
  sh.stub(/pkg version/, stdout: <<-OUT)
    curl-8.9.0                         <   needs updating (remote has 8.10.1)
    partiduo-app-1.2.3                 <   needs updating (remote has 1.2.4)
    OUT
  sh.stub(/sysrc -n partiduo_enable/, stdout: "yes\n")
  sh.stub(/sysrc -n partiduo_devel_enable/, stdout: "NO\n")
  sh
end

describe Beryl::Apply::PkgUpgrade do
  it "est enregistrée sous `pkg-upgrade`" do
    Beryl::Apply::Primitive["pkg-upgrade"]?.should_not be_nil
  end

  describe ".parse_outdated" do
    it "ne garde que les paquets voulus, nom à tirets et versions de → vers" do
      txt = "partiduo-app-devel-0.9.1_1    <   needs updating (remote has 0.9.2)\n" \
            "partiduo-app-1.0,1            <   needs updating (remote has 1.1,1)\n" \
            "zsh-5.9                       <   needs updating (remote has 5.9_1)\n"
      res = Beryl::Apply::PkgUpgrade.parse_outdated(txt, ["partiduo-app", "partiduo-app-devel"])
      res.map(&.name).should eq(["partiduo-app-devel", "partiduo-app"])
      res[0].from.should eq("0.9.1_1")
      res[0].to.should eq("0.9.2")
      res[1].to.should eq("1.1,1")
    end

    it "sortie vide (tout est à jour) → rien" do
      Beryl::Apply::PkgUpgrade.parse_outdated("", ["partiduo-app"]).should be_empty
    end
  end

  it "skip si les paquets installés sont à jour (et ne relance rien)" do
    sh = FakeShell.new
    sh.stub(/pkg info -e/, exit_code: 0)
    sh.stub(/pkg version/, stdout: "")
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    r.message.should contain("à jour")
    sh.ran?(/pkg update -q/).should be_true
    sh.ran?(/pkg upgrade/).should be_false
    sh.ran?(/service .* restart/).should be_false
  end

  it "ignore un paquet non installé, sans erreur" do
    sh = outdated_shell
    sh.stub(/pkg info -e partiduo-app-devel/, exit_code: 1)
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("ignoré(s) : partiduo-app-devel")
    sh.ran?(/pkg upgrade -y partiduo-app$/).should be_true
  end

  it "skip si aucun des paquets n'est installé" do
    sh = FakeShell.new
    sh.stub(/pkg info -e/, exit_code: 1)
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    sh.ran?(/pkg version/).should be_false
  end

  it "met à jour le seul paquet en retard puis relance les seuls services activés" do
    sh = outdated_shell
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("partiduo-app 1.2.3 → 1.2.4")
    r.message.should contain("relancé(s) : partiduo ;")
    r.message.should contain("non relancé(s) : partiduo_devel")
    # curl est en retard aussi mais n'est pas dans la liste : pas demandé.
    sh.ran?(/pkg upgrade -y partiduo-app$/).should be_true
    sh.ran?(/curl/).should be_false
    sh.ran?(/service partiduo restart/).should be_true
    sh.ran?(/service partiduo_devel restart/).should be_false
    # Ordre : upgrade AVANT restart.
    up = sh.commands.index!(&.starts_with?("pkg upgrade"))
    rs = sh.commands.index!(&.includes?("service partiduo restart"))
    (up < rs).should be_true
  end

  it "sans `restart` : met à jour sans relancer" do
    sh = outdated_shell
    r = pkg_upgrade.apply(sh, params("packages: [partiduo-app]"), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.ran?(/sysrc/).should be_false
    sh.ran?(/service/).should be_false
  end

  it "dry-run : plan (versions, services) sans upgrade ni restart" do
    sh = outdated_shell
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: true, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    r.message.should contain("dry-run")
    r.message.should contain("partiduo-app 1.2.3 → 1.2.4")
    r.message.should contain("relancerait : partiduo")
    sh.ran?(/pkg upgrade/).should be_false
    sh.ran?(/service .* restart/).should be_false
  end

  it "échec du pkg upgrade → Failed, aucun service relancé" do
    sh = outdated_shell
    sh.stub(/pkg upgrade -y/, exit_code: 1, stderr: "pkg: No space left on device\n")
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    r.message.should contain("No space left on device")
    sh.ran?(/service .* restart/).should be_false
  end

  it "échec d'un restart → Failed, message renvoyant au journal" do
    sh = outdated_shell
    sh.stub(/sysrc -n partiduo_devel_enable/, stdout: "YES\n")
    sh.stub(/service partiduo restart/, exit_code: 1, stderr: "partiduo: migration impossible\n")
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    r.message.should contain("partiduo (code 1 : partiduo: migration impossible)")
    r.message.should contain("journal")
    # L'autre service activé est tout de même tenté.
    sh.ran?(/service partiduo_devel restart/).should be_true
  end

  it "échec du pkg update → Failed" do
    sh = FakeShell.new
    sh.stub(/pkg update/, exit_code: 3, stderr: "pkg: repository unreachable\n")
    r = pkg_upgrade.apply(sh, params(PARAMS), dry_run: false, context: ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Failed)
    sh.ran?(/pkg upgrade/).should be_false
  end

  it "`packages` obligatoire et non vide" do
    expect_raises(Beryl::Apply::Primitive::MissingParam, /packages/) do
      pkg_upgrade.apply(FakeShell.new, params("restart: [partiduo]"), dry_run: true, context: ctx)
    end
    expect_raises(Beryl::Apply::Primitive::MissingParam, /packages/) do
      pkg_upgrade.apply(FakeShell.new, params("packages: []"), dry_run: true, context: ctx)
    end
  end
end
