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

describe "Beryl::CLI::Upgrade (audit et tableau de flotte)" do
  it "audit : base rafraîchie (-F) sauf sur un host protégé" do
    Beryl::CLI::Upgrade.audit_cmd(true).should eq("pkg audit -F -q")
    Beryl::CLI::Upgrade.audit_cmd(false).should eq("pkg audit -q")
  end

  it "vulnerable_packages : « nom-version » seulement, diagnostics ignorés" do
    output = "vulnxml file up-to-date\ncurl-8.5.0\nexpat-2.6.0_1\ncurl-8.5.0\n\n"
    Beryl::CLI::Upgrade.vulnerable_packages(output).should eq(%w[curl-8.5.0 expat-2.6.0_1])
    Beryl::CLI::Upgrade.vulnerable_packages("").should be_empty
  end

  it "audit_alert : nil sans vulnérabilité, sinon serveur + paquets" do
    Beryl::CLI::Upgrade.audit_alert({"a.example.net" => [] of String}).should be_nil
    alert = Beryl::CLI::Upgrade.audit_alert({"a.example.net" => %w[curl-8.5.0 expat-2.6.0], "b.example.net" => [] of String}).not_nil!
    alert.should contain("ALERTE SÉCURITÉ")
    alert.should contain("  a.example.net : curl-8.5.0, expat-2.6.0")
    alert.should_not contain("b.example.net")
  end

  it "pending_lines : lignes de mise à jour au format de pkg, toutes sections" do
    output = <<-OUT
      Checking integrity... done (0 conflicting)
      The following 3 package(s) will be affected (of 0 checked):

      New packages to be INSTALLED:
      \tlibffi: 3.4.6 [FreeBSD-ports]

      Installed packages to be UPGRADED:
      \tpartiduo-connect-devel: 0.1.46 -> 0.1.47 [aloli]
      \tpython312: 3.12.14_1 -> 3.12.15 [FreeBSD-ports]

      Number of packages to be upgraded: 2
      OUT
    Beryl::CLI::Upgrade.pending_lines(output).should eq([
      "libffi: 3.4.6 [FreeBSD-ports]",
      "partiduo-connect-devel: 0.1.46 -> 0.1.47 [aloli]",
      "python312: 3.12.14_1 -> 3.12.15 [FreeBSD-ports]",
    ])
    Beryl::CLI::Upgrade.pending_lines("Your packages are up to date.\n").should be_empty
  end

  it "fleet_output : FQDN puis lignes pkg indentées, (vulnerable!) en fin de ligne" do
    states = [
      Beryl::CLI::Upgrade::HostState.new("shingouz.example.net", true, "pas encore installé"),
      Beryl::CLI::Upgrade::HostState.new("loulou.example.net", true, "à jour",
        ["partiduo-connect-devel: 0.1.46 -> 0.1.47 [aloli]", "python312: 3.12.14_1 -> 3.12.15 [FreeBSD-ports]"],
        %w[python312-3.12.14_1]),
      Beryl::CLI::Upgrade::HostState.new("tika.example.net", true, "à jour"),
      Beryl::CLI::Upgrade::HostState.new("qwerty.example.net", false, "SSH KO : timeout", vulns: nil),
    ]
    Beryl::CLI::Upgrade.fleet_output(states).should eq(<<-OUT.chomp)
      shingouz.example.net : pas encore installé

      loulou.example.net
      \tpartiduo-connect-devel: 0.1.46 -> 0.1.47 [aloli]
      \tpython312: 3.12.14_1 -> 3.12.15 [FreeBSD-ports] (vulnerable!)

      tika.example.net : à jour

      qwerty.example.net : SSH KO : timeout
      OUT
  end

  it "fleet_block : vulnérable sans mise à jour disponible, audit impossible signalés" do
    st = Beryl::CLI::Upgrade::HostState.new("a.example.net", true, "à jour", vulns: %w[curl-8.5.0])
    Beryl::CLI::Upgrade.fleet_block(st).should eq("a.example.net\n\tcurl-8.5.0 (vulnerable!) — pas de mise à jour disponible")
    st = Beryl::CLI::Upgrade::HostState.new("b.example.net", true, "à jour", vulns: nil)
    Beryl::CLI::Upgrade.fleet_block(st).should eq("b.example.net\n\tpkg audit impossible")
  end
end

describe "Beryl::CLI::Upgrade.fleet_hint" do
  it "nil quand tout est à jour (ou pas encore installé)" do
    states = [
      Beryl::CLI::Upgrade::HostState.new("a", true, "à jour"),
      Beryl::CLI::Upgrade::HostState.new("b", true, "pas encore installé"),
    ]
    Beryl::CLI::Upgrade.fleet_hint(states).should be_nil
  end

  it "décompte des seules actions à faire + commandes" do
    states = [
      Beryl::CLI::Upgrade::HostState.new("a", true, "à jour", ["python312: 3.12.14_1 -> 3.12.15 [FreeBSD-ports]"], %w[python312-3.12.14_1]),
      Beryl::CLI::Upgrade::HostState.new("b", false, "SSH KO : timeout", vulns: nil),
      Beryl::CLI::Upgrade::HostState.new("c", true, "à jour"),
    ]
    hint = Beryl::CLI::Upgrade.fleet_hint(states).not_nil!
    hint.should start_with("→ 1 avec mises à jour · 1 avec paquets vulnérables · 1 injoignable(s) : ")
    hint.should contain("beryl upgrade <portée> --apply")
  end
end
