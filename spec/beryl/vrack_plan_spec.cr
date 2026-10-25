require "../spec_helper"
require "../../src/beryl/vrack_plan"

private def entry(host : String, ip : String, vrack = "pn-1", subnet : String? = "192.168.42.0/24")
  Beryl::VrackPlan::Entry.new(host, ip, vrack, subnet)
end

describe Beryl::VrackPlan do
  describe ".problems" do
    it "rien à signaler sur un plan propre" do
      Beryl::VrackPlan.problems([entry("zgra", "192.168.42.10"), entry("pkg", "192.168.42.1")]).should be_empty
    end

    it "collision : deux serveurs sur la même IP d'un même vRack" do
      p = Beryl::VrackPlan.problems([entry("zgra", "192.168.42.1"), entry("pkg", "192.168.42.1")])
      p.should eq ["collision 192.168.42.1 : zgra, pkg (vRack pn-1)"]
    end

    it "même IP dans deux vRack différents : pas une collision" do
      Beryl::VrackPlan.problems([entry("a", "192.168.42.5", "pn-1"), entry("b", "192.168.42.5", "pn-2")]).should be_empty
    end

    it "rotation (deux IP sur une même fiche) : pas une collision" do
      Beryl::VrackPlan.problems([entry("zgra", "192.168.42.1"), entry("zgra", "192.168.42.10")]).should be_empty
    end

    it "adresse .0 ou .255 : signalée" do
      Beryl::VrackPlan.problems([entry("a", "192.168.42.255")]).first.should contain "pas une adresse de serveur"
    end

    it "hors du réseau déclaré : signalée ; sans réseau déclaré : pas de contrôle" do
      Beryl::VrackPlan.problems([entry("a", "10.0.0.5")]).first.should contain "hors du réseau 192.168.42.0/24"
      Beryl::VrackPlan.problems([entry("a", "10.0.0.5", subnet: nil)]).should be_empty
    end
  end

  describe ".in_subnet?" do
    it "masques usuels" do
      Beryl::VrackPlan.in_subnet?("192.168.42.39", "192.168.42.0/24").should be_true
      Beryl::VrackPlan.in_subnet?("192.168.43.1", "192.168.42.0/24").should be_false
      Beryl::VrackPlan.in_subnet?("10.20.30.40", "10.0.0.0/8").should be_true
      Beryl::VrackPlan.in_subnet?("192.168.42.1", "0.0.0.0/0").should be_true
    end

    it "illisible : faux" do
      Beryl::VrackPlan.in_subnet?("pas-une-ip", "192.168.42.0/24").should be_false
      Beryl::VrackPlan.in_subnet?("192.168.42.1", "192.168.42.0/33").should be_false
    end
  end
end
