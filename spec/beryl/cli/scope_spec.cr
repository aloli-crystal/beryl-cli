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

describe "Parallélisme des tâches de flotte" do
  it "lit --parallel=… : un nombre, `no`/`non` (coupé), sinon illisible" do
    Beryl::CLI::FleetJob.parse_parallel("3").should eq 3
    Beryl::CLI::FleetJob.parse_parallel("no").should eq 0
    Beryl::CLI::FleetJob.parse_parallel("non").should eq 0
    Beryl::CLI::FleetJob.parse_parallel("0").should eq -1
    Beryl::CLI::FleetJob.parse_parallel("beaucoup").should eq -1
  end

  it "réglage `parallel:` hérité du groupe" do
    web = Beryl::CLI::Info.scoped_hosts(scope_root, "web")
    web.map(&.parallel).should eq [2, 2]
    Beryl::CLI::FleetJob.parallel_for(web, nil).should eq 2
  end

  it "portée mêlée : le plus petit réglage ; sans réglage : 4" do
    mixed = Beryl::CLI::Info.scoped_hosts(scope_root, "web,db01")
    Beryl::CLI::FleetJob.parallel_for(mixed, nil).should eq 2
    db = Beryl::CLI::Info.scoped_hosts(scope_root, "db01")
    Beryl::CLI::FleetJob.parallel_for(db, nil).should eq Beryl::CLI::FleetJob::DEFAULT_PARALLEL
  end

  it "--parallel=N l'emporte sur la configuration" do
    web = Beryl::CLI::Info.scoped_hosts(scope_root, "web")
    Beryl::CLI::FleetJob.parallel_for(web, 7).should eq 7
  end
end
