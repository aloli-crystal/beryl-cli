require "../../spec_helper"
require "../../../src/beryl/cli/bootstrap"

describe Beryl::CLI::Bootstrap do
  describe ".ashift_for" do
    it "log2 de la taille de bloc, jamais sous le plancher de 12 (4 K)" do
      Beryl::CLI::Bootstrap.ashift_for(512).should eq(12)
      Beryl::CLI::Bootstrap.ashift_for(4096).should eq(12)
      Beryl::CLI::Bootstrap.ashift_for(8192).should eq(13)
      Beryl::CLI::Bootstrap.ashift_for(0).should eq(Beryl::CLI::Bootstrap::MIN_ASHIFT)
    end
  end

  describe ".drop_installed_false" do
    it "retire la ligne (avec son commentaire de fin) et rien d'autre" do
      input = "# tika.initech.example\n\ninstalled: false # retiré par `beryl bootstrap`\nprovider: ovh\nfreebsd:\n  hostname: tika\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input)
        .should eq("# tika.initech.example\n\nprovider: ovh\nfreebsd:\n  hostname: tika\n")
    end

    it "laisse le fichier intact sans la clé, ou avec `installed: true`" do
      input = "provider: ovh\ninstalled: true\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input).should eq(input)
    end

    it "ne touche pas une clé `installed` imbriquée" do
      input = "jail:\n  installed: false\n"
      Beryl::CLI::Bootstrap.drop_installed_false(input).should eq(input)
    end
  end
end

describe "Beryl::CLI::HostKeys.names" do
  it "vise le FQDN, le nom hébergeur, l'IP publique et les IP vRack" do
    fixture = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "ssh-host-override"))
    host = Beryl::Config::Root.load(fixture).resolve("rescuehidden")
    Beryl::CLI::HostKeys.names(host).should eq([
      "rescuehidden.initech.example", "192.168.42.50", "ns9999.ip-1-2-3.eu", "1.2.3.4", "192.168.42.150",
    ])
  end

  describe ".pair_by_model" do
    disk = ->(name : String, model : String) {
      Beryl::CLI::Scan::Disk.new(name: name, size_bytes: 960_197_124_096_i64, model: model, is_ssd: true, transport: "nvme")
    }
    known = {
      "/dev/nvme0n1" => disk.call("nvme0n1", "MICRON"),
      "/dev/nvme1n1" => disk.call("nvme1n1", "MICRON"),
      "/dev/nvme2n1" => disk.call("nvme2n1", "SAMSUNG"),
      "/dev/nvme3n1" => disk.call("nvme3n1", "SAMSUNG"),
    }

    it "forme des miroirs de deux modèles, quel que soit l'ordre (trié) de la fiche" do
      Beryl::CLI::Bootstrap.pair_by_model(%w[/dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1], known)
        .should eq(%w[/dev/nvme0n1 /dev/nvme2n1 /dev/nvme1n1 /dev/nvme3n1])
    end

    it "disque déclaré absent du rescue : ordre déclaré gardé" do
      paths = %w[/dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/sdz]
      Beryl::CLI::Bootstrap.pair_by_model(paths, known).should eq(paths)
    end
  end
end
