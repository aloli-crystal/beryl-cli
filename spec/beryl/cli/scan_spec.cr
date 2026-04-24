require "../../spec_helper"
require "../../../src/beryl/cli/scan"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

private def sample_disk(name = "sda", size = 1_000_000_000_000_i64)
  Beryl::CLI::Scan::Disk.new(
    name: name, size_bytes: size, model: "Samsung SSD",
    is_ssd: true, transport: "sata",
  )
end

describe Beryl::CLI::Scan do
  describe ".render_yaml" do
    it "écrit `provider:` hérité du domaine (cas standard)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", [sample_disk], 0)
      yaml.should contain("provider: ovh")
    end

    it "surcharge via provider_override (ex: --provider=scaleway)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", [sample_disk], 0, provider_override: "scaleway")
      yaml.should contain("provider: scaleway")
      yaml.should_not contain("provider: ovh")
    end

    it "n'écrit pas `provider:` si aucun niveau n'en déclare et pas d'override" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "with-defaults-and-env"))
      host = root.resolve("serveur-neuf", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "serveur-neuf", [sample_disk], 0)
      yaml.should_not contain("provider:")
    end

    it "override CLI fonctionne même si pas de provider mergé" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "with-defaults-and-env"))
      host = root.resolve("serveur-neuf", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "serveur-neuf", [sample_disk], 0, provider_override: "hetzner")
      yaml.should contain("provider: hetzner")
    end

    it "mode multi-pool : écrit zroot (boot) + zdata (non-boot) avec leurs disques et RAID respectifs" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      pools = [
        Beryl::CLI::Scan::PoolSpec.new(name: "zroot", disks: [sample_disk("nvme0n1")], raid: 0, boot: true),
        Beryl::CLI::Scan::PoolSpec.new(name: "zdata", disks: [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc"), sample_disk("sdd")], raid: 10, boot: false),
      ]
      yaml = Beryl::CLI::Scan.render_yaml(host, "quantas", [] of Beryl::CLI::Scan::Disk, 0, pools: pools)

      # zroot en premier, avec boot: true
      yaml.should contain("zroot:")
      yaml.should contain("boot: true")
      yaml.should contain("/dev/nvme0n1")

      # zdata en second, sans boot, avec RAID 10 et 4 disques
      yaml.should contain("zdata:")
      yaml.should contain("raid: 10")
      yaml.should contain("/dev/sda")
      yaml.should contain("/dev/sdb")
      yaml.should contain("/dev/sdc")
      yaml.should contain("/dev/sdd")

      # `boot: true` ne doit apparaître QUE pour zroot (exactement un pool système)
      yaml.scan("boot: true").size.should eq(1)
    end

    it "mode single-pool (rétrocompat) : disks + raid sans pools → zroot implicite" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", [sample_disk("sda"), sample_disk("sdb")], 1)
      yaml.should contain("zroot:")
      yaml.should contain("boot: true")
      yaml.should contain("raid: 1")
      yaml.should_not contain("zdata:")
    end
  end

  describe ".parse_pool_spec" do
    it "parse `zdata:sda,sdb:10` et consomme les disques du pool courant" do
      candidates = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      pool = Beryl::CLI::Scan.parse_pool_spec("zdata:sda,sdb:10", candidates)
      pool.name.should eq("zdata")
      pool.raid.should eq(10)
      pool.boot.should be_false
      pool.disks.map(&.name).should eq(["sda", "sdb"])
    end

    it "accepte `all` pour prendre tous les disques restants" do
      candidates = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      pool = Beryl::CLI::Scan.parse_pool_spec("zdata:all:6", candidates)
      pool.disks.map(&.name).should eq(["sda", "sdb", "sdc"])
    end

    it "refuse un format sans 2 `:` (NAME:DISKS:RAID requis)" do
      expect_raises(Exception, /NAME:DISKS:RAID/) do
        Beryl::CLI::Scan.parse_pool_spec("zdata:sda", [sample_disk])
      end
    end

    it "refuse un RAID inconnu (ex: 42)" do
      expect_raises(Exception, /niveau RAID 42/) do
        Beryl::CLI::Scan.parse_pool_spec("zdata:sda:42", [sample_disk])
      end
    end

    it "refuse un disque qui n'est pas dans les candidates" do
      expect_raises(Exception, /disque inconnu : sdz/) do
        Beryl::CLI::Scan.parse_pool_spec("zdata:sdz:0", [sample_disk("sda")])
      end
    end

    it "refuse un nom de pool vide" do
      expect_raises(Exception, /nom de pool vide/) do
        Beryl::CLI::Scan.parse_pool_spec(":sda:0", [sample_disk])
      end
    end
  end

  describe ".resolve_write_target" do
    # Règle ADR-014 : le chemin d'un host YAML est
    # `<config_root>/<société>/<domaine>/<host>.yml`. Le segment
    # société est obligatoire (sinon on perd la multi-société).
    it "construit <config_root>/<société>/<domaine>/<host>.yml en mode auto" do
      result = Beryl::CLI::Scan.resolve_write_target(
        explicit: nil, auto: true,
        config_root: "/tmp/.beryl", account_name: "aloli",
        domain_name: "aloli.net", short: "loulou",
      )
      result.should eq("/tmp/.beryl/aloli/aloli.net/loulou.yml")
    end

    it "retourne le chemin explicite quand fourni (write_path gagne)" do
      result = Beryl::CLI::Scan.resolve_write_target(
        explicit: "/custom/path.yml", auto: true,
        config_root: "/tmp/.beryl", account_name: "aloli",
        domain_name: "aloli.net", short: "loulou",
      )
      result.should eq("/custom/path.yml")
    end

    it "retourne nil quand ni --write ni --write-to ne sont passés" do
      result = Beryl::CLI::Scan.resolve_write_target(
        explicit: nil, auto: false,
        config_root: "/tmp/.beryl", account_name: "aloli",
        domain_name: "aloli.net", short: "loulou",
      )
      result.should be_nil
    end
  end

  describe ".rerun_with_write" do
    # Le mode suggestion affiche le YAML à l'écran et propose la commande
    # à relancer pour que beryl écrive lui-même le fichier. Standard
    # Aloli : toute interaction qui suggère un état suivant doit
    # proposer la commande précise à copier-coller.
    it "ajoute --write quand il n'est pas déjà dans les args" do
      args = ["aloli/ns3156789.ip-51-83-6.eu", "--hostname=loulou", "--raid=0"]
      result = Beryl::CLI::Scan.rerun_with_write(args, "loulou")
      result.should contain("--write")
      result.should contain("aloli/ns3156789.ip-51-83-6.eu")
      result.should contain("--hostname=loulou")
      result.should contain("--raid=0")
    end

    it "n'ajoute pas --hostname si déjà présent (forme longue)" do
      args = ["host", "--hostname=loulou"]
      Beryl::CLI::Scan.rerun_with_write(args, "loulou").should_not contain("--hostname=loulou --hostname=loulou")
    end

    it "n'ajoute pas --hostname si déjà présent (forme courte -H)" do
      args = ["host", "-H", "loulou"]
      result = Beryl::CLI::Scan.rerun_with_write(args, "loulou")
      # La forme courte d'origine reste, pas de conversion vers --hostname
      result.scan("--hostname=").size.should eq(0)
    end

    it "ajoute --hostname=<short> quand absent (évite le re-prompt)" do
      args = ["host", "--raid=0"]
      Beryl::CLI::Scan.rerun_with_write(args, "loulou").should contain("--hostname=loulou")
    end

    it "ne duplique pas --write si déjà passé" do
      args = ["host", "--write"]
      result = Beryl::CLI::Scan.rerun_with_write(args, "loulou")
      result.scan("--write").size.should eq(1)
    end

    it "retire --dry-run / -n s'ils étaient présents" do
      args = ["host", "--dry-run"]
      Beryl::CLI::Scan.rerun_with_write(args, "loulou").should_not contain("--dry-run")
    end
  end
end
