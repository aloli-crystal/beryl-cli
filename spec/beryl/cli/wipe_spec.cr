require "../../spec_helper"
require "../../../src/beryl/cli/wipe"

# Specs « smoke » pour `beryl wipe`. La logique lourde (connexion SSH,
# commandes shell destructrices) n'est pas testée ici — on se contente
# de vérifier les vérifications en amont : parsing d'arguments, refus
# si hôte introuvable et non résolvable, et acceptation d'un
# service_name OVH nu via `HostResolver.resolve`.
describe Beryl::CLI::Wipe do
  describe ".run" do
    it "refuse sans host" do
      io = IO::Memory.new
      Beryl::CLI::Wipe.run("/inexistant.yml", ["--disk=/dev/sda"], confirm_io: io).should eq(Beryl::CLI::Wipe::EXIT_USAGE)
    end

    it "refuse sans --disk" do
      io = IO::Memory.new
      Beryl::CLI::Wipe.run("/inexistant.yml", ["ns3156789.ip-51-83-6.eu"], confirm_io: io).should eq(Beryl::CLI::Wipe::EXIT_USAGE)
    end

    it "lève NotFound avec un nom qui ne ressemble à rien (pas OVH, pas en inventaire)" do
      io = IO::Memory.new
      ret = Beryl::CLI::Wipe.run("/inexistant.yml", ["not-a-name", "--disk=/dev/sda"], confirm_io: io)
      ret.should eq(Beryl::CLI::Wipe::EXIT_USAGE)
    end

    it "accepte un service_name OVH nu (heuristique fallback, pas d'erreur « hôte inconnu »)" do
      # Sans credentials OVH, HostResolver construit un Host virtuel
      # via l'heuristique nsXXX.ip-A-B-C.tld. wipe essaiera ensuite de
      # se connecter en SSH, ce qui échoue hors réseau — on accepte
      # tout code de retour SAUF EXIT_USAGE (« hôte inconnu »).
      io = IO::Memory.new
      ret = Beryl::CLI::Wipe.run(
        "/inexistant.yml",
        ["ns3156789.ip-51-83-6.eu", "--disk=/dev/sda", "--force"],
        confirm_io: io,
      )
      ret.should_not eq(Beryl::CLI::Wipe::EXIT_USAGE)
    end
  end
end
