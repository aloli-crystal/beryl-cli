require "../spec_helper"

private YAML_MINIMAL = <<-YAML
  hosts:
    web01.aloli.fr: {}
  YAML

private YAML_COMPLET = <<-YAML
  defaults:
    user: root
    port: 22
    identity_file: ~/.ssh/id_ed25519

  hosts:
    web01.aloli.fr:
      provider: ovh
      recipes:
        - core-system
        - nginx-crystal-deploy
      variables:
        timezone: Europe/Paris

    web02.scaleway.aloli.fr:
      provider: scaleway
      user: admin
      port: 2222
  YAML

describe Beryl::Inventory do
  describe ".from_yaml" do
    it "accepte un inventaire minimal avec des valeurs par défaut" do
      inv = Beryl::Inventory.from_yaml(YAML_MINIMAL)
      inv.size.should eq(1)
      host = inv.find("web01.aloli.fr")
      host.user.should eq("root")
      host.port.should eq(22)
      host.recipes.should be_empty
    end

    it "applique les defaults puis les overrides de chaque hôte" do
      inv = Beryl::Inventory.from_yaml(YAML_COMPLET)

      web01 = inv.find("web01.aloli.fr")
      web01.user.should eq("root")
      web01.port.should eq(22)
      web01.identity_file.should eq("~/.ssh/id_ed25519")
      web01.provider.should eq("ovh")
      web01.recipes.should eq(["core-system", "nginx-crystal-deploy"])
      web01.variables["timezone"].as_s.should eq("Europe/Paris")

      web02 = inv.find("web02.scaleway.aloli.fr")
      web02.user.should eq("admin")
      web02.port.should eq(2222)
      web02.identity_file.should eq("~/.ssh/id_ed25519") # hérité des defaults
      web02.provider.should eq("scaleway")
    end

    it "lève NotFound pour un hôte inexistant" do
      inv = Beryl::Inventory.from_yaml(YAML_MINIMAL)
      expect_raises(Beryl::Inventory::NotFound, /web99/) do
        inv.find("web99.aloli.fr")
      end
    end

    it "retourne nil avec find? pour un hôte inexistant" do
      inv = Beryl::Inventory.from_yaml(YAML_MINIMAL)
      inv.find?("web99.aloli.fr").should be_nil
    end
  end

  describe "Host#connection" do
    it "construit une SSH::Connection conforme aux paramètres de l'hôte" do
      inv = Beryl::Inventory.from_yaml(YAML_COMPLET)
      conn = inv.find("web02.scaleway.aloli.fr").connection
      conn.host.should eq("web02.scaleway.aloli.fr")
      conn.user.should eq("admin")
      conn.port.should eq(2222)
    end
  end
end
