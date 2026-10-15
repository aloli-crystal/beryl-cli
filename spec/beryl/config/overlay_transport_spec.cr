require "../../spec_helper"

# Tests du switch `Beryl.transport_mode`. Le couplage avec
# `ResolvedHost#ssh_host` est validé par les tests d'intégration et
# manuellement (cf. memory INITECH `roadmap_beryl_headscale.md` Phase 4).

describe "Beryl.transport_mode" do
  it "default est :public" do
    # Reset au cas où un test précédent a basculé.
    Beryl.transport_mode = :public
    Beryl.transport_mode.should eq(:public)
    Beryl.use_overlay_transport?.should be_false
  end

  it "rejette une valeur invalide" do
    expect_raises(ArgumentError, /transport_mode invalide/) do
      Beryl.transport_mode = :invalid
    end
  end

  it "bascule à :overlay" do
    Beryl.transport_mode = :overlay
    Beryl.use_overlay_transport?.should be_true
  ensure
    Beryl.transport_mode = :public
  end

  it "accepte le retour à :public après :overlay" do
    Beryl.transport_mode = :overlay
    Beryl.transport_mode = :public
    Beryl.use_overlay_transport?.should be_false
  end
end
