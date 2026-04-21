require "../../spec_helper"

private def make_bootstrap(**overrides) : Beryl::Bootstrap::QemuInRescue
  defaults = {
    rescue_conn:     Beryl::SSH::Connection.new(host: "srv.example.com"),
    target_disk:     "/dev/sda",
    hostname:        "srv.example.com",
    authorized_keys: ["ssh-ed25519 AAAAC3... me@laptop"],
  }
  Beryl::Bootstrap::QemuInRescue.new(**defaults.merge(overrides))
end

describe Beryl::Bootstrap::QemuInRescue do
  describe "#initialize" do
    it "refuse une liste de clés SSH vide" do
      expect_raises(ArgumentError, /authorized_keys/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: Beryl::SSH::Connection.new(host: "x"),
          target_disk: "/dev/sda",
          hostname: "srv",
          authorized_keys: [] of String,
        )
      end
    end

    it "refuse un hostname vide" do
      expect_raises(ArgumentError, /hostname/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: Beryl::SSH::Connection.new(host: "x"),
          target_disk: "/dev/sda",
          hostname: "",
          authorized_keys: ["ssh-ed25519 AAA me@x"],
        )
      end
    end

    it "refuse un target_disk vide" do
      expect_raises(ArgumentError, /target_disk/) do
        Beryl::Bootstrap::QemuInRescue.new(
          rescue_conn: Beryl::SSH::Connection.new(host: "x"),
          target_disk: "",
          hostname: "srv",
          authorized_keys: ["ssh-ed25519 AAA me@x"],
        )
      end
    end

    it "refuse une RAM QEMU insuffisante" do
      expect_raises(ArgumentError, /qemu_ram_mb/) do
        make_bootstrap(qemu_ram_mb: 512)
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
    end

    it "construit l'URL mfsBSD SE par défaut (ADR-012)" do
      bs = make_bootstrap
      bs.iso_url.should contain("mfsbsd-se")
      bs.iso_url.should contain("14.2")
      bs.iso_url.should_not contain("__VERSION_MFS__")
    end

    it "paramètre l'URL mfsBSD selon la version passée" do
      bs = make_bootstrap(mfsbsd_version: "14.1")
      bs.iso_url.should contain("14.1")
    end

    it "accepte un iso_url explicite qui court-circuite le template (rétrocompat CLI)" do
      custom = "https://mirror.example.com/mfsbsd.img"
      bs = make_bootstrap(iso_url: custom)
      bs.iso_url.should eq(custom)
    end
  end

  describe "#render_installerconfig" do
    it "remplace tous les placeholders du template" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should_not contain("__HOSTNAME__")
      cfg.should_not contain("__TIMEZONE__")
      cfg.should_not contain("__ABI__")
      cfg.should_not contain("__POOL_NAME__")
      cfg.should_not contain("__SWAP_GB__")
      cfg.should_not contain("__AUTHORIZED_KEYS_B64__")
    end

    it "injecte les valeurs passées au constructeur" do
      cfg = make_bootstrap(
        hostname: "web99.aloli.fr",
        pool_name: "mypool",
        swap_gb: 8,
        timezone: "UTC",
      ).render_installerconfig

      cfg.should contain("web99.aloli.fr")
      cfg.should contain("mypool")
      cfg.should contain("8g")
      cfg.should contain("UTC")
    end

    it "déclare les distributions pkgbase (kernel.txz base.txz)" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain("DISTRIBUTIONS=\"kernel.txz base.txz\"")
    end

    it "pose ZFSBOOT_DISKS à vtbd1 (point de vue VM QEMU)" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain("ZFSBOOT_DISKS=\"vtbd1\"")
    end

    it "utilise ifconfig_DEFAULT pour survivre au changement VM → bare metal" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain("ifconfig_DEFAULT=\"DHCP\"")
    end

    it "utilise des labels GPT dans fstab (indépendants des noms de devices)" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain("/dev/gpt/efiboot0")
      cfg.should contain("/dev/gpt/swap0")
    end

    it "crée le user admin (wheel, csh) — base FreeBSD uniquement, deploy pour plus tard" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain("pw useradd admin")
      cfg.should contain("-G wheel")
      cfg.should contain("-s /bin/csh")
    end

    it "pose la clé SSH pour admin et root" do
      cfg = make_bootstrap.render_installerconfig
      cfg.should contain("/home/admin/.ssh")
      cfg.should contain("/root/.ssh")
    end

    it "termine par poweroff pour que QEMU sorte via -no-reboot" do
      cfg = make_bootstrap.render_installerconfig
      cfg.strip.should end_with("poweroff")
    end

    it "contient un seul shebang (séparateur pre/post-install, pas en tête de fichier)" do
      # bsdinstall utilise la PREMIÈRE ligne `#!` comme séparateur. Un
      # shebang en tête ferait interpréter tout le préambule comme
      # post-install → ZFSBOOT_POOL_NAME vide → boucle « Pool name cannot
      # be empty » observée sur loulou le 21 avril 2026.
      cfg = make_bootstrap.render_installerconfig
      cfg.scan(/^#!\/bin\/sh$/m).size.should eq(1)
      cfg.lines.first.should_not start_with("#!")
    end
  end

  describe "#authorized_keys_base64" do
    it "produit du base64 décodable en les clés originales" do
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAA me@laptop",
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAA autre-clé",
      ]
      bs = make_bootstrap(authorized_keys: keys)

      decoded = Base64.decode_string(bs.authorized_keys_base64)
      decoded.should contain(keys[0])
      decoded.should contain(keys[1])
    end
  end

  describe "#qemu_command" do
    it "attache l'image mfsBSD + OVMF UEFI (obligatoire pour un install UEFI-bootable)" do
      cmd = make_bootstrap.qemu_command
      cmd.should contain("mfsbsd-se.img")
      cmd.should contain("if=virtio")
      cmd.should contain("OVMF_CODE_4M.fd")
      cmd.should contain("readonly=on")
      cmd.should contain("vars.fd")
    end

    it "passe le disque cible en virtio passthrough" do
      cmd = make_bootstrap(target_disk: "/dev/nvme0n1").qemu_command
      cmd.should contain("/dev/nvme0n1")
    end

    it "inclut -no-reboot et -enable-kvm" do
      cmd = make_bootstrap.qemu_command
      cmd.should contain("-no-reboot")
      cmd.should contain("-enable-kvm")
    end

    it "forwarde le 22 de la VM sur le port 2223 local (scp/ssh depuis le rescue)" do
      cmd = make_bootstrap.qemu_command
      cmd.should contain("hostfwd=tcp::2223-:22")
    end

    it "dirige la sortie série vers un fichier du working dir" do
      cmd = make_bootstrap.qemu_command
      cmd.should contain("qemu-serial.log")
    end
  end
end
