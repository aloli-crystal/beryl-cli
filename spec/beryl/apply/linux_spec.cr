require "../../spec_helper"
require "../../support/fake_shell"
require "../../support/apply_helpers"

# Prise en charge de Linux (systemd, SUSE) : les primitives portées
# choisissent leurs commandes selon `context.os`.
describe "beryl apply sous Linux" do
  describe Beryl::Apply::Posix do
    it "choisit stat et sha256 GNU sous Linux, BSD sinon" do
      Beryl::Apply::Posix.mode("/etc/x", Beryl::Apply::LINUX).should eq "stat -c %a /etc/x"
      Beryl::Apply::Posix.mode("/etc/x", Beryl::Apply::FREEBSD).should eq "stat -f %Lp /etc/x"
      Beryl::Apply::Posix.owner("/etc/x", Beryl::Apply::LINUX).should eq "stat -c %U:%G /etc/x"
      Beryl::Apply::Posix.owner("/etc/x", Beryl::Apply::LINUX, with_group: false).should eq "stat -c %U /etc/x"
      Beryl::Apply::Posix.sha256("/etc/x", Beryl::Apply::LINUX).should contain "sha256sum"
      Beryl::Apply::Posix.sha256("/etc/x", Beryl::Apply::FREEBSD).should contain "sha256 -q"
    end
  end

  it "déclare Linux pour les primitives portées seulement" do
    %w[command cron-entry directory file-write file-template secret-file file-absent line-in-file symlink
      user-update-keys user-create pkg-install service-enable service-disable service-reload service-restart
      assert-env-var].each do |name|
      prim(name).systems.should contain Beryl::Apply::LINUX
    end
    %w[sysrc-set pkg-remove zfs-dataset pf-rule netif jail-create].each do |name|
      prim(name).systems.should eq [Beryl::Apply::FREEBSD]
    end
  end

  describe "user-create" do
    it "crée l'utilisateur avec useradd, nom en dernier" do
      shell = FakeShell.new
      shell.stub(/getent passwd/, exit_code: 2)
      result = prim("user-create").apply(shell, apply_params("{name: deploy, shell: /bin/bash, groups: [wheel]}"),
        dry_run: false, context: linux_ctx)
      result.outcome.should eq Beryl::Apply::Outcome::Applied
      shell.ran?(/^useradd -m -s \/bin\/bash -G wheel deploy$/).should be_true
      shell.ran?(/pw /).should be_false
    end

    it "saute un utilisateur existant (getent)" do
      shell = FakeShell.new
      shell.stub(/getent passwd/, exit_code: 0)
      prim("user-create").apply(shell, apply_params("name: deploy"), dry_run: false, context: linux_ctx)
        .outcome.should eq Beryl::Apply::Outcome::Skipped
    end
  end

  describe "pkg-install" do
    it "installe les paquets manquants avec zypper" do
      shell = FakeShell.new
      shell.stub(/rpm -qa/, stdout: "sudo\nopenssh-server\n")
      shell.stub(/command -v zypper/, exit_code: 0)
      result = prim("pkg-install").apply(shell, apply_params("packages: [sudo, podman]"),
        dry_run: false, context: linux_ctx)
      result.message.should contain "podman"
      shell.ran?(/zypper --non-interactive install --no-recommends podman$/).should be_true
      shell.ran?(/pkg install/).should be_false
    end

    it "refuse une distribution sans zypper" do
      shell = FakeShell.new
      shell.stub(/command -v zypper/, exit_code: 1)
      expect_raises(Beryl::Apply::Primitive::PrimitiveError, /zypper/) do
        prim("pkg-install").apply(shell, apply_params("packages: [podman]"), dry_run: false, context: linux_ctx)
      end
    end
  end

  describe "service-enable" do
    it "active et démarre une unité systemd" do
      shell = FakeShell.new
      shell.stub(/systemctl is-enabled/, stdout: "disabled\n", exit_code: 1)
      shell.stub(/systemctl is-active/, exit_code: 3)
      result = prim("service-enable").apply(shell, apply_params("name: podman"), dry_run: false, context: linux_ctx)
      result.outcome.should eq Beryl::Apply::Outcome::Applied
      shell.ran?(/^systemctl enable podman$/).should be_true
      shell.ran?(/^systemctl start podman$/).should be_true
      shell.ran?(/sysrc/).should be_false
    end

    it "saute une unité déjà activée et démarrée" do
      shell = FakeShell.new
      shell.stub(/systemctl is-enabled/, stdout: "enabled\n")
      shell.stub(/systemctl is-active/, exit_code: 0)
      prim("service-enable").apply(shell, apply_params("name: sshd"), dry_run: false, context: linux_ctx)
        .outcome.should eq Beryl::Apply::Outcome::Skipped
    end
  end

  it "recharge un service avec systemctl" do
    shell = FakeShell.new
    shell.stub(/systemctl is-active/, exit_code: 0)
    prim("service-reload").apply(shell, apply_params("name: sshd"), dry_run: false, context: linux_ctx)
    shell.ran?(/^systemctl reload sshd$/).should be_true
  end

  it "compare l'empreinte et les droits avec les outils GNU (file-write)" do
    shell = FakeShell.new
    shell.stub(/sha256sum/, stdout: "")
    prim("file-write").apply(shell, apply_params("{path: /etc/x, content: abc, mode: '0600', owner: 'root:root'}"),
      dry_run: false, context: linux_ctx)
    shell.ran?(/sha256sum/).should be_true
    shell.ran?(/sha256 -q|stat -f/).should be_false
    shell.writes.map(&.path).should eq ["/etc/x"]
  end

  describe "sshd-config-set" do
    it "écrit 00-beryl.conf (avant les drop-ins SUSE) et recharge par systemctl" do
      shell = FakeShell.new
      shell.stub(/grep -qE .*Include/, exit_code: 0)
      result = prim("sshd-config-set").apply(shell, apply_params("{key: PasswordAuthentication, value: 'no'}"),
        dry_run: false, context: linux_ctx)
      result.outcome.should eq Beryl::Apply::Outcome::Applied
      shell.writes.map(&.path).should eq ["/etc/ssh/sshd_config.d/00-beryl.conf"]
      shell.writes.first.content.should contain "PasswordAuthentication no"
      shell.ran?(/^systemctl reload sshd$/).should be_true
      shell.ran?(/service sshd reload/).should be_false
    end

    it "remet l'ancien fichier si sshd -t refuse la valeur, sans recharger" do
      shell = FakeShell.new
      shell.stub(/grep -qE .*Include/, exit_code: 0)
      shell.stub(/^cat .*00-beryl.conf/, stdout: "# ancien\nPermitRootLogin no\n")
      shell.stub(/^sshd -t$/, exit_code: 255, stderr: "Bad key exchange algorithm\n")
      result = prim("sshd-config-set").apply(shell, apply_params("{key: KexAlgorithms, value: inconnu}"),
        dry_run: false, context: linux_ctx)
      result.outcome.should eq Beryl::Apply::Outcome::Failed
      result.message.should contain "remis en l'état"
      shell.writes.last.content.should eq "# ancien\nPermitRootLogin no\n"
      shell.ran?(/reload/).should be_false
    end

    it "garde beryl.conf sous FreeBSD" do
      Beryl::Apply::SshdConfigSet.path(Beryl::Apply::FREEBSD).should eq "/etc/ssh/sshd_config.d/beryl.conf"
    end
  end

  describe "recettes : systems" do
    it "vaut FreeBSD seul par défaut et lit une liste ou un scalaire" do
      dir = File.tempname("beryl-recipes")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.recipe.yml"), "steps: []\n")
      File.write(File.join(dir, "b.recipe.yml"), "systems: linux\nsteps: []\n")
      File.write(File.join(dir, "c.recipe.yml"), "systems: [freebsd, linux]\nsteps: []\n")
      File.write(File.join(dir, "d.recipe.yml"), "systems: [windows]\nsteps: []\n")
      Beryl::Apply::Recipe.load(File.join(dir, "a.recipe.yml")).systems.should eq [Beryl::Apply::FREEBSD]
      Beryl::Apply::Recipe.load(File.join(dir, "b.recipe.yml")).systems.should eq [Beryl::Apply::LINUX]
      Beryl::Apply::Recipe.load(File.join(dir, "c.recipe.yml")).systems.should eq [Beryl::Apply::FREEBSD, Beryl::Apply::LINUX]
      expect_raises(Beryl::Apply::Recipe::InvalidRecipe, /systems/) do
        Beryl::Apply::Recipe.load(File.join(dir, "d.recipe.yml"))
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
