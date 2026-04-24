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
  # Valeurs explicites pour les tests : en prod, ces trois champs
  # viennent de `Beryl::Bootstrap::MfsBSDRelease.latest` (détection
  # dynamique GitHub). Ici on fige pour isoler le comportement.
  defaults = {
    rescue_conn:     SSH::Connection.new(host: "srv.example.com"),
    disks:           ["/dev/sda"],
    hostname:        "srv.example.com",
    users:           [user_admin],
    freebsd_version: "14.2",
    mfsbsd_version:  "14.2",
    abi:             "FreeBSD:14:amd64",
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

describe Beryl::Bootstrap::DataPoolSpec do
  describe "#validate!" do
    it "refuse un name vide" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "", raid: 0, disks: ["/dev/sdb"], mountpoint: "/data")
      expect_raises(ArgumentError, /name vide/) { dp.validate! }
    end

    it "refuse disks vide" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "zdata", raid: 0, disks: [] of String, mountpoint: "/data")
      expect_raises(ArgumentError, /disks vide/) { dp.validate! }
    end

    it "refuse un mountpoint vide" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "zdata", raid: 0, disks: ["/dev/sdb"], mountpoint: "")
      expect_raises(ArgumentError, /mountpoint vide/) { dp.validate! }
    end

    it "délègue la validation RAID à Zpool (parité RAID 10 impaire)" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 10,
        disks: ["/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde", "/dev/sdf"],
        mountpoint: "/data",
      )
      expect_raises(Beryl::Config::Zpool::InvalidDiskCount, /PAIR/) { dp.validate! }
    end

    it "délègue la validation RAID à Zpool (min disques insuffisants)" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 5, disks: ["/dev/sdb", "/dev/sdc"], mountpoint: "/data",
      )
      expect_raises(Beryl::Config::Zpool::InvalidDiskCount, /minimum 3/) { dp.validate! }
    end
  end

  describe "#vdev_spec" do
    it "raid 0 = devices en stripe implicite" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "z", raid: 0, disks: ["/dev/sdb", "/dev/sdc"], mountpoint: "/d")
      dp.vdev_spec(["vtbd2", "vtbd3"]).should eq("vtbd2 vtbd3")
    end

    it "raid 1 = mirror" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "z", raid: 1, disks: ["/dev/sdb", "/dev/sdc"], mountpoint: "/d")
      dp.vdev_spec(["vtbd2", "vtbd3"]).should eq("mirror vtbd2 vtbd3")
    end

    it "raid 5 = raidz" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "z", raid: 5, disks: ["/dev/sdb", "/dev/sdc", "/dev/sdd"], mountpoint: "/d")
      dp.vdev_spec(["vtbd2", "vtbd3", "vtbd4"]).should eq("raidz vtbd2 vtbd3 vtbd4")
    end

    it "raid 10 = paires mirror consécutives" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "z", raid: 10,
        disks: ["/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"],
        mountpoint: "/d",
      )
      dp.vdev_spec(["vtbd2", "vtbd3", "vtbd4", "vtbd5"]).should eq("mirror vtbd2 vtbd3 mirror vtbd4 vtbd5")
    end

    it "lève si le nombre de devices ne correspond pas au nombre de disques" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(name: "z", raid: 1, disks: ["/dev/sdb", "/dev/sdc"], mountpoint: "/d")
      expect_raises(ArgumentError, /devices/) { dp.vdev_spec(["vtbd2"]) }
    end
  end
end

