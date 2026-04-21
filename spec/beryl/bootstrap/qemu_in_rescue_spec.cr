require "../../spec_helper"

private def user_admin(keys = ["ssh-ed25519 AAAA test@laptop"])
  Beryl::Bootstrap::UserSpec.new(
    name: "admin",
    primary_group: "www",
    secondary_groups: ["wheel"],
    shell: "/bin/csh",
    ssh_keys: keys,
  )
end

private def make_bootstrap(**overrides) : Beryl::Bootstrap::QemuInRescue
  defaults = {
    rescue_conn: Beryl::SSH::Connection.new(host: "srv.example.com"),
    disks:       ["/dev/sda"],
    hostname:    "srv.example.com",
    users:       [user_admin],
  }
  Beryl::Bootstrap::QemuInRescue.new(**defaults.merge(overrides))
end

describe Beryl::Bootstrap::UserSpec do
  it "valide que les clés SSH ne sont pas vides" do
    u = Beryl::Bootstrap::UserSpec.new(
      name: "admin", primary_group: "www", secondary_groups: %w[wheel],
      shell: "/bin/csh", ssh_keys: [] of String,
    )
    expect_raises(ArgumentError, /ssh_keys vide/) { u.validate! }
  end

  it "rend un TSV compact name|g|G,G|shell|key1,key2" do
    u = Beryl::Bootstrap::UserSpec.new(
      name: "admin", primary_group: "www", secondary_groups: %w[wheel staff],
      shell: "/bin/csh", ssh_keys: ["ssh-ed25519 AAAA", "ssh-rsa BBBB"],
    )
    u.to_tsv.should eq("admin|www|wheel,staff|/bin/csh|ssh-ed25519 AAAA,ssh-rsa BBBB")
  end
end

