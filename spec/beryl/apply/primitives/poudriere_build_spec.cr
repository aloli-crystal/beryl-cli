require "../../../spec_helper"

describe Beryl::Apply::PoudriereBuild do
  it "est enregistrée sous `poudriere-build`" do
    Beryl::Apply::Primitive["poudriere-build"]?.should_not be_nil
  end

  it "jail_name / alias_name / set_name" do
    Beryl::Apply::PoudriereBuild.jail_name("15.1", "amd64").should eq("fbsd151amd64")
    Beryl::Apply::PoudriereBuild.alias_name("15", "amd64").should eq("FreeBSD:15:amd64")
    Beryl::Apply::PoudriereBuild.set_name("15.1", "amd64", "default").should eq("fbsd151amd64-default")
  end

  it "set_version : reconstruit la version depuis le nom de set" do
    Beryl::Apply::PoudriereBuild.set_version("fbsd151amd64-default", "15", "amd64", "default").should eq("15.1")
    Beryl::Apply::PoudriereBuild.set_version("fbsd1510amd64-default", "15", "amd64", "default").should eq("15.10")
    Beryl::Apply::PoudriereBuild.set_version("autre-chose", "15", "amd64", "default").should be_nil
  end

  it "build_script : jail conditionnelle, bulk overlay, repoint alias ABI" do
    s = Beryl::Apply::PoudriereBuild.build_script(
      "15.1", "amd64", "default", "quimeo", "/etc/pkglist", "/pkg", nil)
    s.should contain("poudriere jail -c -j fbsd151amd64 -v 15.1-RELEASE -a amd64")
    s.should contain("poudriere bulk -j fbsd151amd64 -p default -O quimeo -f /etc/pkglist")
    s.should contain("ln -sfh fbsd151amd64-default /pkg/FreeBSD:15:amd64")
    # Arbre de ports remis à l'état git AVANT le pull (sinon `ports -u` échoue
    # sur les modifs non commitées d'un reapply précédent).
    s.should contain("git -C \"$PTDIR\" reset -q --hard")
    (s.index!("reset -q --hard") < s.index!("poudriere ports -u -p default")).should be_true
  end

  it "build_script : intègre le reapply si fourni (avec $PTDIR + garde-fou absent)" do
    s = Beryl::Apply::PoudriereBuild.build_script(
      "15.1", "amd64", "default", "quimeo", "/etc/pkglist", "/pkg", "/re/apply.sh")
    s.should contain("if [ -x /re/apply.sh ]; then /re/apply.sh \"$PTDIR\"")
    s.should contain("reapply absent ou non exécutable") # prévient au lieu de skip silencieux
  end
end
