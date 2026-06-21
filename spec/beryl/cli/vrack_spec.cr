require "../../spec_helper"
require "../../../src/beryl/cli/vrack"

describe Beryl::CLI::Vrack do
  describe ".upsert_vrack_field" do
    it "met à jour une clé existante du bloc vrack:" do
      input = "provider: ovh\nvrack:\n  ip: 192.168.42.31\n  proxy_jump: old@bast.net\nfreebsd:\n  hostname: x\n"
      out = Beryl::CLI::Vrack.upsert_vrack_field(input, "proxy_jump", "admin@zsbg.popi.net")
      out.should eq("provider: ovh\nvrack:\n  ip: 192.168.42.31\n  proxy_jump: admin@zsbg.popi.net\nfreebsd:\n  hostname: x\n")
    end

    it "ajoute une clé en fin de bloc vrack: existant" do
      input = "vrack:\n  ip: 192.168.42.31\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.upsert_vrack_field(input, "proxy_jump", "admin@z.net")
      out.should eq("vrack:\n  ip: 192.168.42.31\n  proxy_jump: admin@z.net\napply_recipes:\n  - clamav\n")
    end

    it "crée le bloc vrack: avant apply_recipes: s'il est absent" do
      input = "provider: ovh\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.upsert_vrack_field(input, "bastion", "true")
      out.should eq("provider: ovh\nvrack:\n  bastion: true\napply_recipes:\n  - clamav\n")
    end

    it "crée le bloc vrack: en fin si pas d'apply_recipes:" do
      input = "provider: ovh\n"
      out = Beryl::CLI::Vrack.upsert_vrack_field(input, "bastion", "false")
      out.should eq("provider: ovh\nvrack:\n  bastion: false\n")
    end
  end

  describe ".remove_vrack_field" do
    it "retire une clé du bloc vrack:" do
      input = "vrack:\n  ip: 192.168.42.31\n  proxy_jump: admin@z.net\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.remove_vrack_field(input, "proxy_jump")
      out.should eq("vrack:\n  ip: 192.168.42.31\napply_recipes:\n  - clamav\n")
    end

    it "retire le bloc vrack: entier si la dernière clé part" do
      input = "provider: ovh\nvrack:\n  proxy_jump: admin@z.net\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Vrack.remove_vrack_field(input, "proxy_jump")
      out.should eq("provider: ovh\napply_recipes:\n  - clamav\n")
    end

    it "no-op si la clé est absente" do
      input = "vrack:\n  ip: 192.168.42.31\n"
      Beryl::CLI::Vrack.remove_vrack_field(input, "proxy_jump").should eq(input)
    end
  end

  describe ".derive_proxy_jump" do
    it "complète un nom court de bastion avec le domaine" do
      Beryl::CLI::Vrack.derive_proxy_jump("admin", "zsbg", "popi.net").should eq("admin@zsbg.popi.net")
    end

    it "respecte un bastion déjà en FQDN" do
      Beryl::CLI::Vrack.derive_proxy_jump("deploy", "bast.example.net", "popi.net").should eq("deploy@bast.example.net")
    end
  end

  describe ".derive_subnet" do
    it "dérive le /24 d'une IP vRack" do
      Beryl::CLI::Vrack.derive_subnet("192.168.42.31").should eq("192.168.42.0/24")
    end

    it "renvoie l'entrée telle quelle si ce n'est pas une IPv4 à 4 octets" do
      Beryl::CLI::Vrack.derive_subnet("pas-une-ip").should eq("pas-une-ip")
    end
  end
end
