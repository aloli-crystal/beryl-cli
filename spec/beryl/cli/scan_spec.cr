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
