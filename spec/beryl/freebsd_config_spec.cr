require "../spec_helper"

# Spec pour `Beryl::FreebsdConfig.from_yaml` et son pendant user
# `Beryl::UserSpecYaml`. L'objectif : valider la règle Aloli
# `feedback_no_silent_defaults` — un champ absent reste `nil` ou vide
# (jamais un défaut magique qui s'applique silencieusement), et les
# validations explicites (raid, install_type) lèvent tôt.
describe Beryl::FreebsdConfig do
  describe ".from_yaml" do
    it "retourne nil pour une valeur nil" do
      Beryl::FreebsdConfig.from_yaml(nil).should be_nil
    end

    it "retourne nil pour une entrée non-hash" do
      value = YAML.parse("42")
      Beryl::FreebsdConfig.from_yaml(value).should be_nil
    end

    it "parse un bloc complet" do
      yaml = <<-YAML
        hostname: loulou
        timezone: Europe/Paris
        pool_name: zroot
        swap_gb: 4
        disks:
          - /dev/sda
        raid: stripe
        install_type: distribution_sets
        users:
          - name: admin
            primary_group: www
            secondary_groups: [wheel]
            shell: /bin/csh
            ssh_keys:
              - ssh-ed25519 AAAA philippe@aloli
        packages:
          - sudo
          - zsh
        sudoers:
          - '%wheel ALL=(ALL) NOPASSWD:ALL'
        YAML

      cfg = Beryl::FreebsdConfig.from_yaml(YAML.parse(yaml)).not_nil!
      cfg.hostname.should eq("loulou")
      cfg.timezone.should eq("Europe/Paris")
      cfg.pool_name.should eq("zroot")
      cfg.swap_gb.should eq(4)
      cfg.disks.should eq(["/dev/sda"])
      cfg.raid.should eq("stripe")
      cfg.install_type.should eq("distribution_sets")
      cfg.packages.should eq(["sudo", "zsh"])
      cfg.sudoers.should eq(["%wheel ALL=(ALL) NOPASSWD:ALL"])

      cfg.users.size.should eq(1)
      u = cfg.users.first
      u.name.should eq("admin")
      u.primary_group.should eq("www")
      u.secondary_groups.should eq(["wheel"])
      u.shell.should eq("/bin/csh")
      u.ssh_keys.should eq(["ssh-ed25519 AAAA philippe@aloli"])
    end

    it "tolère les champs manquants (tout reste nil ou vide)" do
      cfg = Beryl::FreebsdConfig.from_yaml(YAML.parse("hostname: loulou")).not_nil!
      cfg.hostname.should eq("loulou")
      cfg.timezone.should be_nil
      cfg.pool_name.should be_nil
      cfg.swap_gb.should be_nil
      cfg.raid.should be_nil
      cfg.install_type.should be_nil
      cfg.disks.should be_empty
      cfg.users.should be_empty
      cfg.packages.should be_empty
      cfg.sudoers.should be_empty
    end

    it "lève sur raid invalide" do
      yaml = "raid: raid42\n"
      expect_raises(ArgumentError, /raid invalide/) do
        Beryl::FreebsdConfig.from_yaml(YAML.parse(yaml))
      end
    end

    it "accepte toutes les valeurs ZFS valides" do
      %w[stripe mirror raidz raidz2 raidz3].each do |mode|
        cfg = Beryl::FreebsdConfig.from_yaml(YAML.parse("raid: #{mode}\n")).not_nil!
        cfg.raid.should eq(mode)
      end
    end

    it "lève sur install_type invalide" do
      yaml = "install_type: tar_manual\n"
      expect_raises(ArgumentError, /install_type invalide/) do
        Beryl::FreebsdConfig.from_yaml(YAML.parse(yaml))
      end
    end

    it "accepte distribution_sets et packages" do
      %w[distribution_sets packages].each do |t|
        cfg = Beryl::FreebsdConfig.from_yaml(YAML.parse("install_type: #{t}\n")).not_nil!
        cfg.install_type.should eq(t)
      end
    end
  end
end

describe Beryl::UserSpecYaml do
  describe ".from_yaml" do
    it "exige un champ name" do
      yaml = <<-YAML
        primary_group: www
        YAML
      expect_raises(ArgumentError, /'name' requis/) do
        Beryl::UserSpecYaml.from_yaml(YAML.parse(yaml))
      end
    end

    it "lève si l'entrée n'est pas un hash" do
      expect_raises(ArgumentError, /non-hash/) do
        Beryl::UserSpecYaml.from_yaml(YAML.parse("- toto"))
      end
    end

    it "accepte un user minimal (name seul)" do
      u = Beryl::UserSpecYaml.from_yaml(YAML.parse("name: deploy\n"))
      u.name.should eq("deploy")
      u.primary_group.should be_nil
      u.secondary_groups.should be_empty
      u.shell.should be_nil
      u.ssh_keys.should be_empty
    end
  end
end

# L'intégration côté Inventory : un Host avec bloc `freebsd:` doit
# exposer son FreebsdConfig, et sans bloc renvoyer nil (pas de défaut).
describe Beryl::Inventory do
  describe "bloc freebsd: sur un hôte" do
    it "expose freebsd_config quand le bloc est présent" do
      yaml = <<-YAML
        hosts:
          loulou.aloli.fr:
            provider: ovh
            freebsd:
              hostname: loulou
              disks: [/dev/sda]
              raid: stripe
              users:
                - name: admin
                  primary_group: www
                  secondary_groups: [wheel]
                  shell: /bin/csh
                  ssh_keys: [ssh-ed25519 AAAA philippe]
        YAML
      host = Beryl::Inventory.from_yaml(yaml).find("loulou.aloli.fr")
      fcfg = host.freebsd_config.not_nil!
      fcfg.hostname.should eq("loulou")
      fcfg.disks.should eq(["/dev/sda"])
      fcfg.raid.should eq("stripe")
      fcfg.users.size.should eq(1)
      fcfg.users.first.name.should eq("admin")
    end

    it "renvoie nil quand aucun bloc freebsd: n'est fourni" do
      yaml = <<-YAML
        hosts:
          web01.aloli.fr:
            provider: ovh
        YAML
      host = Beryl::Inventory.from_yaml(yaml).find("web01.aloli.fr")
      host.freebsd_config.should be_nil
    end
  end
end
