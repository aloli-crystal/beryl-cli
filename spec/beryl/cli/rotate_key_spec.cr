require "../../spec_helper"
require "../../../src/beryl/cli/rotate_key"

describe Beryl::CLI::RotateKey do
  describe ".find_pairs" do
    it "trouve une paire au niveau racine ssh_keys (user nil = tous)" do
      raw = YAML.parse("ssh_keys:\n  - [philippe.popi.fr.pub, pne.popi.fr.pub]\n").as_h
      pairs = Beryl::CLI::RotateKey.find_pairs(raw)
      pairs.size.should eq(1)
      pairs[0].user.should be_nil
      pairs[0].active.should eq("philippe.popi.fr.pub")
      pairs[0].suivante.should eq("pne.popi.fr.pub")
    end

    it "ignore une clé simple (string), ne retient que les paires" do
      raw = YAML.parse("ssh_keys:\n  - cle-simple.pub\n  - [a.pub, b.pub]\n").as_h
      pairs = Beryl::CLI::RotateKey.find_pairs(raw)
      pairs.size.should eq(1)
      pairs[0].active.should eq("a.pub")
      pairs[0].suivante.should eq("b.pub")
    end

    it "trouve une paire au niveau d'un user (user nommé)" do
      raw = YAML.parse("freebsd:\n  users:\n    - name: deploy\n      ssh_keys:\n        - [old.pub, new.pub]\n").as_h
      pairs = Beryl::CLI::RotateKey.find_pairs(raw)
      pairs.size.should eq(1)
      pairs[0].user.should eq("deploy")
      pairs[0].active.should eq("old.pub")
      pairs[0].suivante.should eq("new.pub")
    end
  end

  describe ".swap_pair_in_file" do
    it "remplace [active, suivante] par suivante en gardant le reste (commentaires)" do
      tmp = File.tempfile("rotate", ".yml")
      File.write(tmp.path, "# Mon domaine\nssh_keys:\n  - [philippe.popi.fr.pub, pne.popi.fr.pub]   # rotation\nfreebsd:\n  timezone: Europe/Paris\n")
      pair = Beryl::CLI::RotateKey::Pair.new(nil, "philippe.popi.fr.pub", "pne.popi.fr.pub")
      Beryl::CLI::RotateKey.swap_pair_in_file(tmp.path, pair)
      result = File.read(tmp.path)
      result.should contain("- pne.popi.fr.pub")
      result.should_not contain("[philippe.popi.fr.pub")
      result.should contain("# Mon domaine")          # commentaire préservé
      result.should contain("timezone: Europe/Paris") # reste préservé
      tmp.delete
    end
  end
end
