require "../../spec_helper"
require "../../../src/beryl/cli/hoist_globals"

describe "Beryl::CLI.hoist_globals" do
  it "ramène --transport=MODE écrit après la sous-commande" do
    Beryl::CLI.hoist_globals(%w[sync sauvegardes vrack-interface --apply --transport=direct])
      .should eq(%w[--transport=direct sync sauvegardes vrack-interface --apply])
  end

  it "accepte la forme en deux mots" do
    Beryl::CLI.hoist_globals(%w[unlock hoth --transport direct --apply])
      .should eq(%w[--transport direct unlock hoth --apply])
  end

  it "ramène -c VALEUR et --config=VALEUR" do
    Beryl::CLI.hoist_globals(%w[sync g --apply -c /cfg])
      .should eq(%w[-c /cfg sync g --apply])
    Beryl::CLI.hoist_globals(%w[show h --config=/cfg])
      .should eq(%w[--config=/cfg show h])
  end

  it "laisse en place une ligne déjà dans l'ordre" do
    Beryl::CLI.hoist_globals(%w[-c /cfg --transport=overlay sync g])
      .should eq(%w[-c /cfg --transport=overlay sync g])
  end

  it "ne touche pas --headscale-config, ni rien après --" do
    Beryl::CLI.hoist_globals(%w[headscale-authkey h --headscale-config=/x])
      .should eq(%w[headscale-authkey h --headscale-config=/x])
    Beryl::CLI.hoist_globals(%w[sync g -- --transport=direct])
      .should eq(%w[sync g -- --transport=direct])
  end
end
