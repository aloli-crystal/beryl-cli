require "../../spec_helper"
require "../../../src/beryl/cli/scan"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

private def sample_disk(name = "sda", size = 1_000_000_000_000_i64)
  Beryl::CLI::Scan::Disk.new(
    name: name, size_bytes: size, model: "Samsung SSD",
    is_ssd: true, transport: "sata",
  )
end

private def single_zroot(disks, raid = 0)
  [Beryl::CLI::Scan::PoolSpec.zroot(disks, raid)]
end

describe Beryl::CLI::Scan do
  describe ".render_yaml" do
    it "écrit `provider:` hérité du domaine (cas standard)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", single_zroot([sample_disk]))
      yaml.should contain("provider: ovh")
    end

    it "écrit ovh.commercial_name + bloc hardware: depuis les overrides OVH" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      hw = Beryl::HardwareSpec.new(cpu: "AMD EPYC 4344P", cores: 8, threads: 16,
        ram_gb: 64, disks: ["2 x 960 GB SSD", "4 x 7680 GB SSD"], raid: "9361-4i")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", single_zroot([sample_disk]),
        ovh_service_name_override: "ns1.eu", ovh_commercial_override: "Advance-2",
        ovh_hardware_override: hw)
      yaml.should contain("commercial_name: Advance-2")
      yaml.should contain("hardware:")
      yaml.should contain("cpu: AMD EPYC 4344P")
      yaml.should contain("ram_gb: 64")
      yaml.should contain("raid: 9361-4i")
      yaml.should contain("- 2 x 960 GB SSD")
    end

    it "surcharge via provider_override (ex: --provider=scaleway)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", single_zroot([sample_disk]), provider_override: "scaleway")
      yaml.should contain("provider: scaleway")
      yaml.should_not contain("provider: ovh")
    end

    it "n'écrit pas `provider:` si aucun niveau n'en déclare et pas d'override" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "with-defaults-and-env"))
      host = root.resolve("serveur-neuf", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "serveur-neuf", single_zroot([sample_disk]))
      yaml.should_not contain("provider:")
    end

    it "override CLI fonctionne même si pas de provider mergé" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "with-defaults-and-env"))
      host = root.resolve("serveur-neuf", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "serveur-neuf", single_zroot([sample_disk]), provider_override: "hetzner")
      yaml.should contain("provider: hetzner")
    end

    it "multi-pool : zroot (boot) + zdata (data, mountpoint /data) avec leurs disques et RAID respectifs" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      pools = [
        Beryl::CLI::Scan::PoolSpec.zroot([sample_disk("nvme0n1")], 0),
        Beryl::CLI::Scan::PoolSpec.data("data",
          [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc"), sample_disk("sdd")], 10),
      ]
      yaml = Beryl::CLI::Scan.render_yaml(host, "quantas", pools)

      # zroot en premier, avec boot: true, pas de mountpoint
      yaml.should contain("zroot:")
      yaml.should contain("boot: true")
      yaml.should contain("/dev/nvme0n1")

      # zdata en second, sans boot, avec mountpoint /data, RAID 10, 4 disques
      yaml.should contain("zdata:")
      yaml.should contain("mountpoint: /data")
      yaml.should contain("raid: 10")
      yaml.should contain("/dev/sda")
      yaml.should contain("/dev/sdb")
      yaml.should contain("/dev/sdc")
      yaml.should contain("/dev/sdd")

      # `boot: true` ne doit apparaître QUE pour zroot (exactement un pool système)
      yaml.scan("boot: true").size.should eq(1)
    end

    it "zroot n'a PAS de mountpoint dans le YAML (le root-fs est géré par l'installeur)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", single_zroot([sample_disk]))
      yaml.should_not contain("mountpoint:")
    end

    it "single pool zroot : raid passé dans le PoolSpec est préservé" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "multi-provider-domain"))
      host = root.resolve("loulou", domain_hint: "aloli.net")
      yaml = Beryl::CLI::Scan.render_yaml(host, "loulou", single_zroot([sample_disk("sda"), sample_disk("sdb")], 1))
      yaml.should contain("zroot:")
      yaml.should contain("boot: true")
      yaml.should contain("raid: 1")
      yaml.should_not contain("zdata:")
    end
  end

  describe ".resolve_host_ipv4" do
    it "renvoie l'IP telle quelle si déjà une IPv4 (pas de DNS)" do
      Beryl::CLI::Scan.resolve_host_ipv4("51.210.0.22").should eq("51.210.0.22")
    end
  end

  describe ".merge_scan_into" do
    it "rafraîchit les champs scan et préserve les ajouts de l'opérateur" do
      existing = <<-YAML
        provider: ovh
        ovh:
          service_name: ns-old.eu
        proxy_jump: admin@zsbg.popi.net
        apply_recipes:
          - sshd-vrack-only: {}
        freebsd:
          hostname: bi
          users: [admin, deploy]
          zfs:
            zroot:
              boot: true
              raid: 0
              disks: [/dev/nvme0n1]
        YAML
      scan_yaml = <<-YAML
        provider: ovh
        ovh:
          service_name: ns-new.eu
        freebsd:
          hostname: bi
          zfs:
            zroot:
              boot: true
              raid: 1
              disks:
                - /dev/nvme0n1
                - /dev/nvme1n1
        YAML
      merged = Beryl::CLI::Scan.merge_scan_into(existing, scan_yaml)
      parsed = YAML.parse(merged)
      # préservés
      parsed["apply_recipes"].as_a.size.should eq(1)
      parsed["proxy_jump"].as_s.should eq("admin@zsbg.popi.net")
      parsed["freebsd"]["users"].as_a.size.should eq(2)
      # rafraîchis par scan
      parsed["ovh"]["service_name"].as_s.should eq("ns-new.eu")
      parsed["freebsd"]["zfs"]["zroot"]["raid"].as_i.should eq(1)
      parsed["freebsd"]["zfs"]["zroot"]["disks"].as_a.size.should eq(2)
    end
  end

  describe ".parse_pool_spec" do
    it "parse `data:sda,sdb:10` → pool zdata, mountpoint /data, non-boot" do
      candidates = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      pool = Beryl::CLI::Scan.parse_pool_spec("data:sda,sdb:10", candidates)
      pool.name.should eq("zdata")
      pool.mountpoint.should eq("/data")
      pool.raid.should eq(10)
      pool.boot.should be_false
      pool.disks.map(&.name).should eq(["sda", "sdb"])
    end

    it "accepte `all` pour prendre tous les disques restants" do
      candidates = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      pool = Beryl::CLI::Scan.parse_pool_spec("data:all:6", candidates)
      pool.disks.map(&.name).should eq(["sda", "sdb", "sdc"])
    end

    it "refuse un format sans 2 `:` (SHORTNAME:DISKS:RAID requis)" do
      expect_raises(ArgumentError, /SHORTNAME:DISKS:RAID/) do
        Beryl::CLI::Scan.parse_pool_spec("data:sda", [sample_disk])
      end
    end

    it "refuse un RAID inconnu (ex: 42)" do
      expect_raises(ArgumentError, /niveau RAID 42/) do
        Beryl::CLI::Scan.parse_pool_spec("data:sda:42", [sample_disk])
      end
    end

    it "refuse un RAID non-numérique (ex: abc)" do
      expect_raises(ArgumentError, /RAID invalide : "abc"/) do
        Beryl::CLI::Scan.parse_pool_spec("data:sda:abc", [sample_disk])
      end
    end

    it "refuse un disque qui n'est pas dans les candidates, en listant ceux disponibles" do
      ex = expect_raises(ArgumentError, /disque inconnu : sdz/) do
        Beryl::CLI::Scan.parse_pool_spec("data:sdz:0", [sample_disk("sda"), sample_disk("sdb")])
      end
      ex.message.to_s.should contain("disques disponibles : sda, sdb")
    end

    it "refuse un nom de pool vide" do
      expect_raises(ArgumentError, /nom de pool vide/) do
        Beryl::CLI::Scan.parse_pool_spec(":sda:0", [sample_disk])
      end
    end

    it "refuse un nom avec des caractères invalides (majuscules, espaces, tirets, majuscules, préfixe z)" do
      ["Data", "da ta", "my-data", "1data", "data!"].each do |bad|
        expect_raises(ArgumentError, /nom invalide/) do
          Beryl::CLI::Scan.parse_pool_spec("#{bad}:sda:0", [sample_disk])
        end
      end
    end

    it "refuse `root` (réservé au pool boot zroot)" do
      expect_raises(ArgumentError, /`root` est réservé/) do
        Beryl::CLI::Scan.parse_pool_spec("root:sda:0", [sample_disk])
      end
    end

    it "refuse les dossiers système FreeBSD (via validate_pool_name!)" do
      %w[etc usr var bin boot tmp home lib sbin].each do |reserved|
        expect_raises(ArgumentError, /nom réservé/) do
          Beryl::CLI::Scan.parse_pool_spec("#{reserved}:sda:0", [sample_disk])
        end
      end
    end
  end

  describe "PoolSpec.data" do
    it "construit un pool data avec préfixe z et mountpoint /" do
      pool = Beryl::CLI::Scan::PoolSpec.data("data", [sample_disk("sda")], 0)
      pool.name.should eq("zdata")
      pool.mountpoint.should eq("/data")
      pool.boot.should be_false
    end

    it "préserve le nom court tel quel (cache → zcache, /cache)" do
      pool = Beryl::CLI::Scan::PoolSpec.data("cache", [sample_disk], 0)
      pool.name.should eq("zcache")
      pool.mountpoint.should eq("/cache")
    end
  end

  describe "PoolSpec.zroot" do
    it "nom fixe `zroot`, boot: true, mountpoint nil (géré par l'installeur)" do
      pool = Beryl::CLI::Scan::PoolSpec.zroot([sample_disk], 0)
      pool.name.should eq("zroot")
      pool.boot.should be_true
      pool.mountpoint.should be_nil
    end
  end

  describe ".validate_pool_name!" do
    it "accepte les noms courts conventionnels (sans préfixe z)" do
      %w[data cache backup logs archive01 my_data save web].each do |ok|
        # doit passer sans raise
        Beryl::CLI::Scan.validate_pool_name!(ok)
      end
    end

    it "refuse majuscules, espaces, tirets, et début par un chiffre" do
      ["Data", "my data", "my-data", "1data", "data!", " ", "", "DATA"].each do |bad|
        expect_raises(ArgumentError, /nom invalide/) do
          Beryl::CLI::Scan.validate_pool_name!(bad)
        end
      end
    end

    # Sécurité critique : un pool data dont le nom court correspond
    # à un dossier FreeBSD de premier niveau écraserait l'OS au
    # montage. Refus ferme.
    it "refuse les noms qui écraseraient un dossier système FreeBSD" do
      # Liste tirée d'un `ls -l /` sur FreeBSD 15.
      %w[bin boot dev etc home lib libexec media mnt net
        proc rescue sbin sys tmp usr var zroot].each do |reserved|
        ex = expect_raises(ArgumentError, /nom réservé/) do
          Beryl::CLI::Scan.validate_pool_name!(reserved)
        end
        ex.message.to_s.should contain("/#{reserved}")
        ex.message.to_s.should contain("casserait l'OS")
      end
    end
  end

  describe ".validate_raid!" do
    it "accepte les niveaux supportés" do
      [0, 1, 5, 6, 7, 10].each do |n|
        Beryl::CLI::Scan.validate_raid!(n.to_s).should eq(n)
      end
    end

    it "refuse une valeur non-numérique avec message explicite" do
      ex = expect_raises(ArgumentError, /RAID invalide/) do
        Beryl::CLI::Scan.validate_raid!("abc")
      end
      ex.message.to_s.should contain("0, 1, 5, 6, 7, 10")
    end

    it "refuse un niveau RAID inconnu (ex: 2, 42)" do
      [2, 3, 4, 8, 42].each do |n|
        expect_raises(ArgumentError, /RAID #{n} non supporté/) do
          Beryl::CLI::Scan.validate_raid!(n.to_s)
        end
      end
    end

    it "accepte des espaces autour (strip)" do
      Beryl::CLI::Scan.validate_raid!("  1 ").should eq(1)
    end
  end

  describe ".disk_inventory_warning" do
    # Cas in vivo ns3207652 : 2 NVMe + 2 HDD déclarés par OVH, mais un NVMe
    # mort n'est pas énuméré → l'OS ne voit qu'1 NVMe + 2 HDD.
    it "alerte quand l'OS voit moins de disques que l'inventaire provider" do
      inv = Beryl::DiskInventory.new(flash: 2, spinning: 2, total: 4)
      detected = [
        Beryl::CLI::Scan::Disk.new(name: "nvme0n1", size_bytes: 512_000_000_000_i64, model: "Samsung", is_ssd: true, transport: "nvme"),
        Beryl::CLI::Scan::Disk.new(name: "sda", size_bytes: 6_000_000_000_000_i64, model: "HGST", is_ssd: false, transport: "sata"),
        Beryl::CLI::Scan::Disk.new(name: "sdb", size_bytes: 6_000_000_000_000_i64, model: "HGST", is_ssd: false, transport: "sata"),
      ]
      msg = Beryl::CLI::Scan.disk_inventory_warning(inv, detected)
      msg.should_not be_nil
      msg.not_nil!.should contain("déclare 4")
      msg.not_nil!.should contain("n'en voit que 3")
      msg.not_nil!.should contain("DÉFAILLANT")
    end

    it "ne dit rien quand l'OS voit tous les disques déclarés" do
      inv = Beryl::DiskInventory.new(flash: 2, spinning: 2, total: 4)
      detected = [
        Beryl::CLI::Scan::Disk.new(name: "nvme0n1", size_bytes: 512_000_000_000_i64, model: "x", is_ssd: true, transport: "nvme"),
        Beryl::CLI::Scan::Disk.new(name: "nvme1n1", size_bytes: 512_000_000_000_i64, model: "x", is_ssd: true, transport: "nvme"),
        Beryl::CLI::Scan::Disk.new(name: "sda", size_bytes: 6_000_000_000_000_i64, model: "x", is_ssd: false, transport: "sata"),
        Beryl::CLI::Scan::Disk.new(name: "sdb", size_bytes: 6_000_000_000_000_i64, model: "x", is_ssd: false, transport: "sata"),
      ]
      Beryl::CLI::Scan.disk_inventory_warning(inv, detected).should be_nil
    end

    it "ne dit rien si l'OS voit autant ou plus de disques que déclaré" do
      inv = Beryl::DiskInventory.new(flash: 1, spinning: 0, total: 1)
      Beryl::CLI::Scan.disk_inventory_warning(inv, [sample_disk("nvme0n1")]).should be_nil
    end

    # INFRA-3 : 4x960 SSD derrière un MegaRAID → 1 volume logique sda.
    it "explique (sans alarmer) quand un contrôleur RAID matériel masque les disques" do
      inv = Beryl::DiskInventory.new(flash: 4, spinning: 0, total: 4)
      detected = [
        Beryl::CLI::Scan::Disk.new(name: "sda", size_bytes: 1_920_000_000_000_i64, model: "AVAGO MR9363-4i", is_ssd: false, transport: ""),
      ]
      msg = Beryl::CLI::Scan.disk_inventory_warning(inv, detected)
      msg.should_not be_nil
      msg.not_nil!.should contain("RAID matériel")
      msg.not_nil!.should_not contain("DÉFAILLANT")
    end
  end

  describe "Disk#hardware_raid?" do
    it "reconnaît un volume de contrôleur RAID matériel (MegaRAID)" do
      Beryl::CLI::Scan::Disk.new(name: "sda", size_bytes: 1_920_000_000_000_i64, model: "AVAGO MR9363-4i", is_ssd: false, transport: "").hardware_raid?.should be_true
    end
    it "ne confond pas un SSD/NVMe normal" do
      Beryl::CLI::Scan::Disk.new(name: "nvme0n1", size_bytes: 512_000_000_000_i64, model: "Samsung MZVL2512HCJQ", is_ssd: true, transport: "nvme").hardware_raid?.should be_false
    end
  end

  describe ".resolve_disk_selection" do
    it "accepte `all` (casse ignorée) et retourne tous les disques" do
      disks = [sample_disk("sda"), sample_disk("sdb")]
      Beryl::CLI::Scan.resolve_disk_selection(disks, "all").size.should eq(2)
      Beryl::CLI::Scan.resolve_disk_selection(disks, "ALL").size.should eq(2)
    end

    it "résout par index 1-based" do
      disks = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      result = Beryl::CLI::Scan.resolve_disk_selection(disks, "1,3")
      result.map(&.name).should eq(["sda", "sdc"])
    end

    it "résout par nom" do
      disks = [sample_disk("sda"), sample_disk("sdb")]
      result = Beryl::CLI::Scan.resolve_disk_selection(disks, "sdb")
      result.map(&.name).should eq(["sdb"])
    end

    it "index hors bornes : message avec la plage valide" do
      disks = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      ex = expect_raises(ArgumentError, /index disque invalide : 42/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "42")
      end
      ex.message.to_s.should contain("attendu : 1 à 3")
    end

    it "index 0 refusé (les indexes sont 1-based dans le prompt)" do
      disks = [sample_disk("sda")]
      expect_raises(ArgumentError, /index disque invalide : 0/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "0")
      end
    end

    it "nom inconnu : message avec la liste des disponibles" do
      disks = [sample_disk("sda"), sample_disk("sdb")]
      ex = expect_raises(ArgumentError, /disque inconnu : sdz/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "sdz")
      end
      ex.message.to_s.should contain("disques disponibles : sda, sdb")
    end

    it "doublon dans la sélection (index et nom pointent vers le même) : refusé" do
      disks = [sample_disk("sda"), sample_disk("sdb")]
      expect_raises(ArgumentError, /doublon/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "1,sda")
      end
    end

    it "doublon direct (ex: 1,1) : refusé" do
      disks = [sample_disk("sda"), sample_disk("sdb")]
      expect_raises(ArgumentError, /doublon/) do
        Beryl::CLI::Scan.resolve_disk_selection(disks, "1,1")
      end
    end

    it "mix index + nom dans la même sélection" do
      disks = [sample_disk("sda"), sample_disk("sdb"), sample_disk("sdc")]
      result = Beryl::CLI::Scan.resolve_disk_selection(disks, "1,sdc")
      result.map(&.name).should eq(["sda", "sdc"])
    end

    it "réponse vide = Aborted (l'opérateur refuse explicitement)" do
      expect_raises(Beryl::CLI::Scan::Aborted) do
        Beryl::CLI::Scan.resolve_disk_selection([sample_disk], "")
      end
    end

    it "tous les tokens en whitespace = Aborted (après strip : résultat vide)" do
      # `,, ,` → après strip et reject(empty), il reste 0 tokens → Aborted
      expect_raises(Beryl::CLI::Scan::Aborted) do
        Beryl::CLI::Scan.resolve_disk_selection([sample_disk], ",, ,")
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
        config_root: "/tmp/.config/beryl", account_name: "aloli",
        domain_name: "aloli.net", short: "loulou",
      )
      result.should eq("/tmp/.config/beryl/aloli/aloli.net/loulou.host.yml")
    end

    it "retourne le chemin explicite quand fourni (write_path gagne)" do
      result = Beryl::CLI::Scan.resolve_write_target(
        explicit: "/custom/path.yml", auto: true,
        config_root: "/tmp/.config/beryl", account_name: "aloli",
        domain_name: "aloli.net", short: "loulou",
      )
      result.should eq("/custom/path.yml")
    end

    it "retourne nil quand ni --write ni --write-to ne sont passés" do
      result = Beryl::CLI::Scan.resolve_write_target(
        explicit: nil, auto: false,
        config_root: "/tmp/.config/beryl", account_name: "aloli",
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