describe Beryl::Bootstrap::QemuInRescue do
  describe "#initialize" do
    it "refuse disks vide" do
      expect_raises(ArgumentError, /disks/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: Beryl::SSH::Connection.new(host: "x"),
          disks: [] of String, hostname: "srv", users: [user_admin],
        )
      end
    end

    it "refuse users vide" do
      expect_raises(ArgumentError, /users/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: Beryl::SSH::Connection.new(host: "x"),
          disks: ["/dev/sda"], hostname: "srv", users: [] of Beryl::Bootstrap::UserSpec,
        )
      end
    end

    it "refuse un hostname vide" do
      expect_raises(ArgumentError, /hostname/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: Beryl::SSH::Connection.new(host: "x"),
          disks: ["/dev/sda"], hostname: "", users: [user_admin],
        )
      end
    end

    it "refuse une RAM QEMU insuffisante" do
      expect_raises(ArgumentError, /qemu_ram_mb/) do
        make_bootstrap(qemu_ram_mb: 512)
      end
    end

    it "refuse un raid inconnu" do
      expect_raises(ArgumentError, /raid invalide/) do
        make_bootstrap(raid: "raid42")
      end
    end

    it "accepte les valeurs ZFS valides (stripe/mirror/raidz*)" do
      %w[stripe mirror raidz raidz2 raidz3].each do |r|
        make_bootstrap(raid: r).raid.should eq(r)
      end
    end

    it "a des défauts raisonnables" do
      bs = make_bootstrap
      bs.freebsd_version.should eq("15.0")
      bs.timezone.should eq("Europe/Paris")
      bs.pool_name.should eq("zroot")
      bs.swap_gb.should eq(4)
      bs.abi.should eq("FreeBSD:15:amd64")
      bs.qemu_ram_mb.should eq(4096)
      bs.qemu_cpus.should eq(4)
      bs.installed_user.should eq("admin")
      bs.raid.should eq("stripe")
      bs.packages.should be_empty
      bs.sudoers.should be_empty
    end

    it "construit l'URL mfsBSD SE par défaut (ADR-012)" do
      bs = make_bootstrap
      bs.iso_url.should contain("mfsbsd-se")
      bs.iso_url.should contain("14.2")
      bs.iso_url.should_not contain("__VERSION_MFS__")
    end

    it "accepte un iso_url explicite qui court-circuite le template" do
      custom = "https://mirror.example.com/mfsbsd.img"
      bs = make_bootstrap(iso_url: custom)
      bs.iso_url.should eq(custom)
    end
  end

  describe "#render_installerconfig" do
    it "remplace tous les placeholders du template" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should_not contain("__HOSTNAME__")
      cfg.should_not contain("__ZFSBOOT_DISKS__")
      cfg.should_not contain("__ZFSBOOT_VDEV_TYPE__")
      cfg.should_not contain("__POOL_NAME__")
      cfg.should_not contain("__SWAP_GB__")
    end

    it "déclare les distributions tarballs (base.txz + kernel.txz)" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain(%(DISTRIBUTIONS="kernel.txz base.txz"))
    end

    it "pose ZFSBOOT_DISKS = vtbd1 pour un seul disque" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain(%(ZFSBOOT_DISKS="vtbd1"))
    end

    it "pose ZFSBOOT_DISKS = vtbd1 vtbd2 pour deux disques (RAID mirror/stripe)" do
      cfg = make_bootstrap(disks: ["/dev/sda", "/dev/sdb"], raid: "mirror").render_installerconfig
      cfg.should contain(%(ZFSBOOT_DISKS="vtbd1 vtbd2"))
      cfg.should contain(%(ZFSBOOT_VDEV_TYPE="mirror"))
    end

    it "est un préambule bsdinstall SEUL (pas de shebang actif → pas de chroot post-install)" do
      # Règle Aloli ADR-013 : tout le post-install passe par le driver
      # shell hors chroot pour contourner le bug Capsicum.
      cfg = make_bootstrap.render_installerconfig
      cfg.lines.any? { |l| l.strip == "#!/bin/sh" }.should be_false
      cfg.should_not contain("pw useradd")
      cfg.should_not contain("pkg install")
      cfg.should_not contain("poweroff")
    end
  end

  describe "#render_rescue_run_vm" do
    it "substitue tous les placeholders du driver shell" do
      sh = make_bootstrap.render_rescue_run_vm
      sh.should_not match(/__[A-Z_]+__/)
    end

    it "embarque le user admin en TSV" do
      sh = make_bootstrap.render_rescue_run_vm
      sh.should contain("admin|www|wheel|/bin/csh|ssh-ed25519 AAAA test@laptop")
    end

    it "embarque les packages si fournis" do
      sh = make_bootstrap(packages: ["sudo", "zsh", "postgresql16-server"]).render_rescue_run_vm
      sh.should contain("sudo zsh postgresql16-server")
    end

    it "passe la commande pkg -r /mnt install (contournement Capsicum)" do
      sh = make_bootstrap(packages: ["sudo"]).render_rescue_run_vm
      sh.should contain("pkg -r /mnt install")
    end

    it "utilise systemd-run --unit=qemu-vm pour survivre à la fermeture ssh" do
      sh = make_bootstrap.render_rescue_run_vm
      sh.should contain("systemd-run --unit=qemu-vm")
    end

    it "embarque sudoers en base64 si fournis, rien sinon" do
      sh1 = make_bootstrap(sudoers: ["%wheel ALL=(ALL) NOPASSWD:ALL"]).render_rescue_run_vm
      sh1.should_not contain(%(SUDOERS_CONTENT='')) # should have encoded content
      sh1.should match(/SUDOERS_CONTENT='[A-Za-z0-9+\/=]+'/)
      sh2 = make_bootstrap.render_rescue_run_vm
      sh2.should contain(%(SUDOERS_CONTENT=''))
    end

    it "génère un -drive QEMU par disque cible" do
      sh = make_bootstrap(disks: ["/dev/sda", "/dev/sdb", "/dev/sdc"]).render_rescue_run_vm
      sh.should contain("/dev/sda")
      sh.should contain("/dev/sdb")
      sh.should contain("/dev/sdc")
    end
  end
end
