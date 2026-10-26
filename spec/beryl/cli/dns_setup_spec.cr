require "../../spec_helper"
require "../../../src/beryl/cli/dns_setup"

describe Beryl::CLI::DnsSetup do
  describe ".derive_ipv6_address" do
    it "bloc /64 ou /56 en `::` → `::1` (jamais l'adresse réseau)" do
      Beryl::CLI::DnsSetup.derive_ipv6_address("2001:41d0:2:6e01::", "2001:41d0:2:6e01::/64").should eq("2001:41d0:2:6e01::1")
      Beryl::CLI::DnsSetup.derive_ipv6_address("2001:41d0:408:6600::", "2001:41d0:408:6600::/56").should eq("2001:41d0:408:6600::1")
    end

    it "adresse précise (/128) ou déjà complète : inchangée" do
      Beryl::CLI::DnsSetup.derive_ipv6_address("2001:41d0:2:6e01::5", "2001:41d0:2:6e01::5/128").should eq("2001:41d0:2:6e01::5")
    end
  end

  describe ".ipv6_block_64" do
    it "déduit le /64 d'une adresse compressée en fin (cas OVH usuel)" do
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:306:2b67::1")
        .should eq("2001:41d0:306:2b67::/64")
    end

    it "déduit le /64 quand la compression est au milieu" do
      # `::` couvre des groupes nuls AVANT le 4e hextet → le 4e doit
      # être complété à 0, pas pris dans la partie droite.
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:306::2b67:1")
        .should eq("2001:41d0:306:0::/64")
    end

    it "déduit le /64 d'une adresse pleinement développée" do
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:0306:2b67:0:0:0:1")
        .should eq("2001:41d0:0306:2b67::/64")
    end

    it "ignore un éventuel suffixe /prefix déjà présent" do
      Beryl::CLI::DnsSetup.ipv6_block_64("2001:41d0:306:2b67::1/128")
        .should eq("2001:41d0:306:2b67::/64")
    end
  end
end
