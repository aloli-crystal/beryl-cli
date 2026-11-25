require "../../spec_helper"
require "../../support/fake_shell"

# Le protocole est joué contre un `sh` LOCAL (même amorce, même flux que le
# `sudo -n sh` distant) : aucun serveur nécessaire.
private def local_shell(fallback : Beryl::Apply::Shell = FakeShell.new, install : Bool = true) : Beryl::Apply::PersistentShell
  Beryl::Apply::PersistentShell.new("sh", [] of String, fallback, install: install).tap(&.start)
end

describe Beryl::Apply::PersistentShell do
  it "rend stdout, stderr et le code de sortie de chaque commande" do
    shell = local_shell
    shell.alive?.should be_true
    res = shell.exec("echo dehors; echo dedans >&2; exit 3", raise_on_error: false)
    res.stdout.should eq("dehors\n")
    res.stderr.should eq("dedans\n")
    res.exit_code.should eq(3)
    shell.exec("printf 'sans fin de ligne'").stdout.should eq("sans fin de ligne")
    shell.exec("printf 'é…'").stdout.should eq("é…")
  ensure
    shell.try(&.close)
  end

  it "joue un script multi-ligne avec la syntaxe sh" do
    shell = local_shell
    script = "for i in 1 2; do\n  echo \"n=$i\"\ndone\ncase x in x) echo ok ;; esac"
    shell.exec(script).stdout.should eq("n=1\nn=2\nok\n")
  ensure
    shell.try(&.close)
  end

  it "ne laisse pas une commande lire la suite du flux, ni fuir son état" do
    shell = local_shell
    shell.exec("cat").stdout.should eq("")
    shell.exec("X=fuite; cd /").success?.should be_true
    shell.exec("echo \"[$X]\"").stdout.should eq("[]\n")
    shell.exec("echo suivante").stdout.should eq("suivante\n")
  ensure
    shell.try(&.close)
  end

  it "lève CommandFailed sur un échec, sauf raise_on_error: false" do
    shell = local_shell
    expect_raises(SSH::CommandFailed) { shell.exec("false") }
    shell.exec("echo encore").stdout.should eq("encore\n")
  ensure
    shell.try(&.close)
  end

  it "écrit un fichier par install (connexion sudo), mode compris" do
    shell = local_shell
    dir = File.tempname("beryl-persistent")
    Dir.mkdir(dir)
    path = File.join(dir, "f.conf")
    shell.write_file(path, "ligne 1\nligne 'deux' $HOME\n", mode: "0600")
    File.read(path).should eq("ligne 1\nligne 'deux' $HOME\n")
    (File.info(path).permissions.value & 0o777).should eq(0o600)
    shell.write_file(path, "")
    File.read(path).should eq("")
  ensure
    shell.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "écrit un fichier par cat (connexion root) en gardant le mode existant" do
    shell = local_shell(install: false)
    dir = File.tempname("beryl-persistent")
    Dir.mkdir(dir)
    path = File.join(dir, "f.conf")
    File.write(path, "ancien")
    File.chmod(path, 0o640)
    shell.write_file(path, "nouveau")
    File.read(path).should eq("nouveau")
    (File.info(path).permissions.value & 0o777).should eq(0o640)
  ensure
    shell.try(&.close)
    FileUtils.rm_rf(dir) if dir
  end

  it "rapporte en échec la commande perdue avec la session, puis passe au repli" do
    fallback = FakeShell.new
    fallback.stub(/echo repli/, stdout: "par le repli\n")
    shell = local_shell(fallback)
    lost = shell.exec("kill -9 $PPID", raise_on_error: false)
    lost.exit_code.should eq(Beryl::Apply::PersistentShell::LOST)
    shell.alive?.should be_false
    shell.exec("echo repli").stdout.should eq("par le repli\n")
    fallback.commands.should eq(["echo repli"])
  ensure
    shell.try(&.close)
  end

  it "envoie chaque requête, fin de ligne comprise, en un seul bloc (Nagle)" do
    Beryl::Apply::PersistentShell.frame("__beryl_run 'dHJ1ZQ=='").should eq("__beryl_run 'dHJ1ZQ=='\n".to_slice)
  end

  it "étalonnage : écho, commande vide et lecture, sans casser la session" do
    shell = local_shell
    shell.calibrate(rounds: 3)
    shell.alive?.should be_true
    shell.exec("echo après").stdout.should eq("après\n")
  ensure
    shell.try(&.close)
  end

  it "passe au repli dès le départ si la session ne s'établit pas" do
    fallback = FakeShell.new
    shell = Beryl::Apply::PersistentShell.new("false", [] of String, fallback)
    shell.start.should be_false
    shell.exec("uname -s")
    shell.write_file("/tmp/x", "y")
    fallback.commands.should eq(["uname -s"])
    fallback.writes.map(&.path).should eq(["/tmp/x"])
  end
end
