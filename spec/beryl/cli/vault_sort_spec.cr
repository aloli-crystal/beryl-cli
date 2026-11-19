require "../../spec_helper"
require "../../../src/beryl/cli/vault_sort"

private alias VS = Beryl::CLI::VaultSort

describe Beryl::CLI::VaultSort do
  it "trie sections et variables, garde préambule et commentaires à leur place" do
    src = <<-TOML
      # Coffre initech — préambule.

      # section ovh
      [ovh]
      # clé d'application
      OVH_APPLICATION_KEY = "abc"
      # le consumer
      OVH_CONSUMER_KEY = "def"
      ENDPOINT = "ovh-eu"

      [mail]
      SMTP_RELAY_USER = "relais@example.net"
      # mot de passe OVH
      SMTP_RELAY_PASSWORD = "x"
      # fin de mail
      TOML
    VS.sort(src).should eq(<<-TOML + "\n")
      # Coffre initech — préambule.

      [mail]
      # mot de passe OVH
      SMTP_RELAY_PASSWORD = "x"
      SMTP_RELAY_USER = "relais@example.net"
      # fin de mail

      # section ovh
      [ovh]
      ENDPOINT = "ovh-eu"
      # clé d'application
      OVH_APPLICATION_KEY = "abc"
      # le consumer
      OVH_CONSUMER_KEY = "def"
      TOML
  end

  it "déplace une valeur multi-ligne d'un bloc" do
    src = "[builder]\nZ = \"z\"\nKEY = '''\n-----BEGIN-----\nAAA\n-----END-----\n'''\nA = \"a\"\n"
    VS.sort(src).should eq("[builder]\nA = \"a\"\nKEY = '''\n-----BEGIN-----\nAAA\n-----END-----\n'''\nZ = \"z\"\n")
  end

  it "idempotent" do
    src = "[b]\nY = \"1\"\nX = \"2\"\n\n[a]\nK = \"3\"\n"
    once = VS.sort(src)
    VS.sort(once).should eq(once)
  end

  it "TOML invalide : texte rendu intact" do
    src = "[a]\nK = '''\nnon fermé\n"
    VS.sort(src).should eq(src)
  end

  it "commentaire seul après un en-tête (variable commentée) : reste dans la section" do
    src = "[ovh]\n# OVH_APPLICATION_KEY = \"\"\n\n[mail]\nU = \"u\"\n"
    VS.sort(src).should eq("[mail]\nU = \"u\"\n\n[ovh]\n# OVH_APPLICATION_KEY = \"\"\n")
  end
end
