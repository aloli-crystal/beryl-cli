require "../../spec_helper"
require "../../../src/beryl/config"
require "yaml"

# Métadonnées société (_account.yml) vides pour les tests qui ne testent
# pas le niveau société.
private EMPTY_META = {} of YAML::Any => YAML::Any

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
      ssh_keys: ['ssh-ed25519 AAAA k']
      freebsd:
        swap_gb: 4
      YAML
      h = host_node(<<-YAML)
      freebsd:
        hostname: loulou
        raid: mirror
      YAML

      merged = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h)
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
      d = domain("ssh_keys: ['ssh-ed25519 AAAA k']\n")
      g = group(<<-YAML)
      freebsd:
        packages: [nginx, postgresql16-server]
      YAML
      h = host_node(<<-YAML)
      freebsd:
        packages: [redis, sudo]
      YAML

      merged = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, g, h)
      packages = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("packages")].as_a.map(&.as_s)
      packages.should eq(["sudo", "zsh", "curl", "git", "nginx", "postgresql16-server", "redis"])
      # `sudo` dédupé
    end

    it "remplace disks au niveau host (pas d'append)" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        disks: [/dev/sda]
      YAML
      d = domain("ssh_keys: ['ssh-ed25519 AAAA k']\n")
      h = host_node(<<-YAML)
      freebsd:
        disks: [/dev/sdc, /dev/sdd]
      YAML

      merged = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h)
      disks = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("disks")].as_a.map(&.as_s)
      disks.should eq(["/dev/sdc", "/dev/sdd"])
    end

    it "cascade apply_recipes : société (_account.yml) + domaine + host s'additionnent" do
      defaults = hash_from_yaml("os: freebsd\n")
      account_meta = hash_from_yaml("apply_recipes: [ssh-hardening]\n")
      d = domain(<<-YAML)
      ssh_keys: ['ssh-ed25519 AAAA k']
      apply_recipes: [ruby]
      YAML
      h = host_node(<<-YAML)
      freebsd:
        hostname: x
      apply_recipes: [headscale-node]
      YAML

      merged = Beryl::Config::Merger.merge(defaults, account_meta, d, nil, h)
      recipes = merged[YAML::Any.new("apply_recipes")].as_a.map(&.as_s)
      recipes.should eq(["ssh-hardening", "ruby", "headscale-node"])
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

      merged = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h)
      users = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a

      users.size.should eq(2)
      Beryl::Config::Users.list(users).each do |e|
        keys = e.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
        keys.should contain("ssh-ed25519 AAAA philippe@aloli.fr")
      end
    end

    it "injecte la clé déclarée au niveau SOCIÉTÉ (cherchée dans le merge, pas que le domaine)" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        users:
          - admin:
              groups: [www, wheel]
              shell: /bin/csh
      YAML
      # Clé SSH au niveau SOCIÉTÉ (`_account.yml`/`_defaults.yml`), domaine SANS ssh_keys.
      account_meta = hash_from_yaml("ssh_keys:\n  - ssh-ed25519 AAAA societe\n")
      d = domain("provider: ovh\n")
      h = host_node("freebsd:\n  hostname: x\n")

      merged = Beryl::Config::Merger.merge(defaults, account_meta, d, nil, h)
      users = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
      keys = Beryl::Config::Users.list(users).first.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
      keys.should contain("ssh-ed25519 AAAA societe")
    end

    it "précédence host > domaine > société : le plus spécifique REMPLACE (premier trouvé)" do
      defaults = hash_from_yaml(<<-YAML)
      freebsd:
        users:
          - admin:
              groups: [www, wheel]
              shell: /bin/csh
      YAML
      account_meta = hash_from_yaml("ssh_keys:\n  - ssh-ed25519 AAAA societe\n")
      d = domain("ssh_keys:\n  - ssh-ed25519 AAAA domaine\n")
      h = host_node("ssh_keys:\n  - ssh-ed25519 AAAA host\nfreebsd:\n  hostname: x\n")

      merged = Beryl::Config::Merger.merge(defaults, account_meta, d, nil, h)
      users = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
      keys = Beryl::Config::Users.list(users).first.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
      keys.should contain("ssh-ed25519 AAAA host")        # host gagne…
      keys.should_not contain("ssh-ed25519 AAAA domaine") # …et remplace domaine
      keys.should_not contain("ssh-ed25519 AAAA societe") # …et société
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

      merged = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h)
      users = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
      deploy = Beryl::Config::Users.list(users).find! { |e| e.name == "deploy" }
      keys = deploy.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)

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

      merged = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h)
      users = merged[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
      keys = Beryl::Config::Users.list(users).first.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)

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

      v1 = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h_v1)
      v2 = Beryl::Config::Merger.merge(defaults, EMPTY_META, d, nil, h_v2)

      v1_users = v1[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
      v2_users = v2[YAML::Any.new("freebsd")].as_h[YAML::Any.new("users")].as_a
      v1_keys = Beryl::Config::Users.list(v1_users).first.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)
      v2_keys = Beryl::Config::Users.list(v2_users).first.fields[YAML::Any.new("ssh_keys")].as_a.map(&.as_s)

      v1_keys.should eq(["ssh-ed25519 AAAA philippe", "ssh-ed25519 AAAA dev2", "ssh-ed25519 AAAA dev3"])
      v2_keys.should eq(["ssh-ed25519 AAAA philippe", "ssh-ed25519 AAAA dev2"])
      # dev3 a disparu : apply pourra le supprimer du serveur.
    end
  end

  describe ".merge_users (forme NOUVELLE : user en clé)" do
    it "fusionne par nom (override gagne champ par champ), ordre préservé" do
      base = YAML.parse("- deploy:\n    groups: [wheel]\n    shell: /bin/csh\n").as_a
      override = YAML.parse("- deploy:\n    shell: oh-my-zsh\n- admin:\n    groups: [wheel]\n").as_a
      users = Beryl::Config::Users.list(Beryl::Config::Merger.merge_users(base, override))
      users.map(&.name).should eq(["deploy", "admin"]) # ordre préservé, admin ajouté
      deploy = users.find { |e| e.name == "deploy" }.not_nil!
      deploy.shell.should eq("oh-my-zsh")                                          # override gagne
      deploy.fields[YAML::Any.new("groups")].as_a.map(&.as_s).should eq(["wheel"]) # base conservé
    end

    it "tolère le mélange legacy (base) + nouvelle (override)" do
      base = YAML.parse("- name: deploy\n  groups: [wheel]\n").as_a
      override = YAML.parse("- deploy:\n    shell: oh-my-zsh\n").as_a
      deploy = Beryl::Config::Users.list(Beryl::Config::Merger.merge_users(base, override)).first
      deploy.name.should eq("deploy")
      deploy.shell.should eq("oh-my-zsh")
      deploy.fields[YAML::Any.new("groups")].as_a.map(&.as_s).should eq(["wheel"])
    end
  end
end
