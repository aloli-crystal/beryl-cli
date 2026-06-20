require "../../spec_helper"
require "../../../src/beryl/cli/headscale_authkey"

# Tests du parsing de la sortie `headscale preauthkeys create -o json`.
# C'est la partie sensible : la sortie réelle peut comporter des lignes de
# log avant le JSON (selon le niveau de log du serveur), et le format JSON
# varie un peu selon la version de Headscale. (`out` est un mot-clé Crystal
# → on nomme les variables `txt`.)
describe Beryl::CLI::HeadscaleAuthkey do
  describe ".extract_key" do
    it "extrait la clé d'une sortie JSON simple" do
      json = %({"id":"3","key":"abcdef0123456789","user":"aloli","reusable":false})
      Beryl::CLI::HeadscaleAuthkey.extract_key(json).should eq("abcdef0123456789")
    end

    it "ignore des lignes de log AVANT le bloc JSON" do
      txt = <<-TXT
        2026-06-20T22:00:00Z INF headscale starting
        {"id":"7","key":"deadbeefcafe","user":"aloli"}
        TXT
      Beryl::CLI::HeadscaleAuthkey.extract_key(txt).should eq("deadbeefcafe")
    end

    it "gère un JSON multi-ligne (pretty-printed)" do
      txt = <<-TXT
        {
          "id": "9",
          "key": "0011223344556677",
          "user": "aloli"
        }
        TXT
      Beryl::CLI::HeadscaleAuthkey.extract_key(txt).should eq("0011223344556677")
    end

    it "renvoie nil si le champ key est absent" do
      Beryl::CLI::HeadscaleAuthkey.extract_key(%({"id":"3","user":"aloli"})).should be_nil
    end

    it "renvoie nil si la clé est vide" do
      Beryl::CLI::HeadscaleAuthkey.extract_key(%({"key":""})).should be_nil
    end

    it "renvoie nil si la sortie ne contient pas de JSON" do
      Beryl::CLI::HeadscaleAuthkey.extract_key("Error: user not found\n").should be_nil
    end

    it "renvoie nil sur un JSON malformé" do
      Beryl::CLI::HeadscaleAuthkey.extract_key("{ ceci n'est pas du json }").should be_nil
    end

    it "renvoie nil sur une sortie vide" do
      Beryl::CLI::HeadscaleAuthkey.extract_key("").should be_nil
    end
  end
end
