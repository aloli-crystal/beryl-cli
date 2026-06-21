require "../../spec_helper"
require "../../../src/beryl/cli/dns_apply"

describe Beryl::CLI::DnsApply do
  describe ".reverse_already_set?" do
    it "vrai sur le 409 OVH « is already setted » (idempotent, pas une erreur)" do
      ex = Exception.new(%(OVH API POST /ip/2001:.../reverse → HTTP 409 : {"message":"Reverse wan.popi.net. for 2001:... is already setted"}))
      Beryl::CLI::DnsApply.reverse_already_set?(ex).should be_true
    end

    it "faux sur une vraie erreur (404, timeout…)" do
      ex = Exception.new("OVH API POST /ip/.../reverse → HTTP 404 : service does not exist")
      Beryl::CLI::DnsApply.reverse_already_set?(ex).should be_false
    end

    it "faux si message nil" do
      Beryl::CLI::DnsApply.reverse_already_set?(Exception.new).should be_false
    end
  end
end
