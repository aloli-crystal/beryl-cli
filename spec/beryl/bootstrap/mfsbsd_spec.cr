require "../../spec_helper"

describe Beryl::Bootstrap::MfsBSD do
  describe ".detect_disk_cmd" do
    it "renvoie une commande shell listant les disques" do
      cmd = Beryl::Bootstrap::MfsBSD.detect_disk_cmd
      cmd.should contain("lsblk")
      cmd.should contain("disk")
    end
  end

  describe "#initialize" do
    it "accepte les paramètres par défaut et conserve le disque cible" do
      conn = SSH::Connection.new(host: "rescue.example.com")
      bootstrap = Beryl::Bootstrap::MfsBSD.new(
        rescue_conn: conn,
        target_disk: "/dev/sda",
      )
      bootstrap.target_disk.should eq("/dev/sda")
      bootstrap.image_url.should eq(Beryl::Bootstrap::MfsBSD::DEFAULT_IMAGE_URL)
    end

    it "permet d'overrider l'URL de l'image mfsBSD" do
      conn = SSH::Connection.new(host: "rescue.example.com")
      custom_url = "https://example.com/mfsbsd.img"
      bootstrap = Beryl::Bootstrap::MfsBSD.new(
        rescue_conn: conn,
        target_disk: "/dev/nvme0n1",
        image_url: custom_url,
      )
      bootstrap.image_url.should eq(custom_url)
    end
  end
end
