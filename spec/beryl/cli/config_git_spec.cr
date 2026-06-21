require "../../spec_helper"
require "file_utils"
require "../../../src/beryl/cli/config_git"

# Crée un dossier temporaire `git init`-ialisé (avec user.name/email
# locaux pour que `git commit` n'échoue pas sur un poste sans config
# globale), yield son chemin, puis nettoie.
private def with_temp_repo(&)
  dir = File.tempname("beryl-configgit", "")
  Dir.mkdir_p(dir)
  run_git(dir, ["init", "-q"])
  run_git(dir, ["config", "user.email", "test@beryl.local"])
  run_git(dir, ["config", "user.name", "Beryl Test"])
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Crée un dossier temporaire SANS dépôt git.
private def with_temp_plain(&)
  dir = File.tempname("beryl-plain", "")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def run_git(root : String, args : Array(String)) : String
  buf = IO::Memory.new
  Process.run("git", ["-C", root] + args, output: buf, error: buf, input: Process::Redirect::Close)
  buf.to_s
end

# Comme `run_git` mais ne capture QUE stdout (stderr fermé) : utile pour
# `git log`/`git ls-files` dont les `fatal:` (dépôt sans commit, etc.)
# pollueraient l'assertion.
private def run_git_stdout(root : String, args : Array(String)) : String
  buf = IO::Memory.new
  Process.run("git", ["-C", root] + args, output: buf, error: Process::Redirect::Close, input: Process::Redirect::Close)
  buf.to_s
end

private def commit_subjects(root : String) : Array(String)
  log = run_git_stdout(root, ["log", "--pretty=%s"])
  log.lines.map(&.strip).reject(&.empty?)
end

private def tracked?(root : String, relpath : String) : Bool
  run_git_stdout(root, ["ls-files", "--", relpath]).lines.map(&.strip).includes?(relpath)
end

describe Beryl::CLI::ConfigGit do
  describe ".repo_root_for" do
    it "remonte depuis un fichier imbriqué jusqu'à la racine du dépôt" do
      with_temp_repo do |root|
        nested = File.join(root, "popi.net", "host.host.yml")
        Dir.mkdir_p(File.dirname(nested))
        File.write(nested, "ok\n")
        # `git init` peut créer un lien symbolique sur macOS (/var → /private/var) :
        # on compare les chemins réels.
        real = File.real_path(Beryl::CLI::ConfigGit.repo_root_for(nested).not_nil!)
        real.should eq(File.real_path(root))
      end
    end

    it "retourne nil hors de tout dépôt git" do
      with_temp_plain do |dir|
        file = File.join(dir, "host.yml")
        File.write(file, "ok\n")
        Beryl::CLI::ConfigGit.repo_root_for(file).should be_nil
      end
    end
  end

  describe ".commit" do
    it "commite un fichier écrit dans le dépôt" do
      with_temp_repo do |root|
        f = File.join(root, "loulou.host.yml")
        File.write(f, "hostname: loulou\n")
        Beryl::CLI::ConfigGit.commit([f], "scan : loulou.aloli.net (1 disques, zroot raid0)", no_commit: false)

        commit_subjects(root).should eq(["scan : loulou.aloli.net (1 disques, zroot raid0)"])
        tracked?(root, "loulou.host.yml").should be_true
      end
    end

    it "ne commite rien quand no_commit est vrai" do
      with_temp_repo do |root|
        f = File.join(root, "loulou.host.yml")
        File.write(f, "hostname: loulou\n")
        Beryl::CLI::ConfigGit.commit([f], "scan : loulou", no_commit: true)

        commit_subjects(root).should be_empty
        tracked?(root, "loulou.host.yml").should be_false
      end
    end

    it "ne crée pas de commit hors d'un dépôt git (skip sans planter)" do
      with_temp_plain do |dir|
        f = File.join(dir, "loulou.host.yml")
        File.write(f, "hostname: loulou\n")
        # Ne doit pas lever d'exception.
        Beryl::CLI::ConfigGit.commit([f], "scan : loulou", no_commit: false)
        Dir.exists?(File.join(dir, ".git")).should be_false
      end
    end

    it "ne crée pas de second commit si rien n'a changé (idempotent)" do
      with_temp_repo do |root|
        f = File.join(root, "loulou.host.yml")
        File.write(f, "hostname: loulou\n")
        Beryl::CLI::ConfigGit.commit([f], "scan : v1", no_commit: false)
        # Réécrit le MÊME contenu : working tree propre après le 1er commit.
        File.write(f, "hostname: loulou\n")
        Beryl::CLI::ConfigGit.commit([f], "scan : v2", no_commit: false)

        commit_subjects(root).should eq(["scan : v1"])
      end
    end

    it "crée un nouveau commit quand le contenu change" do
      with_temp_repo do |root|
        f = File.join(root, "loulou.host.yml")
        File.write(f, "hostname: loulou\n")
        Beryl::CLI::ConfigGit.commit([f], "scan : v1", no_commit: false)
        File.write(f, "hostname: loulou\nraid: 1\n")
        Beryl::CLI::ConfigGit.commit([f], "scan : v2", no_commit: false)

        commit_subjects(root).should eq(["scan : v2", "scan : v1"])
      end
    end

    it "ne commite jamais un fichier gitignore (secret en clair)" do
      with_temp_repo do |root|
        File.write(File.join(root, ".gitignore"), ".env.yml\n")
        secret = File.join(root, ".env.yml")
        File.write(secret, "OVH_APPLICATION_KEY: super-secret\n")
        Beryl::CLI::ConfigGit.commit([secret], "add-provider : popi/ovh", no_commit: false)

        # Le fichier ignoré n'a pas été stagé → aucun commit créé.
        commit_subjects(root).should be_empty
        tracked?(root, ".env.yml").should be_false
      end
    end
  end
end