describe Beryl::Bootstrap::QemuInRescue do
  describe "#initialize" do
    it "refuse disks vide" do
      expect_raises(ArgumentError, /disks/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: SSH::Connection.new(host: "x"),
          disks: [] of String, hostname: "srv", users: [user_admin],
          freebsd_version: "14.2", mfsbsd_version: "14.2", abi: "FreeBSD:14:amd64",
        )
      end
    end

    it "refuse users vide" do
      expect_raises(ArgumentError, /users/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: SSH::Connection.new(host: "x"),
          disks: ["/dev/sda"], hostname: "srv", users: [] of Beryl::Bootstrap::UserSpec,
          freebsd_version: "14.2", mfsbsd_version: "14.2", abi: "FreeBSD:14:amd64",
        )
      end
    end

    it "refuse un hostname vide" do
      expect_raises(ArgumentError, /hostname/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: SSH::Connection.new(host: "x"),
          disks: ["/dev/sda"], hostname: "", users: [user_admin],
          freebsd_version: "14.2", mfsbsd_version: "14.2", abi: "FreeBSD:14:amd64",
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

    it "refuse un install_type invalide" do
      expect_raises(ArgumentError, /install_type invalide/) do
        make_bootstrap(install_type: "tar_manual")
      end
    end

    it "accepte install_type: distribution_sets (défaut)" do
      make_bootstrap.install_type.should eq("distribution_sets")
      make_bootstrap(install_type: "distribution_sets").install_type.should eq("distribution_sets")
    end

    it "lève PkgbaseNotYetImplemented pour install_type: packages" do
      expect_raises(Beryl::Bootstrap::QemuInRescue::PkgbaseNotYetImplemented, /pkgbase.*pas encore/) do
        make_bootstrap(install_type: "packages")
      end
    end

    it "a des défauts raisonnables pour les paramètres non versionnés" do
      # freebsd_version / mfsbsd_version / abi n'ont plus de défaut :
      # résolus dynamiquement en prod via MfsBSDRelease.latest, ou
      # fournis explicitement par le caller (cf. make_bootstrap).
      bs = make_bootstrap
      bs.timezone.should eq("Europe/Paris")
      bs.pool_name.should eq("zroot")
      bs.swap_gb.should eq(4)
      bs.qemu_ram_mb.should eq(4096)
      bs.qemu_cpus.should eq(4)
      bs.installed_user.should eq("admin")
      bs.raid.should eq("stripe")
      bs.packages.should be_empty
      bs.sudoers.should be_empty
    end

    it "construit l'URL mfsBSD SE par défaut (GitHub releases)" do
      bs = make_bootstrap
      bs.iso_url.should contain("mfsbsd-se")
      bs.iso_url.should contain("14.2")
      bs.iso_url.should contain("github.com/mmatuska")
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

    it "DATA_POOLS_SCRIPT vide si aucun pool data" do
      sh = make_bootstrap.render_rescue_run_vm
      sh.should contain("DATA_POOLS_SCRIPT=''")
    end

    it "DATA_POOLS_SCRIPT base64 encodé si pool data présent" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 10,
        disks: ["/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"],
        mountpoint: "/data",
      )
      sh = make_bootstrap(data_pools: [dp]).render_rescue_run_vm
      sh.should match(/DATA_POOLS_SCRIPT='[A-Za-z0-9+\/=]+'/)
    end

    it "inclut les disques data dans les -drive QEMU" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 1,
        disks: ["/dev/sdb", "/dev/sdc"],
        mountpoint: "/data",
      )
      sh = make_bootstrap(disks: ["/dev/sda"], data_pools: [dp]).render_rescue_run_vm
      sh.should contain("/dev/sda")
      sh.should contain("/dev/sdb")
      sh.should contain("/dev/sdc")
    end
  end

  describe "#data_pools_script" do
    it "vide si aucun pool data" do
      make_bootstrap.data_pools_script.should eq("")
    end

    it "mappe les vtbd après les disques du pool boot" do
      # boot = 1 disque → vtbd1, data = 2 disques → vtbd2 + vtbd3
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 1,
        disks: ["/dev/sdb", "/dev/sdc"],
        mountpoint: "/data",
      )
      script = make_bootstrap(disks: ["/dev/sda"], data_pools: [dp]).data_pools_script
      script.should contain("zpool create -f -R /mnt -m /data zdata mirror vtbd2 vtbd3")
    end

    it "enchaîne plusieurs pools data avec des vtbd contigus" do
      dp1 = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 1,
        disks: ["/dev/sdc", "/dev/sdd"],
        mountpoint: "/data",
      )
      dp2 = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zbackup", raid: 0,
        disks: ["/dev/sde"],
        mountpoint: "/backup",
      )
      # boot = sda+sdb → vtbd1+vtbd2, dp1 → vtbd3+vtbd4, dp2 → vtbd5
      script = make_bootstrap(
        disks: ["/dev/sda", "/dev/sdb"],
        raid: "mirror",
        data_pools: [dp1, dp2],
      ).data_pools_script
      script.should contain("zpool create -f -R /mnt -m /data zdata mirror vtbd3 vtbd4")
      script.should contain("zpool create -f -R /mnt -m /backup zbackup vtbd5")
    end

    it "gère RAID 10 avec paires mirror contiguës" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 10,
        disks: ["/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"],
        mountpoint: "/data",
      )
      script = make_bootstrap(disks: ["/dev/sda"], data_pools: [dp]).data_pools_script
      script.should contain("zpool create -f -R /mnt -m /data zdata mirror vtbd2 vtbd3 mirror vtbd4 vtbd5")
    end

    # Bug quantas (24 avril 2026) : sans `set cachefile`, le
    # `zpool export -a` final retirait le pool du cache du zroot et
    # le pool était orphelin au reboot bare-metal (présent sur disque
    # mais invisible à `zpool list`, récupérable uniquement via
    # `sudo zpool import`).
    it "ajoute `zpool set cachefile=/mnt/boot/zfs/zpool.cache` après chaque create pour survivre au reboot" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 1,
        disks: ["/dev/sdb", "/dev/sdc"],
        mountpoint: "/data",
      )
      script = make_bootstrap(disks: ["/dev/sda"], data_pools: [dp]).data_pools_script
      script.should contain("zpool set cachefile=/mnt/boot/zfs/zpool.cache zdata")
    end

    it "ajoute le set cachefile pour CHAQUE pool data quand il y en a plusieurs" do
      dp1 = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 1,
        disks: ["/dev/sdc", "/dev/sdd"], mountpoint: "/data",
      )
      dp2 = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zbackup", raid: 0,
        disks: ["/dev/sde"], mountpoint: "/backup",
      )
      script = make_bootstrap(
        disks: ["/dev/sda", "/dev/sdb"],
        raid: "mirror",
        data_pools: [dp1, dp2],
      ).data_pools_script
      script.should contain("zpool set cachefile=/mnt/boot/zfs/zpool.cache zdata")
      script.should contain("zpool set cachefile=/mnt/boot/zfs/zpool.cache zbackup")
    end
  end

  describe "#initialize avec data_pools" do
    it "refuse un disque déclaré à la fois en boot et en data" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 0, disks: ["/dev/sda"], mountpoint: "/data",
      )
      expect_raises(ArgumentError, /plusieurs fois/) do
        make_bootstrap(disks: ["/dev/sda"], data_pools: [dp])
      end
    end

    it "refuse le même disque dans deux pools data" do
      dp1 = Beryl::Bootstrap::DataPoolSpec.new(
        name: "z1", raid: 0, disks: ["/dev/sdb"], mountpoint: "/d1",
      )
      dp2 = Beryl::Bootstrap::DataPoolSpec.new(
        name: "z2", raid: 0, disks: ["/dev/sdb"], mountpoint: "/d2",
      )
      expect_raises(ArgumentError, /plusieurs fois/) do
        make_bootstrap(disks: ["/dev/sda"], data_pools: [dp1, dp2])
      end
    end

    it "accepte des pools data disjoints" do
      dp = Beryl::Bootstrap::DataPoolSpec.new(
        name: "zdata", raid: 10,
        disks: ["/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"],
        mountpoint: "/data",
      )
      bs = make_bootstrap(disks: ["/dev/sda"], data_pools: [dp])
      bs.data_pools.size.should eq(1)
      bs.all_qemu_disks.should eq(["/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"])
    end
  end
end
