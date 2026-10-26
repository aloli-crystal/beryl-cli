require "../spec_helper"
require "../../src/beryl/vrack_zone"

private def peer(name : String, ip : String, bastion = false)
  Beryl::VrackZone::Peer.new(name, ip, bastion)
end

describe Beryl::VrackZone do
  describe ".local_data" do
    it "A + PTR par host, dans l'ordre reçu" do
      data = Beryl::VrackZone.local_data([peer("pkg", "192.168.42.1"), peer("zgra", "192.168.42.10", true)], "vrack.internal")
      data.should eq <<-DATA.rstrip
            local-data: "pkg.vrack.internal. IN A 192.168.42.1"
            local-data-ptr: "192.168.42.1 pkg.vrack.internal."
            local-data: "zgra.vrack.internal. IN A 192.168.42.10"
            local-data-ptr: "192.168.42.10 zgra.vrack.internal."
        DATA
    end

    it "aucun host : vide" do
      Beryl::VrackZone.local_data([] of Beryl::VrackZone::Peer, "vrack.internal").should eq ""
    end
  end

  describe ".stub_addrs" do
    it "les bastions seulement" do
      Beryl::VrackZone.stub_addrs([peer("pkg", "192.168.42.1"), peer("zgra", "192.168.42.10", true), peer("zrbx", "192.168.42.20", true)])
        .should eq "    stub-addr: 192.168.42.10\n    stub-addr: 192.168.42.20"
    end
  end

  describe ".reverse_zone" do
    it "réseaux découpés à l'octet" do
      Beryl::VrackZone.reverse_zone("192.168.42.0/24").should eq "42.168.192.in-addr.arpa"
      Beryl::VrackZone.reverse_zone("10.20.0.0/16").should eq "20.10.in-addr.arpa"
      Beryl::VrackZone.reverse_zone("10.0.0.0/8").should eq "10.in-addr.arpa"
    end

    it "autre masque ou absent : nil" do
      Beryl::VrackZone.reverse_zone("192.168.42.0/25").should be_nil
      Beryl::VrackZone.reverse_zone(nil).should be_nil
    end
  end
end
