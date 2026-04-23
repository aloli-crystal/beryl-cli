require "../../spec_helper"

private def make_installer(**overrides) : Beryl::Bootstrap::Installer
  defaults = {
    mfsbsd_conn:     SSH::Connection.new(host: "srv.example.com"),
    target_disk:     "/dev/ada0",
    hostname:        "srv.example.com",
    authorized_keys: ["ssh-ed25519 AAAAC3... me@laptop"],
  }
  Beryl::Bootstrap::Installer.new(**defaults.merge(overrides))
end

describe Beryl::Bootstrap::Installer do
  describe "#initialize" do
    it "refuse une liste de clés SSH vide (sinon root serait injoignable)" do
      expect_raises(ArgumentError, /authorized_keys/) do
        Beryl::Bootstrap::Installer.new(
          mfsbsd_conn: SSH::Connection.new(host: "x"),
          target_disk: "/dev/ada0",
          hostname: "srv",
          authorized_keys: [] of String,
        )
      end
    end

    it "refuse un hostname vide" do
      expect_raises(ArgumentError, /hostname/) do
        Beryl::Bootstrap::Installer.new(
          mfsbsd_conn: SSH::Connection.new(host: "x"),
          target_disk: "/dev/ada0",
          hostname: "",
          authorized_keys: ["ssh-ed25519 AAA me@x"],
        )
      end
    end

    it "a des défauts raisonnables pour pool, swap, timezone" do
      installer = make_installer
      installer.pool_name.should eq("zroot")
      installer.swap_gb.should eq(4)
      installer.timezone.should eq("Europe/Paris")
      # `abi` garde un défaut ici (Installer est la voie legacy mfsBSD
      # pré-ADR-011, plus sur le chemin principal) ; la détection
      # dynamique n'opère que côté `QemuInRescue` / CLI bootstrap.
      installer.abi.should eq("FreeBSD:14:amd64")
    end
  end

  describe "#render_script" do
    it "remplace tous les placeholders du template" do
      script = make_installer.render_script
      script.should_not contain("__TARGET_DISK__")
      script.should_not contain("__POOL_NAME__")
      script.should_not contain("__HOSTNAME__")
      script.should_not contain("__ABI__")
      script.should_not contain("__SWAP_GB__")
      script.should_not contain("__TIMEZONE__")
      script.should_not contain("__AUTHORIZED_KEYS_B64__")
    end

    it "injecte les valeurs passées au constructeur" do
      script = make_installer(
        target_disk: "/dev/nvme0n1",
        hostname: "web99.aloli.fr",
        pool_name: "mypool",
        swap_gb: 8,
        timezone: "UTC",
      ).render_script

      script.should contain("/dev/nvme0n1")
      script.should contain("web99.aloli.fr")
      script.should contain("mypool")
      script.should contain(%(SWAP_GB="8"))
      script.should contain("UTC")
    end

    it "commence par le shebang sh et définit des variables" do
      script = make_installer.render_script
      script.should start_with("#!/bin/sh")
      script.should contain("DISK=")
      script.should contain("POOL=")
    end
  end

  describe "#authorized_keys_base64" do
    it "produit du base64 décodable en les clés originales" do
      keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAA me@laptop",
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAA autre-clé",
      ]
      installer = make_installer(authorized_keys: keys)

      encoded = installer.authorized_keys_base64
      decoded = Base64.decode_string(encoded)
      decoded.should contain(keys[0])
      decoded.should contain(keys[1])
    end
  end
end
