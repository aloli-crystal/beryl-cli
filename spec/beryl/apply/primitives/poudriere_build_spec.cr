require "../../../spec_helper"
require "../../../support/fake_shell"
require "file_utils"

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
      "15.1", "amd64", "default", ["globex"], ["/etc/pkglist"], "/pkg", nil)
    s.should contain("poudriere jail -c -j fbsd151amd64 -v 15.1-RELEASE -a amd64")
    s.should contain("poudriere bulk -j fbsd151amd64 -p default -O globex -f /etc/pkglist")
    s.should contain("ln -sfh fbsd151amd64-default /pkg/FreeBSD:15:amd64")
    # Arbre de ports remis à l'état git AVANT le pull (sinon `ports -u` échoue
    # sur les modifs non commitées d'un reapply précédent).
    s.should contain("git -C \"$PTDIR\" reset -q --hard")
    (s.index!("reset -q --hard") < s.index!("poudriere ports -u -p default")).should be_true
  end

  it "build_script : intègre le reapply si fourni (avec $PTDIR + garde-fou absent)" do
    s = Beryl::Apply::PoudriereBuild.build_script(
      "15.1", "amd64", "default", ["globex"], ["/etc/pkglist"], "/pkg", "/re/apply.sh")
    s.should contain("if [ -x /re/apply.sh ]; then /re/apply.sh \"$PTDIR\"")
    s.should contain("reapply absent ou non exécutable") # prévient au lieu de skip silencieux
  end
end

private def pb_params(yaml : String) : Hash(String, YAML::Any)
  h = {} of String => YAML::Any
  YAML.parse(yaml).as_h.each { |k, v| h[k.as_s] = v }
  h
end

private def pb : Beryl::Apply::Primitive
  Beryl::Apply::Primitive["poudriere-build"]?.not_nil!
end

private def pb_ctx
  Beryl::Apply::Context.new
end

# Fige la « dernière release » le temps d'un bloc (pas de réseau en spec).
private def with_latest(version : String?, &)
  saved = Beryl::Apply::PoudriereBuild.release_lookup
  Beryl::Apply::PoudriereBuild.release_lookup = -> {
    h = {} of Int32 => String
    if v = version
      h[v.split('.').first.to_i] = v
    end
    h
  }
  begin
    yield
  ensure
    Beryl::Apply::PoudriereBuild.release_lookup = saved
  end
end

private LEGACY = <<-YAML
  major: "15"
  pkglist: /usr/local/etc/poudriere.d/globex-pkglist
  overlay: globex
  YAML

private TWO = <<-YAML
  major: "15"
  overlays:
    - name: globex
      pkglist: /usr/local/etc/poudriere.d/globex-pkglist
    - name: initech
      git: https://github.com/initech/initech-ports
      branch: production
      pkglist: /usr/local/etc/poudriere.d/initech-pkglist
  YAML

GLOBEX_SHA  = "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
INITECH_OLD = "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
INITECH_NEW = "3333333ccccccccccccccccccccccccccccccccc"

# Builder « à jour » : alias sur 15.1, globex et initech enregistrés et
# clonés, initech propre sur production, état = commits courants.
private def builder_shell : FakeShell
  sh = FakeShell.new
  sh.stub(/readlink/, stdout: "fbsd151amd64-default\n")
  sh.stub(/test -f .*\.lock/, exit_code: 1)
  sh.stub(/poudriere ports -lq/, stdout: <<-OUT)
    default    git+https 2026-09-01 10:00:00 /usr/local/poudriere/ports/default
    globex     null      2026-06-17 12:00:00 /usr/local/poudriere/globex-ports
    initech      null      2026-09-20 09:00:00 /usr/local/poudriere/initech-ports
    OUT
  sh.stub(/globex-ports rev-parse HEAD/, stdout: "#{GLOBEX_SHA}\n")
  sh.stub(/initech-ports rev-parse HEAD/, stdout: "#{INITECH_OLD}\n")
  sh.stub(/initech-ports symbolic-ref/, stdout: "production\n")
  sh.stub(/initech-ports status --porcelain/, stdout: "")
  sh.stub(/initech-ports rev-parse .*refs\/remotes\/origin\/production/, stdout: "#{INITECH_OLD}\n")
  sh.stub(/initech-ports ls-remote/, stdout: "#{INITECH_OLD}\trefs/heads/production\n")
  sh.stub(/cat .*\.beryl-build-15\.overlays/, stdout: "globex #{GLOBEX_SHA}\ninitech #{INITECH_OLD}\n")
  sh
end

private def launched?(sh : FakeShell) : Bool
  sh.ran?(/daemon -f/)
end

