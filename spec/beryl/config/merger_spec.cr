require "../../spec_helper"
require "../../../src/beryl/config"
require "yaml"

# Helpers de construction manuelle (pas besoin de passer par le disque).
private def hash_from_yaml(yaml : String) : Hash(YAML::Any, YAML::Any)
  YAML.parse(yaml).as_h
end

private def host_node(yaml : String, name : String = "host") : Beryl::Config::HostNode
  Beryl::Config::HostNode.new(name, hash_from_yaml(yaml), "/mock")
end

private def domain(yaml : String, name : String = "aloli.net") : Beryl::Config::Domain
  Beryl::Config::Domain.new(name, hash_from_yaml(yaml), {} of String => Beryl::Config::HostNode, {} of String => Beryl::Config::Group, "/mock")
end

private def group(yaml : String, name : String = "web") : Beryl::Config::Group
  Beryl::Config::Group.new(name, hash_from_yaml(yaml), {} of String => Beryl::Config::HostNode, "/mock")
end

describe Beryl::Config::Merger do
  describe ".merge" do
    it "applique l'ordre _default > domaine > host pour les scalaires" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        timezone: Europe/Paris
        raid: stripe
      YAML
      d = domain(<<-YAML)
      ssh_keys: [k]
      freebsd:
        swap_gb: 4
      YAML
      h = host_node(<<-YAML)
      freebsd:
        hostname: loulou
        raid: mirror
      YAML

      merged = Beryl::Config::Merger.merge(defaults, d, nil, h)
      fb = merged[YAML::Any.new("freebsd")].as_h
      fb[YAML::Any.new("timezone")].as_s.should eq("Europe/Paris") # de _default
      fb[YAML::Any.new("swap_gb")].as_i.should eq(4)               # de domaine
      fb[YAML::Any.new("hostname")].as_s.should eq("loulou")       # de host
      fb[YAML::Any.new("raid")].as_s.should eq("mirror")           # host override _default
    end

    it "append les packages depuis _default + groupe + host (dédup)" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        packages: [sudo, zsh, curl, git]
      YAML
      d = domain("ssh_keys: [k]\n")
      g = group(<<-YAML)
      freebsd:
        packages: [nginx, postgresql16-server]
      YAML
      h = host_node(<<-YAML)
      freebsd:
        packages: [redis, sudo]
      YAML

      merged = Beryl::Config::Merger.merge(defaults, d, g, h)
      packages = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("packages")].as_a.map(&.as_s)
      packages.should eq(["sudo", "zsh", "curl", "git", "nginx", "postgresql16-server", "redis"])
      # `sudo` dédupé
    end

    it "remplace disks au niveau host (pas d'append)" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        disks: [/dev/sda]
      YAML
      d = domain("ssh_keys: [k]\n")
      h = host_node(<<-YAML)
      freebsd:
        disks: [/dev/sdc, /dev/sdd]
      YAML

      merged = Beryl::Config::Merger.merge(defaults, d, nil, h)
      disks = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("disks")].as_a.map(&.as_s)
      disks.should eq(["/dev/sdc", "/dev/sdd"])
    end
  end

  describe "clé domaine injectée dans les users" do
    it "injecte la clé domaine dans chaque user du _default" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        users:
          - name: admin
            primary_group: www
            secondary_groups: [wheel]
            shell: /usr/local/bin/zsh
          - name: deploy
            primary_group: www
            secondary_groups: []
            shell: /bin/csh
      YAML
      d = domain(<<-YAML)
      ssh_keys:
        - ssh-ed25519 AAAA philippe@aloli.fr
      YAML
      h = host_node("freebsd:\n  hostname: x\n")

      merged = Beryl::Config::Merger.merge(defaults, d, nil, h)
      users = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a

      users.size.should eq(2)
      users.each do |user|
        keys = user.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
        keys.should contain("ssh-ed25519 AAAA philippe@aloli.fr")
      end
    end

    it "ajoute les clés host en plus de la clé domaine (obligatoire en tête)" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        users:
          - name: deploy
            primary_group: www
            shell: /bin/csh
      YAML
      d = domain(<<-YAML)
      ssh_keys:
        - ssh-ed25519 AAAA philippe@aloli.fr
      YAML
      h = host_node(<<-YAML)
      freebsd:
        users:
          - name: deploy
            ssh_keys:
              - ssh-ed25519 AAAA dev2@aloli.fr
              - ssh-ed25519 AAAA dev3@aloli.fr
      YAML

      merged = Beryl::Config::Merger.merge(defaults, d, nil, h)
      deploy = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
        .find! { |u| u.as_h[YAML::Any.new("name")].as_s == "deploy" }
      keys = deploy.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)

      keys.size.should eq(3)
      keys[0].should eq("ssh-ed25519 AAAA philippe@aloli.fr") # domaine en tête
      keys[1].should eq("ssh-ed25519 AAAA dev2@aloli.fr")
      keys[2].should eq("ssh-ed25519 AAAA dev3@aloli.fr")
    end

    it "la clé domaine n'est pas dupliquée si le host la liste déjà" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        users:
          - name: admin
            primary_group: www
      YAML
      d = domain(<<-YAML)
      ssh_keys:
        - ssh-ed25519 AAAA philippe@aloli.fr
      YAML
      h = host_node(<<-YAML)
      freebsd:
        users:
          - name: admin
            ssh_keys:
              - ssh-ed25519 AAAA philippe@aloli.fr
              - ssh-ed25519 AAAA autre@aloli.fr
      YAML

      merged = Beryl::Config::Merger.merge(defaults, d, nil, h)
      admin = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a.first
      keys = admin.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)

      keys.size.should eq(2)
      keys.count("ssh-ed25519 AAAA philippe@aloli.fr").should eq(1) # pas doublée
      keys.should contain("ssh-ed25519 AAAA autre@aloli.fr")
    end

    it "supprime une clé retirée du host (sémantique déclarative)" do
      # Itération 1 : le host a dev2 et dev3.
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        users:
          - name: deploy
            primary_group: www
      YAML
      d = domain("ssh_keys:\n  - ssh-ed25519 AAAA philippe\n")

      h_v1 = host_node(<<-YAML)
      freebsd:
        users:
          - name: deploy
            ssh_keys:
              - ssh-ed25519 AAAA dev2
              - ssh-ed25519 AAAA dev3
      YAML

      # Itération 2 : on retire dev3.
      h_v2 = host_node(<<-YAML)
      freebsd:
        users:
          - name: deploy
            ssh_keys:
              - ssh-ed25519 AAAA dev2
      YAML

      v1 = Beryl::Config::Merger.merge(defaults, d, nil, h_v1)
      v2 = Beryl::Config::Merger.merge(defaults, d, nil, h_v2)

      v1_keys = v1[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a.first.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
      v2_keys = v2[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a.first.as_h[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)

      v1_keys.should eq(["ssh-ed25519 AAAA philippe", "ssh-ed25519 AAAA dev2", "ssh-ed25519 AAAA dev3"])
      v2_keys.should eq(["ssh-ed25519 AAAA philippe", "ssh-ed25519 AAAA dev2"])
      # dev3 a disparu : apply pourra le supprimer du serveur.
    end
  end
end
