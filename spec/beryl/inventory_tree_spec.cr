require "../spec_helper"
require "file_utils"

# Spec pour le mode arborescent de `Inventory.load` : dossier
# `groups/*.yml` + `hosts/*.yml` avec héritage + override.
# Chaque test écrit les fichiers dans un dossier temporaire et charge
# via `Inventory.load(dir)`.
describe Beryl::Inventory do
  describe ".load (mode arborescent)" do
    it "charge un host sans groupe" do
      with_tree do |dir|
        File.write(File.join(dir, "hosts", "solo.aloli.fr.yml"), <<-YAML)
        provider: ovh
        ovh:
          service_name: ns1.example
          ssh_key_name: philippe
        freebsd:
          hostname: solo
          disks: [/dev/sda]
        YAML

        inv = Beryl::Inventory.load(dir)
        inv.size.should eq(1)
        host = inv.find("solo.aloli.fr")
        host.provider.should eq("ovh")
        host.ovh_service_name.should eq("ns1.example")
        host.freebsd_config.not_nil!.hostname.should eq("solo")
      end
    end

    it "applique un groupe puis un host : host override les scalaires" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "rails-servers.yml"), <<-YAML)
        freebsd:
          timezone: Europe/Paris
          pool_name: zroot
          swap_gb: 4
          raid: stripe
        YAML

        File.write(File.join(dir, "hosts", "rails01.aloli.fr.yml"), <<-YAML)
        provider: ovh
        groups: [rails-servers]
        ovh:
          service_name: ns42.example
          ssh_key_name: philippe
        freebsd:
          hostname: rails01
          swap_gb: 8
          disks: [/dev/sda, /dev/sdb]
        YAML

        host = Beryl::Inventory.load(dir).find("rails01.aloli.fr")
        fcfg = host.freebsd_config.not_nil!
        # Venus du groupe :
        fcfg.timezone.should eq("Europe/Paris")
        fcfg.pool_name.should eq("zroot")
        fcfg.raid.should eq("stripe")
        # Overridés par le host :
        fcfg.swap_gb.should eq(8)
        fcfg.hostname.should eq("rails01")
        fcfg.disks.should eq(["/dev/sda", "/dev/sdb"])
      end
    end

    it "empile plusieurs groupes dans l'ordre (dernier gagne)" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "a.yml"), <<-YAML)
        freebsd:
          timezone: Europe/Paris
          swap_gb: 4
        YAML
        File.write(File.join(dir, "groups", "b.yml"), <<-YAML)
        freebsd:
          swap_gb: 8
          raid: mirror
        YAML
        File.write(File.join(dir, "hosts", "h.aloli.fr.yml"), <<-YAML)
        groups: [a, b]
        freebsd:
          hostname: h
          disks: [/dev/sda]
        YAML

        fcfg = Beryl::Inventory.load(dir).find("h.aloli.fr").freebsd_config.not_nil!
        fcfg.timezone.should eq("Europe/Paris") # de a
        fcfg.swap_gb.should eq(8)               # de b override a
        fcfg.raid.should eq("mirror")           # de b
        fcfg.hostname.should eq("h")            # du host
      end
    end

    it "append + dédup pour freebsd.packages (groupe fournit la base, host ajoute)" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "base.yml"), <<-YAML)
        freebsd:
          packages: [sudo, zsh, ruby]
        YAML
        File.write(File.join(dir, "hosts", "x.aloli.fr.yml"), <<-YAML)
        groups: [base]
        freebsd:
          hostname: x
          disks: [/dev/sda]
          packages: [postgresql16-server, ruby]  # ruby en doublon : dédupliqué
        YAML

        fcfg = Beryl::Inventory.load(dir).find("x.aloli.fr").freebsd_config.not_nil!
        fcfg.packages.should eq(["sudo", "zsh", "ruby", "postgresql16-server"])
      end
    end

    it "append pour freebsd.sudoers" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "base.yml"), <<-YAML)
        freebsd:
          sudoers: ['%wheel ALL=(ALL) NOPASSWD:ALL']
        YAML
        File.write(File.join(dir, "hosts", "x.aloli.fr.yml"), <<-YAML)
        groups: [base]
        freebsd:
          hostname: x
          disks: [/dev/sda]
          sudoers: ['deploy ALL=(www) NOPASSWD:/usr/local/bin/restart-app']
        YAML

        fcfg = Beryl::Inventory.load(dir).find("x.aloli.fr").freebsd_config.not_nil!
        fcfg.sudoers.size.should eq(2)
        fcfg.sudoers[0].should contain("wheel")
        fcfg.sudoers[1].should contain("deploy")
      end
    end

    it "remplace `disks` au niveau host (pas d'append pour les disques)" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "base.yml"), <<-YAML)
        freebsd:
          disks: [/dev/sda]   # ne devrait jamais être vraiment défini en groupe
        YAML
        File.write(File.join(dir, "hosts", "x.aloli.fr.yml"), <<-YAML)
        groups: [base]
        freebsd:
          hostname: x
          disks: [/dev/sdc, /dev/sdd]
        YAML

        fcfg = Beryl::Inventory.load(dir).find("x.aloli.fr").freebsd_config.not_nil!
        fcfg.disks.should eq(["/dev/sdc", "/dev/sdd"]) # override strict
      end
    end

    it "lève si un groupe listé n'existe pas" do
      with_tree do |dir|
        File.write(File.join(dir, "hosts", "bad.aloli.fr.yml"), <<-YAML)
        groups: [absent]
        freebsd:
          hostname: bad
          disks: [/dev/sda]
        YAML

        expect_raises(Exception, /groupe inconnu `absent`/) do
          Beryl::Inventory.load(dir)
        end
      end
    end

    it "lève si hosts/ n'existe pas" do
      with_tree(with_hosts: false) do |dir|
        expect_raises(Exception, /hosts.*requis/) do
          Beryl::Inventory.load(dir)
        end
      end
    end

    it "tolère l'absence de groups/ (purement hosts/)" do
      with_tree(with_groups: false) do |dir|
        File.write(File.join(dir, "hosts", "h.aloli.fr.yml"), <<-YAML)
        provider: ovh
        freebsd:
          hostname: h
          disks: [/dev/sda]
        YAML

        inv = Beryl::Inventory.load(dir)
        inv.size.should eq(1)
        inv.find("h.aloli.fr").freebsd_config.not_nil!.hostname.should eq("h")
      end
    end

    it "freebsd.users : merge-by-name (host ajoute deploy sans dupliquer admin)" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "core.yml"), <<-YAML)
        freebsd:
          users:
            - name: admin
              primary_group: www
              secondary_groups: [wheel]
              shell: /bin/csh
              ssh_keys: [ssh-ed25519 AAAA admin]
        YAML
        File.write(File.join(dir, "hosts", "srv.aloli.fr.yml"), <<-YAML)
        groups: [core]
        freebsd:
          hostname: srv
          disks: [/dev/sda]
          users:
            - name: deploy
              primary_group: www
              secondary_groups: []
              shell: /bin/csh
              ssh_keys: [ssh-ed25519 AAAA deploy]
        YAML

        users = Beryl::Inventory.load(dir).find("srv.aloli.fr").freebsd_config.not_nil!.users
        # admin vient du groupe, deploy vient du host → les deux présents.
        users.map(&.name).sort.should eq(["admin", "deploy"])
      end
    end

    it "freebsd.users : host peut redéfinir un user par nom (override admin ssh_keys)" do
      with_tree do |dir|
        File.write(File.join(dir, "groups", "core.yml"), <<-YAML)
        freebsd:
          users:
            - name: admin
              primary_group: www
              secondary_groups: [wheel]
              shell: /bin/csh
              ssh_keys: [ssh-ed25519 AAAA groupe]
        YAML
        File.write(File.join(dir, "hosts", "srv.aloli.fr.yml"), <<-YAML)
        groups: [core]
        freebsd:
          hostname: srv
          disks: [/dev/sda]
          users:
            - name: admin
              primary_group: wheel
              secondary_groups: []
              shell: /bin/sh
              ssh_keys: [ssh-ed25519 AAAA override]
        YAML

        users = Beryl::Inventory.load(dir).find("srv.aloli.fr").freebsd_config.not_nil!.users
        users.size.should eq(1) # pas de doublon admin
        admin = users.first
        admin.name.should eq("admin")
        admin.primary_group.should eq("wheel") # override host
        admin.shell.should eq("/bin/sh")       # override host
        admin.ssh_keys.should eq(["ssh-ed25519 AAAA override"])
      end
    end
  end
end

# Helper : crée un dossier temp avec sous-dossiers groups/ et hosts/,
# yield le chemin, nettoie à la fin.
private def with_tree(with_groups : Bool = true, with_hosts : Bool = true, &)
  dir = File.tempname("beryl-inventory-tree-")
  Dir.mkdir_p(dir)
  Dir.mkdir_p(File.join(dir, "groups")) if with_groups
  Dir.mkdir_p(File.join(dir, "hosts")) if with_hosts
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end