describe "Beryl::Apply::PoudriereBuild (overlays)" do
  it "build_script : plusieurs -O, réunion des -f, état écrit APRÈS l'alias" do
    s = Beryl::Apply::PoudriereBuild.build_script(
      "15.1", "amd64", "default", ["globex", "initech"], ["/q.list", "/a.list"], "/pkg", nil,
      {"globex" => "abc", "initech" => "def"}, "/pkg/.beryl-build-15.overlays")
    s.should contain("poudriere bulk -j fbsd151amd64 -p default -O globex -O initech -f /q.list -f /a.list")
    s.should contain("printf '%s\\n' 'globex abc' 'initech def' > /pkg/.beryl-build-15.overlays.tmp")
    s.should contain("mv -f /pkg/.beryl-build-15.overlays.tmp /pkg/.beryl-build-15.overlays")
    (s.index!("ln -sfh") < s.index!("printf '%s")).should be_true
    (s.index!("poudriere bulk") < s.index!("ln -sfh")).should be_true
    s.should contain("poudriere pkgclean -y -j fbsd151amd64 -p default -O globex -O initech -f /q.list -f /a.list ||")
    (s.index!("poudriere bulk") < s.index!("poudriere pkgclean") < s.index!("ln -sfh")).should be_true
  end

  it "parse_state / parse_trees" do
    Beryl::Apply::PoudriereBuild.parse_state("globex abc\n\ninitech def\n").should eq({"globex" => "abc", "initech" => "def"})
    Beryl::Apply::PoudriereBuild.parse_trees("initech null 2026-09-20 09:00:00 /usr/local/poudriere/initech-ports\n")
      .should eq({"initech" => "/usr/local/poudriere/initech-ports"})
  end

  describe "ancien schéma (overlay: + pkglist:)" do
    it "à jour, overlay non git → Skipped sans aucune commande git d'écriture" do
      with_latest("15.1") do
        sh = builder_shell
        sh.stub(/test -d .*globex-ports\/\.git/, exit_code: 1)
        r = pb.apply(sh, pb_params(LEGACY), false, pb_ctx)
        r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
        r.message.should contain("déjà à jour sur 15.1")
        sh.ran?(/git .*(fetch|clone|merge)/).should be_false
        sh.ran?(/poudriere ports -c/).should be_false
        launched?(sh).should be_false
      end
    end

    it "nouvelle mineure → build -O globex -f <pkglist> (comme avant)" do
      with_latest("15.2") do
        sh = builder_shell
        r = pb.apply(sh, pb_params(LEGACY), false, pb_ctx)
        r.outcome.should eq(Beryl::Apply::Outcome::Applied)
        r.message.should contain("FreeBSD 15.2 (← 15.1)")
        script = sh.writes.first.content
        script.should contain("poudriere bulk -j fbsd152amd64 -p default -O globex -f /usr/local/etc/poudriere.d/globex-pkglist")
        script.should contain("'globex #{GLOBEX_SHA}'")
        launched?(sh).should be_true
      end
    end

    it "à jour et commit globex identique à l'état → Skipped" do
      with_latest("15.1") do
        sh = builder_shell
        r = pb.apply(sh, pb_params(LEGACY), false, pb_ctx)
        r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      end
    end
  end

  it "deux overlays inchangés → Skipped (fetch fait, aucune fusion, aucun build)" do
    with_latest("15.1") do
      sh = builder_shell
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      r.message.should contain("initech@2222222")
      sh.ran?(/initech-ports fetch -q origin/).should be_true
      sh.ran?(/merge -q --ff-only/).should be_false
      launched?(sh).should be_false
    end
  end

  it "overlay changé → avance rapide + build des deux overlays, sans nouvelle mineure" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/initech-ports rev-parse .*refs\/remotes\/origin\/production/, stdout: "#{INITECH_NEW}\n")
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("overlay initech 2222222 → 3333333")
      r.message.should_not contain("FreeBSD 15")
      sh.ran?(/initech-ports merge -q --ff-only/).should be_true
      script = sh.writes.first.content
      script.should contain("poudriere bulk -j fbsd151amd64 -p default -O globex -O initech " \
                            "-f /usr/local/etc/poudriere.d/globex-pkglist -f /usr/local/etc/poudriere.d/initech-pkglist")
      script.should contain("'initech #{INITECH_NEW}'")
      launched?(sh).should be_true
    end
  end

  it "état absent (premier passage) → build" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/cat .*\.beryl-build-15\.overlays/, stdout: "", exit_code: 1)
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("overlay initech ∅ → 2222222")
      launched?(sh).should be_true
    end
  end

  it "overlay absent → clone + enregistrement poudriere + build" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/poudriere ports -lq/, stdout: "globex null 2026-06-17 12:00:00 /usr/local/poudriere/globex-ports\n")
      sh.stub(/test -d \/usr\/local\/poudriere\/initech-ports\/\.git/, exit_code: 1)
      sh.stub(/test -e \/usr\/local\/poudriere\/initech-ports/, exit_code: 1)
      sh.stub(/cat .*\.beryl-build-15\.overlays/, stdout: "globex #{GLOBEX_SHA}\n") # initech jamais construit
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      sh.ran?(/git clone -q -b production https:\/\/github.com\/initech\/initech-ports \/usr\/local\/poudriere\/initech-ports/).should be_true
      sh.ran?(/poudriere ports -c -p initech -m null -M \/usr\/local\/poudriere\/initech-ports/).should be_true
      clone = sh.commands.index!(&.starts_with?("git clone"))
      reg = sh.commands.index!(&.starts_with?("poudriere ports -c"))
      (clone < reg).should be_true
      launched?(sh).should be_true
    end
  end

  it "dry-run : plan (clone, enregistrement, build) sans rien modifier" do
    with_latest("15.2") do
      sh = builder_shell
      sh.stub(/poudriere ports -lq/, stdout: "globex null 2026-06-17 12:00:00 /usr/local/poudriere/globex-ports\n")
      sh.stub(/test -d \/usr\/local\/poudriere\/initech-ports\/\.git/, exit_code: 1)
      sh.stub(/test -e \/usr\/local\/poudriere\/initech-ports/, exit_code: 1)
      r = pb.apply(sh, pb_params(TWO), true, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("clone https://github.com/initech/initech-ports (production)")
      r.message.should contain("enregistrement poudriere initech")
      r.message.should contain("FreeBSD 15.2")
      r.message.should contain("dry-run")
      sh.ran?(/git clone|poudriere ports -c|touch|daemon/).should be_false
      sh.writes.should be_empty
    end
  end

  it "dry-run sur overlay en retard : git ls-remote, ni fetch ni fusion" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/initech-ports ls-remote/, stdout: "#{INITECH_NEW}\trefs/heads/production\n")
      sh.stub(/merge-base --is-ancestor/, exit_code: 1)
      r = pb.apply(sh, pb_params(TWO), true, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("serait mis à jour 2222222 → 3333333")
      sh.ran?(/fetch|merge -q|daemon/).should be_false
    end
  end

  it "modifications locales non commitées → Failed, rien n'est écrasé" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/initech-ports status --porcelain/, stdout: " M finance/partiduo-app/Makefile\n")
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Failed)
      r.message.should contain("finance/partiduo-app/Makefile")
      sh.ran?(/fetch|merge|reset|daemon/).should be_false
    end
  end

  it "historique divergé → Failed" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/initech-ports rev-parse .*refs\/remotes\/origin\/production/, stdout: "#{INITECH_NEW}\n")
      sh.stub(/merge-base --is-ancestor/, exit_code: 1)
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Failed)
      r.message.should contain("divergé")
      launched?(sh).should be_false
    end
  end

  it "commits locaux en avance : conservés, pas de rebuild si déjà construits" do
    with_latest("15.1") do
      sh = builder_shell
      sh.stub(/initech-ports rev-parse .*refs\/remotes\/origin\/production/, stdout: "#{INITECH_NEW}\n")
      sh.stub(/merge-base --is-ancestor HEAD/, exit_code: 1) # local pas ancêtre du distant
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      r.message.should contain("non poussés")
      sh.ran?(/merge -q/).should be_false
    end
  end

  it "build en cours (lock) → Skipped avant toute opération git" do
    with_latest("15.2") do
      sh = builder_shell
      sh.stub(/test -f .*\.lock/, exit_code: 0)
      r = pb.apply(sh, pb_params(TWO), false, pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      sh.ran?(/git /).should be_false
    end
  end

  it "validation : overlay/overlays exclusifs, overlays vide, nom invalide, pkglist requise" do
    with_latest("15.1") do
      expect_raises(Beryl::Apply::Primitive::PrimitiveError, /exclusifs/) do
        pb.apply(builder_shell, pb_params("major: \"15\"\noverlay: globex\noverlays: [initech]\npkglist: /x"), true, pb_ctx)
      end
      expect_raises(Beryl::Apply::Primitive::MissingParam, /vide/) do
        pb.apply(builder_shell, pb_params("major: \"15\"\noverlays: []\npkglist: /x"), true, pb_ctx)
      end
      expect_raises(Beryl::Apply::Primitive::PrimitiveError, /invalide/) do
        pb.apply(builder_shell, pb_params("major: \"15\"\noverlays: [\"../x\"]\npkglist: /x"), true, pb_ctx)
      end
      expect_raises(Beryl::Apply::Primitive::MissingParam, /pkglist/) do
        pb.apply(builder_shell, pb_params("major: \"15\"\noverlays: [{name: initech}]"), true, pb_ctx)
      end
    end
  end

  describe ".scheduled_script" do
    ov = [Beryl::Apply::PoudriereBuild::ScheduledOverlay.new("globex", "/p/globex-ports", nil, true),
          Beryl::Apply::PoudriereBuild::ScheduledOverlay.new("initech", "/p/initech-ports", "production", true)]
    script = Beryl::Apply::PoudriereBuild.scheduled_script("15.1", "amd64", "default", ov,
      ["/e/globex-pkglist", "/e/initech-pkglist"], "/pkg", "/e/reapply.sh")

    it "partage le verrou de beryl sync et le libère en sortie" do
      script.should contain("if [ -f /pkg/.beryl-build-15.lock ]; then")
      script.should contain("trap 'rm -f /pkg/.beryl-build-15.lock' EXIT")
    end

    it "met à jour en avance rapide les seuls overlays gérés par beryl" do
      script.should contain("git -C /p/initech-ports fetch -q origin production")
      script.should contain("git -C /p/initech-ports merge -q --ff-only FETCH_HEAD")
      script.should_not contain("git -C /p/globex-ports fetch")
    end

    it "lance le même build que beryl sync" do
      script.should contain("poudriere bulk -j fbsd151amd64 -p default -O globex -O initech -f /e/globex-pkglist -f /e/initech-pkglist")
      script.should contain("/e/reapply.sh \"$PTDIR\"")
      script.should contain("ln -sfh fbsd151amd64-default /pkg/FreeBSD:15:amd64")
    end

    it "enregistre les commits réellement construits" do
      script.should contain(%(printf '%s %s\\n' globex "$(git -C /p/globex-ports rev-parse HEAD)"))
      script.should contain("mv -f \"$TMP\" /pkg/.beryl-build-15.overlays")
    end
  end
end

# Exécute le fragment avec une fausse date et un faux git (ls-remote : code
# `remote_ok`), et renvoie la branche retenue.
private def pick_branch(date_ym : String, remote_ok : Bool) : String
  dir = File.tempname("beryl-branch")
  Dir.mkdir_p(dir)
  y, m = date_ym.split('-')
  File.write(File.join(dir, "date"), "#!/bin/sh\ncase \"$2\" in +%Y) echo #{y};; +%m) echo #{m};; esac\n")
  File.write(File.join(dir, "git"), "#!/bin/sh\nexit #{remote_ok ? 0 : 2}\n")
  File.chmod(File.join(dir, "date"), 0o755)
  File.chmod(File.join(dir, "git"), 0o755)
  script = "PTDIR=/nonexistent\n" + Beryl::Apply::PoudriereBuild.branch_script("quarterly") + "echo \"$BR\"\n"
  buf = IO::Memory.new
  Process.run("sh", ["-c", script], output: buf, env: {"PATH" => "#{dir}:/usr/bin:/bin"})
  buf.to_s.strip.lines.last
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "Beryl::Apply::PoudriereBuild.branch_script" do
  it "prend le trimestre en cours quand sa branche existe" do
    pick_branch("2026-10", true).should eq("2026Q4")
    pick_branch("2027-03", true).should eq("2027Q1")
    pick_branch("2026-06", true).should eq("2026Q2")
  end

  it "se replie sur le trimestre précédent tant que la branche n'est pas publiée" do
    pick_branch("2026-10", false).should eq("2026Q3")
    pick_branch("2027-01", false).should eq("2026Q4")
  end

  it "accepte une branche fixe" do
    Beryl::Apply::PoudriereBuild.branch_script("main").should contain("BR=main\n")
  end

  it "est inséré avant la mise à jour de l'arbre" do
    s = Beryl::Apply::PoudriereBuild.build_script("15.1", "amd64", "default", ["initech"], ["/l"], "/p", nil,
      ports_branch: "quarterly")
    (s.index!("remote set-branches") < s.index!("poudriere ports -u -p")).should be_true
  end
end

describe "Beryl::Apply::PoudriereBuild — force" do
  it "lance un build forcé même si tout est à jour" do
    with_latest("15.1") do
      sh = builder_shell
      r = pb.apply(sh, pb_params(TWO + "\nforce: \"1\"\n"), dry_run: false, context: pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("forcé")
      launched?(sh).should be_true
    end
  end

  it "force: false — rien à faire si tout est à jour" do
    with_latest("15.1") do
      sh = builder_shell
      r = pb.apply(sh, pb_params(TWO + "\nforce: \"false\"\n"), dry_run: false, context: pb_ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      launched?(sh).should be_false
    end
  end
end

describe "Beryl::Apply::PoudriereBuild — ancien schéma sans `overlay:`" do
  it "exige le nom de l'overlay (plus de valeur par défaut propre à une société)" do
    expect_raises(Beryl::Apply::Primitive::MissingParam, /overlay/) do
      pb.apply(builder_shell, pb_params("major: \"15\"\npkglist: /l\n"), dry_run: true, context: pb_ctx)
    end
  end
end
