require "../spec_helper"
require "../../src/beryl/ipv6_plan"

describe Beryl::Ipv6Plan do
  describe ".in_block?" do
    it "adresse dans son bloc /56 ou /64" do
      Beryl::Ipv6Plan.in_block?("2001:41d0:364:3e00::1", "2001:41d0:364:3e00::/56").should be_true
      Beryl::Ipv6Plan.in_block?("2001:41d0:364:3eff::5", "2001:41d0:364:3e00::/56").should be_true
      Beryl::Ipv6Plan.in_block?("2001:41d0:306:2b67::1", "2001:41d0:306:2b67::/64").should be_true
    end

    it "adresse hors du bloc (cas de ke)" do
      Beryl::Ipv6Plan.in_block?("2001:41d0:306:43d3::1", "2001:41d0:364:3e00::/56").should be_false
      Beryl::Ipv6Plan.in_block?("2001:41d0:364:3f00::1", "2001:41d0:364:3e00::/56").should be_false
    end

    it "illisible : faux" do
      Beryl::Ipv6Plan.in_block?("pas-une-ip", "2001:db8::/32").should be_false
      Beryl::Ipv6Plan.in_block?("2001:db8::1", "2001:db8::/129").should be_false
    end
  end

  describe ".value" do
    it "formes courte, longue et avec zone" do
      Beryl::Ipv6Plan.value("::1").should eq(1_u128)
      Beryl::Ipv6Plan.value("2001:41d0:0364:3e00:0000:0000:0000:0001").should eq(Beryl::Ipv6Plan.value("2001:41d0:364:3e00::1"))
      Beryl::Ipv6Plan.value("fe80::1%bnxt0").should eq(Beryl::Ipv6Plan.value("fe80::1"))
      Beryl::Ipv6Plan.value("1::2::3").should be_nil
    end
  end
end
