require "../../spec_helper"
require "../../../src/beryl/cli/vrack_dns"

describe Beryl::CLI::VrackDns do
  describe ".unbound_local_data" do
    it "génère A + PTR par hôte, triés par nom" do
      data = Beryl::CLI::VrackDns.unbound_local_data(
        [{"zsbg", "192.168.42.3"}, {"bi", "192.168.42.30"}], "vrack.popi.net")
      data.should contain(%(local-data: "bi.vrack.popi.net. IN A 192.168.42.30"))
      data.should contain(%(local-data-ptr: "192.168.42.30 bi.vrack.popi.net."))
      data.should contain(%(local-data: "zsbg.vrack.popi.net. IN A 192.168.42.3"))
      # tri alpha : bi avant zsbg
      data.index("bi.vrack").not_nil!.should be < data.index("zsbg.vrack").not_nil!
    end

    it "vide si aucun enregistrement" do
      Beryl::CLI::VrackDns.unbound_local_data([] of {String, String}, "vrack.popi.net").should eq("")
    end
  end
end
