require "../../spec_helper"
require "../../../src/beryl/cli/host_resolver"
require "file_utils"

# Provider factice pour tester la logique de résolution sans toucher
# aux vraies API d'hébergeur. Chaque test configure la liste des
# serveurs « possédés » + la disponibilité des credentials.
private class FakeProvider < Beryl::Provider
  getter name_val : String
  getter is_available : Bool
  getter owns_set : Set(String)
  getter display_name_val : String

  def initialize(@name_val, @is_available = true, owns : Array(String) = [] of String, display : String? = nil)
    @owns_set = Set(String).new(owns)
    @display_name_val = display || "Fake #{@name_val}"
  end

  def name : String
    @name_val
  end

  def display_name : String
    @display_name_val
  end

  def available? : Bool
    @is_available
  end

  def list_ssh_keys : Array(Beryl::SshKeyInfo)
    [] of Beryl::SshKeyInfo
  end

  def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
    result = {} of String => String | Array(String)
    result["key"] = key_id
    result
  end

  def credentials_env_vars : Array(Beryl::EnvVarSpec)
    [] of Beryl::EnvVarSpec
  end

  def credentials_help_url : String
    ""
  end

  def owns?(host_name : String) : Bool
    @owns_set.includes?(host_name)
  end
end

# Helper : exécute un bloc avec un registre de providers vide +
# ceux fournis, puis restaure les providers initiaux.
private def with_providers(providers : Array(Beryl::Provider), &)
  saved = Beryl::Providers.all
  Beryl::Providers.clear
  providers.each { |p| Beryl::Providers.register(p) }
  yield
ensure
  Beryl::Providers.clear
  saved.each { |p| Beryl::Providers.register(p) } if saved
end

# Helper : crée un inventaire temporaire avec le YAML donné et yield
# son chemin. Nettoyé à la sortie.
private def with_inventory(yaml : String, &)
  path = File.tempname("beryl-resolver-test-", ".yml")
  File.write(path, yaml)
  begin
    yield path
  ensure
    File.delete(path) rescue nil
  end
end

