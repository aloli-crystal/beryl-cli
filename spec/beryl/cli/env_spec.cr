require "../../spec_helper"
require "../../../src/beryl/cli/env"

describe Beryl::CLI::Env do
  describe ".strip_error_notes" do
    it "retire les lignes de note d'erreur injectées (préfixe ERR_MARKER)" do
      injected = "#{Beryl::CLI::Env::ERR_MARKER} TOML invalide : oops\n" \
                 "#{Beryl::CLI::Env::ERR_MARKER} Corrigez puis sauvez.\n" \
                 "[mail]\nSMTP_RELAY_USER = \"it@popi.net\"\n"
      Beryl::CLI::Env.strip_error_notes(injected).should eq(
        "[mail]\nSMTP_RELAY_USER = \"it@popi.net\"\n")
    end

    it "laisse intact un contenu sans note (idempotent)" do
      content = "[ovh]\nOVH_APPLICATION_KEY = \"xxx\"\n"
      Beryl::CLI::Env.strip_error_notes(content).should eq(content)
    end

    it "ne touche pas une ligne qui contient le marqueur sans commencer par lui" do
      content = "KEY = \"valeur #!ERR au milieu\"\n"
      Beryl::CLI::Env.strip_error_notes(content).should eq(content)
    end
  end
end
