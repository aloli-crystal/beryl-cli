require "../../../spec_helper"

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
