require "../spec_helper"
require "../../src/beryl/host_key"
require "../../src/beryl/bootstrap"

describe Beryl::HostKey do
  it "génère une paire ed25519 sans rien laisser sur disque" do
    pair = Beryl::HostKey.generate("root@a.example")
    pair.private_key.should contain("BEGIN OPENSSH PRIVATE KEY")
    pair.public_key.should start_with("ssh-ed25519 ")
    pair.public_key.should end_with("root@a.example")
    Beryl::HostKey.fingerprint(pair.public_key).should start_with("SHA256:")
  end

  it "known_hosts : remplace l'entrée du serveur, trie, sans commentaire de clé" do
    before = "# vieil en-tête\nz.example ssh-ed25519 ZZZ\nb.example ssh-ed25519 OLD\n"
    after = Beryl::HostKey.with_entry(before, "b.example", "ssh-ed25519 NEW root@b.example")
    after.should eq "#{Beryl::HostKey::HEADER}\nb.example ssh-ed25519 NEW\nz.example ssh-ed25519 ZZZ\n"
    Beryl::HostKey.with_entry("", "a.example", "ssh-ed25519 K c")
      .should eq "#{Beryl::HostKey::HEADER}\na.example ssh-ed25519 K\n"
  end
end

require "../../src/beryl/cli/host_keys_import"

describe Beryl::CLI::HostKeysImport do
  it "entry : clé ed25519 d'un serveur dans un known_hosts (noms multiples tolérés)" do
    content = "# en-tête\na.example ssh-ed25519 AAA\nb.example,10.0.0.2 ssh-ed25519 BBB\nb.example ssh-rsa RRR\n"
    Beryl::CLI::HostKeysImport.entry(content, "a.example").should eq "AAA"
    Beryl::CLI::HostKeysImport.entry(content, "b.example").should eq "BBB"
    Beryl::CLI::HostKeysImport.entry(content, "c.example").should be_nil
  end
end
