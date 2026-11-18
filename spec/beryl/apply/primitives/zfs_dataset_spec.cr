require "../../../spec_helper"
require "../../../support/fake_shell"

private def y(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = YAML::Any.new(v) }
  res
end

describe Beryl::Apply::ZfsDataset do
  it "est enregistrée sous `zfs-dataset`" do
    Beryl::Apply::Primitive["zfs-dataset"]?.should_not be_nil
  end

  describe ".build_props" do
    it "applique les défauts lz4/1M et l'ordre déterministe (quota d'abord)" do
      props = Beryl::Apply::ZfsDataset.build_props(y({"quota" => "2T"}))
      props.should eq([{"quota", "2T"}, {"compression", "lz4"}, {"recordsize", "1M"}])
    end

    it "laisse surcharger compression/recordsize et ajoute mountpoint" do
      props = Beryl::Apply::ZfsDataset.build_props(
        y({"quota" => "500G", "recordsize" => "16k", "mountpoint" => "/tank/clients/x"}))
      props.should eq([
        {"quota", "500G"}, {"mountpoint", "/tank/clients/x"},
        {"compression", "lz4"}, {"recordsize", "16k"},
      ])
    end

    it "sans quota : juste les défauts" do
      Beryl::Apply::ZfsDataset.build_props(y({} of String => String))
        .should eq([{"compression", "lz4"}, {"recordsize", "1M"}])
    end
  end

  describe ".create_cmd" do
    it "génère `zfs create -o k=v … <dataset>`" do
      cmd = Beryl::Apply::ZfsDataset.create_cmd(
        "tank/clients/acme", [{"quota", "2T"}, {"compression", "lz4"}])
      cmd.should eq("zfs create -o quota=2T -o compression=lz4 tank/clients/acme")
    end
  end

  describe "essai à blanc" do
    params = y({"pool" => "zdata", "name" => "partiduo", "quota" => "8T", "mountpoint" => "/data/clients/partiduo"})
    ctx = Beryl::Apply::Context.new

    it "dataset présent et conforme : skip, rien d'écrit" do
      sh = FakeShell.new
      sh.stub(/zfs list -H -o name/, stdout: "zdata/clients/partiduo\n")
      sh.stub(/zfs get -H -o value quota/, stdout: "8T\n")
      sh.stub(/zfs get -H -o value mountpoint/, stdout: "/data/clients/partiduo\n")
      sh.stub(/zfs get -H -o value compression/, stdout: "lz4\n")
      sh.stub(/zfs get -H -o value recordsize/, stdout: "1M\n")
      r = Beryl::Apply::ZfsDataset.new.apply(sh, params, true, ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      sh.ran?(/zfs (create|set)/).should be_false
    end

    it "dataset présent, propriété divergente : annonce le seul écart" do
      sh = FakeShell.new
      sh.stub(/zfs list -H -o name/, stdout: "zdata/clients/partiduo\n")
      sh.stub(/zfs get -H -o value quota/, stdout: "4T\n")
      sh.stub(/zfs get -H -o value mountpoint/, stdout: "/data/clients/partiduo\n")
      sh.stub(/zfs get -H -o value compression/, stdout: "lz4\n")
      sh.stub(/zfs get -H -o value recordsize/, stdout: "1M\n")
      r = Beryl::Apply::ZfsDataset.new.apply(sh, params, true, ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("quota=8T")
      r.message.should_not contain("recordsize")
      sh.ran?(/zfs (create|set)/).should be_false
    end

    it "dataset absent : annonce la création" do
      sh = FakeShell.new
      sh.stub(/zfs list -H -o name/, exit_code: 1)
      r = Beryl::Apply::ZfsDataset.new.apply(sh, params, true, ctx)
      r.outcome.should eq(Beryl::Apply::Outcome::Applied)
      r.message.should contain("zfs create")
      sh.ran?(/zfs (create|set)/).should be_false
    end
  end

  describe ".valid_name? / .valid_pool?" do
    it "valide noms de client et de pool, refuse l'injection" do
      Beryl::Apply::ZfsDataset.valid_name?("acme").should be_true
      Beryl::Apply::ZfsDataset.valid_name?("../x").should be_false
      Beryl::Apply::ZfsDataset.valid_name?("a/b").should be_false
      Beryl::Apply::ZfsDataset.valid_pool?("tank").should be_true
      Beryl::Apply::ZfsDataset.valid_pool?("zroot").should be_true
      Beryl::Apply::ZfsDataset.valid_pool?("tank/x").should be_false # pool racine, pas de /
    end
  end
end
