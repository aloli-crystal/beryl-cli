require "file_utils"
require "../../spec_helper"
require "../../../src/beryl/cli/pkg_ops"

# Joue `script` avec sh et un faux `pkg` en tête du PATH : `pkg rquery -a`
# rend `remote`, `pkg query '%n %R'` rend `installed` (« nom dépôt »), et
# `pkg upgrade` affiche ses arguments. Renvoie la sortie.
private def run_with_fake_pkg(script : String, remote : Array(String), installed : Array(String)) : String
  dir = File.tempname("beryl-fake-pkg")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "remote"), remote.join("\n") + "\n")
  File.write(File.join(dir, "installed"), installed.join("\n") + "\n")
  pkg = File.join(dir, "pkg")
  File.write(pkg, <<-SH)
    #!/bin/sh
    case "$1" in
      update) exit 0 ;;
      rquery) cat "#{dir}/remote" ;;
      query) cat "#{dir}/installed" ;;
      upgrade) shift; echo "UPGRADE $*" ;;
    esac
    SH
  File.chmod(pkg, 0o755)
  buf = IO::Memory.new
  Process.run("sh", ["-c", script], env: {"PATH" => "#{dir}:#{ENV["PATH"]}"}, output: buf, error: buf)
  buf.to_s
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Beryl::CLI::Upgrade do
  describe ".software_cmd" do
    it "n'envoie à pkg upgrade que les paquets hors du dépôt de base, disponibles dans un dépôt" do
      res = run_with_fake_pkg(Beryl::CLI::Upgrade.software_cmd(false),
        remote: %w[FreeBSD-kernel-generic FreeBSD-runtime expat nginx-lite partiduo-app],
        installed: ["FreeBSD-kernel-generic FreeBSD-base", "FreeBSD-runtime FreeBSD-base",
                    "expat FreeBSD-ports", "nginx-lite quimeo", "partiduo-app aloli",
                    "outil-local unknown-repository"])
      res.should eq("UPGRADE -n expat nginx-lite partiduo-app\n")
    end

    it "en --apply, même liste avec -y" do
      res = run_with_fake_pkg(Beryl::CLI::Upgrade.software_cmd(true),
        remote: %w[FreeBSD-runtime expat], installed: ["FreeBSD-runtime FreeBSD-base", "expat FreeBSD-ports"])
      res.should eq("UPGRADE -y expat\n")
    end

    it "jamais de `pkg upgrade` nu (qui toucherait le noyau) quand aucun paquet logiciel" do
      res = run_with_fake_pkg(Beryl::CLI::Upgrade.software_cmd(false),
        remote: %w[FreeBSD-runtime], installed: ["FreeBSD-runtime FreeBSD-base"])
      res.should_not contain("UPGRADE")
      res.should contain("aucun paquet logiciel")
    end

    it "liste fermée (--recipes) : ces paquets seulement" do
      Beryl::CLI::Upgrade.software_cmd(false, ["nginx-lite", "monit"]).should eq("pkg upgrade -n nginx-lite monit")
    end
  end

  describe ".pending_count" do
    it "compte les paquets annoncés par pkg" do
      sample = "Installed packages to be UPGRADED:\n\tFreeBSD-runtime: 15.1p4 -> 15.1p5 [FreeBSD-base]\n\n" \
               "Number of packages to be upgraded: 7\n\n65 MiB to be downloaded.\n"
      Beryl::CLI::Upgrade.pending_count(sample).should eq(7)
    end

    it "0 quand tout est à jour" do
      Beryl::CLI::Upgrade.pending_count("Your packages are up to date.\n").should eq(0)
    end
  end
end