describe Beryl::CLI::HostResolver do
  describe ".resolve" do
    it "retourne l'hôte de l'inventaire quand il est connu" do
      yaml = <<-YAML
        hosts:
          rails01.aloli.fr:
            provider: ovh
            ovh:
              service_name: ns1.example
        YAML

      with_providers([] of Beryl::Provider) do
        with_inventory(yaml) do |path|
          host = Beryl::CLI::HostResolver.resolve(path, "rails01.aloli.fr")
          host.name.should eq("rails01.aloli.fr")
          host.provider.should eq("ovh")
          host.ovh_service_name.should eq("ns1.example")
        end
      end
    end

    it "construit un Host virtuel quand provider_hint=ovh (flag --provider)" do
      with_providers([] of Beryl::Provider) do
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", "ns9999.ip-1-2-3.eu", "ovh")
        host.provider.should eq("ovh")
        host.ovh_service_name.should eq("ns9999.ip-1-2-3.eu")
      end
    end

    it "construit un Host virtuel scaleway avec un UUID" do
      with_providers([] of Beryl::Provider) do
        uuid = "11111111-2222-3333-4444-555555555555"
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", uuid, "scaleway")
        host.provider.should eq("scaleway")
        host.scaleway_server_id.should eq(uuid)
      end
    end

    it "auto-détecte via Provider#owns? (OVH a le serveur)" do
      ovh = FakeProvider.new("ovh", owns: ["ns3156789.ip-51-83-6.eu"])
      scw = FakeProvider.new("scaleway", owns: [] of String)

      with_providers([ovh, scw]) do
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", "ns3156789.ip-51-83-6.eu")
        host.provider.should eq("ovh")
        host.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
      end
    end

    it "auto-détecte via Provider#owns? (Scaleway a le serveur)" do
      ovh = FakeProvider.new("ovh", owns: [] of String)
      scw = FakeProvider.new("scaleway", owns: ["mon-serveur-scw"])

      with_providers([ovh, scw]) do
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", "mon-serveur-scw")
        host.provider.should eq("scaleway")
        host.scaleway_server_id.should eq("mon-serveur-scw")
      end
    end

    it "ignore un provider non disponible (credentials manquants) lors de l'auto-détection" do
      ovh_off = FakeProvider.new("ovh", is_available: false, owns: ["ns9.ip-1-2-3.eu"])
      scw = FakeProvider.new("scaleway", owns: ["ns9.ip-1-2-3.eu"])

      with_providers([ovh_off, scw]) do
        # ovh_off prétend posséder le host mais is_available=false → exclu
        # de Providers.available. Scaleway gagne.
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", "ns9.ip-1-2-3.eu")
        host.provider.should eq("scaleway")
      end
    end

    it "fallback heuristique OVH quand aucun provider n'a matché" do
      # Pas de provider disponible → fallback sur le pattern nsXXX.ip-A-B-C.tld
      with_providers([] of Beryl::Provider) do
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", "ns3156789.ip-51-83-6.eu")
        host.provider.should eq("ovh")
        host.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
      end
    end

    it "lève quand le nom n'est ni dans l'inventaire, ni détecté, ni reconnu" do
      with_providers([] of Beryl::Provider) do
        expect_raises(Beryl::Inventory::NotFound, /inconnu/) do
          Beryl::CLI::HostResolver.resolve("/inexistant.yml", "nom-bizarre")
        end
      end
    end

    it "privilégie l'inventaire sur l'auto-détection" do
      # Même si un provider dit « je l'ai », l'inventaire gagne.
      yaml = <<-YAML
        hosts:
          shared-name.example:
            provider: scaleway
            scaleway:
              server_id: 11111111-2222-3333-4444-555555555555
        YAML

      ovh = FakeProvider.new("ovh", owns: ["shared-name.example"])

      with_providers([ovh]) do
        with_inventory(yaml) do |path|
          host = Beryl::CLI::HostResolver.resolve(path, "shared-name.example")
          host.provider.should eq("scaleway") # depuis inventaire, pas ovh
        end
      end
    end

    it "privilégie provider_hint sur l'auto-détection" do
      ovh = FakeProvider.new("ovh", owns: ["serveur.example"])

      with_providers([ovh]) do
        # On force scaleway même si ovh aurait matché.
        host = Beryl::CLI::HostResolver.resolve("/inexistant.yml", "serveur.example", "scaleway")
        host.provider.should eq("scaleway")
      end
    end
  end

  describe ".looks_like_ovh_service_name?" do
    it "reconnaît les formats OVH valides" do
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("ns3156789.ip-51-83-6.eu").should be_true
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("ns42.ip-1-2-3.com").should be_true
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("ns1.ip-4-5-6.net").should be_true
    end

    it "rejette les autres formats" do
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("rails01.aloli.fr").should be_false
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("11111111-2222-3333-4444-555555555555").should be_false
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("mon-serveur").should be_false
      Beryl::CLI::HostResolver.looks_like_ovh_service_name?("").should be_false
    end
  end

  describe ".build_virtual_host" do
    it "remplit service_name pour OVH" do
      host = Beryl::CLI::HostResolver.build_virtual_host("ns1.ip-1-2-3.eu", "ovh")
      host.provider.should eq("ovh")
      host.ovh_service_name.should eq("ns1.ip-1-2-3.eu")
      host.scaleway_server_id.should be_nil
    end

    it "remplit server_id pour Scaleway" do
      host = Beryl::CLI::HostResolver.build_virtual_host("uuid-123", "scaleway")
      host.provider.should eq("scaleway")
      host.scaleway_server_id.should eq("uuid-123")
      host.ovh_service_name.should be_nil
    end

    it "utilise `id` générique pour un provider inconnu" do
      host = Beryl::CLI::HostResolver.build_virtual_host("x", "hetzner")
      host.provider.should eq("hetzner")
      host.provider_config["id"].as_s.should eq("x")
    end
  end
end
