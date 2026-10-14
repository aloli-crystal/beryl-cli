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

# Joue `services_cmd` avec de faux `pkg` (dépendances inverses, fichiers) et
# `service` (activés). `rdeps` : paquet → paquets qui en dépendent ;
# `files` : paquet → fichiers installés ; `enabled` : services activés.
private def services_with_fakes(pkgs : Array(String), rdeps : Hash(String, Array(String)),
                                files : Hash(String, Array(String)), enabled : Array(String)) : Array(String)
  dir = File.tempname("beryl-fake-svc")
  Dir.mkdir_p(dir)
  rdeps.each { |p, l| File.write(File.join(dir, "rdeps-#{p}"), l.join("\n") + "\n") }
  files.each { |p, l| File.write(File.join(dir, "files-#{p}"), l.join("\n") + "\n") }
  File.write(File.join(dir, "pkg"), <<-SH)
    #!/bin/sh
    # pkg query %rn <p> | pkg query %Fp <p>
    case "$2" in
      %rn) cat "#{dir}/rdeps-$3" 2>/dev/null ;;
      %Fp) cat "#{dir}/files-$3" 2>/dev/null ;;
    esac
    SH
  File.write(File.join(dir, "service"), <<-SH)
    #!/bin/sh
    case " #{enabled.join(" ")} " in *" $1 "*) exit 0 ;; esac
    exit 1
    SH
  File.chmod(File.join(dir, "pkg"), 0o755)
  File.chmod(File.join(dir, "service"), 0o755)
  buf = IO::Memory.new
  Process.run("sh", ["-c", Beryl::CLI::Upgrade.services_cmd(pkgs)], env: {"PATH" => "#{dir}:#{ENV["PATH"]}"}, output: buf, error: buf)
  buf.to_s.lines.map(&.strip).reject(&.empty?)
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "Beryl::CLI::Upgrade, services touchés" do
  it "relève les paquets mis à jour et réinstallés, pas les nouveaux" do
    out_loulou = <<-OUT
      The following 15 package(s) will be affected (of 0 checked):

      New packages to be INSTALLED:
      \tage: 1.3.2_2 [aloli]

      Installed packages to be UPGRADED:
      \tacme.sh: 3.1.3_1 -> 3.1.6 [FreeBSD-ports]
      \texpat: 2.8.2 -> 2.8.4 [FreeBSD-ports] (vulnerable!)
      \tnginx: 1.30.4,3 -> 1.30.5_2,3 [FreeBSD-ports]

      Installed packages to be REINSTALLED:
      \tnginx-lite-1.30.5_2,3 [quimeo] (options changed)

      Number of packages to be upgraded: 3
      OUT
    Beryl::CLI::Upgrade.changed_packages(out_loulou).should eq(%w[acme.sh expat nginx nginx-lite])
  end

  it "aucun paquet modifié quand tout est à jour" do
    Beryl::CLI::Upgrade.changed_packages("Your packages are up to date.\n").should be_empty
  end

  it "suit les dépendances inverses jusqu'aux services ACTIVÉS (expat → nginx-lite → nginx)" do
    services_with_fakes(
      %w[expat],
      rdeps: {"expat" => %w[nginx-lite git], "nginx-lite" => [] of String, "git" => [] of String},
      files: {"nginx-lite" => %w[/usr/local/sbin/nginx /usr/local/etc/rc.d/nginx],
              "git"        => %w[/usr/local/bin/git]},
      enabled: %w[nginx],
    ).should eq(%w[nginx])
  end

  it "écarte un service présent mais NON activé, et ne boucle pas sur un cycle" do
    services_with_fakes(
      %w[a],
      rdeps: {"a" => %w[b], "b" => %w[a]},
      files: {"a" => %w[/usr/local/etc/rc.d/monit], "b" => %w[/usr/local/etc/rc.d/postgresql]},
      enabled: %w[postgresql],
    ).should eq(%w[postgresql])
  end
end
