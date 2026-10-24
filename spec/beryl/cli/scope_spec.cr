require "../../spec_helper"
require "../../../src/beryl/cli/apply"
require "../../../src/beryl/cli/info"

private SCOPE_FIXTURE = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "scope-groups"))

private def scope_root : Beryl::Config::Root
  Beryl::Config::Root.load(SCOPE_FIXTURE)
end

describe "Portées de beryl : groupe et liste" do
  describe "Beryl::CLI::Info.scoped_hosts (upgrade, os-upgrade, info, monitoring)" do
    it "un groupe désigne ses serveurs" do
      Beryl::CLI::Info.scoped_hosts(scope_root, "web").map(&.short_name).should eq(%w[rails01 rails02])
    end

    it "une liste est l'union des portées citées, sans doublon" do
      Beryl::CLI::Info.scoped_hosts(scope_root, "db01,web").map(&.short_name).sort.should eq(%w[db01 rails01 rails02])
      Beryl::CLI::Info.scoped_hosts(scope_root, "rails01,web").map(&.short_name).sort.should eq(%w[rails01 rails02])
    end
  end

  describe "Beryl::CLI::Apply.resolve_list (apply)" do
    it "groupe" do
      Beryl::CLI::Apply.resolve_list(scope_root, "web", nil, nil).map(&.short_name).should eq(%w[rails01 rails02])
    end

    it "liste de serveurs, dans l'ordre donné" do
      Beryl::CLI::Apply.resolve_list(scope_root, "rails02,db01", nil, nil).map(&.short_name).should eq(%w[rails02 db01])
    end

    it "liste mêlant groupe et serveur, sans doublon" do
      Beryl::CLI::Apply.resolve_list(scope_root, "web,rails01,db01", nil, nil).map(&.short_name).should eq(%w[rails01 rails02 db01])
    end

    it "élément inconnu : signalé (apply refuse la liste)" do
      Beryl::CLI::Apply.unknown_parts(scope_root, "db01,zgar,web", nil, nil).should eq(%w[zgar])
      Beryl::CLI::Apply.unknown_parts(scope_root, "db01,web", nil, nil).should be_empty
    end

    it "union seule : un élément inconnu n'ajoute rien" do
      Beryl::CLI::Apply.resolve_list(scope_root, "db01,inconnu", nil, nil).map(&.short_name).should eq(%w[db01])
    end
  end
end
