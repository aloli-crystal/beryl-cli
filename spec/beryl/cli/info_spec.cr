require "../../spec_helper"
require "../../../src/beryl/cli/info"

private FIXTURES = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config"))

describe Beryl::CLI::Info do
  describe ".scoped_hosts" do
    it "résout société, nom court ET la forme chemin société/host" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "direct-hosts"))
      Beryl::CLI::Info.scoped_hosts(root, "initech").map(&.short_name).should contain("loulou")
      Beryl::CLI::Info.scoped_hosts(root, "loulou").map(&.short_name).should eq(["loulou"])
      Beryl::CLI::Info.scoped_hosts(root, "initech/loulou").map(&.short_name).should eq(["loulou"])
      Beryl::CLI::Info.scoped_hosts(root, "initech/inconnu").should be_empty
    end
  end

  describe ".build_adoc" do
    it "produit un doc AsciiDoc sectionné (synthèse + matériel + réseau)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      out = Beryl::CLI::Info.build_adoc([root.resolve("infohw")], "test")
      out.should contain("= Inventaire des serveurs — test")
      out.should contain(":pdf-page-layout: landscape") # paysage
      out.should_not contain(":toc:")                   # pas de table des matières
      out.should contain(":toc!:")                      # TOC neutralisé (sinon injecté par la user config)
      out.should contain(":!x-title-page-toc:")         # …y compris la variante page de garde
      out.should contain("== Synthèse")
      out.should contain("| Serveurs | 1") # synthèse = tableau
      out.should contain("== Matériel")
      out.should contain("| Host | Rôle | Nom commercial | Datacentre | Baie | CPU | RAM | Disques | Prix/mois")
      out.should contain("| GRA3 | 16RA09 |")         # datacentre en capitales, avant la baie
      out.should contain("| infohw | apps-crystal |") # rôle fonctionnel
      out.should contain("16RA09")                    # rack
      out.should contain("== Réseau")
      out.should contain("| Host | IPv4 publique | IPv6 publique | vRack | Accès SSH")
      out.should contain("1.2.3.4")
      out.should contain("2001:db8::1")
      out.should contain("89.99 €")                   # prix lu depuis un NOMBRE YAML (pas une chaîne)
      out.should_not contain("== Utilisation disque") # pas d'usage fourni
    end

    it "alerte sur les serveurs co-localisés (même baie)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      hosts = ["infohw", "infohw2"].map { |n| root.resolve(n) }
      out = Beryl::CLI::Info.build_adoc(hosts, "test")
      out.should contain("[WARNING]")
      out.should contain("CO-LOCALISÉS")
      out.should contain("*16RA09* : infohw, infohw2")
      out.should contain(" +\n") # chaque baie sur sa ligne (saut forcé AsciiDoc)
    end

    it "ajoute la section utilisation disque quand l'usage est fourni (colonne % libre)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      usage = {} of String => Array(Beryl::CLI::Info::UsageRow)?
      usage[h.fqdn] = [Beryl::CLI::Info::UsageRow.new("zroot", "460G", "12G", "448G", "97%")]
      out = Beryl::CLI::Info.build_adoc([h], "test", usage)
      out.should contain("== Utilisation disque")
      out.should contain("| Host | OS | Volume | Taille | Utilisé | Libre | % libre")
      out.should contain("| infohw | — | zroot | 460G | 12G | 448G | 97%") # OS=— sans os_map
      out.should_not contain("SOUS 10")                                    # 97% libre → pas d'alerte saturation
    end

    it "place l'OS live en colonne 2 du tableau d'utilisation (chapitre 4)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      usage = {} of String => Array(Beryl::CLI::Info::UsageRow)?
      usage[h.fqdn] = [Beryl::CLI::Info::UsageRow.new("zroot", "460G", "12G", "448G", "97%")]
      os_map = {h.fqdn => "FreeBSD 15.0-RELEASE-p10"}
      out = Beryl::CLI::Info.build_adoc([h], "test", usage, os_map)
      out.should contain("| infohw | FreeBSD 15.0-RELEASE-p10 | zroot |")
    end

    it "alerte sur les volumes sous 10% de libre" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      usage = {} of String => Array(Beryl::CLI::Info::UsageRow)?
      usage[h.fqdn] = [
        Beryl::CLI::Info::UsageRow.new("zroot", "460G", "440G", "20G", "5%"),
        Beryl::CLI::Info::UsageRow.new("zdata", "14T", "1T", "13T", "92%"),
      ]
      out = Beryl::CLI::Info.build_adoc([h], "test", usage)
      out.should contain("[WARNING]")
      out.should contain("SOUS 10")
      out.should contain("*infohw* / zroot : 5% libre") # nom serveur en GRAS, volume saturé
      out.should_not contain("zdata : 92%")             # le volume sain n'est pas listé
    end
  end

  describe ".ipv4_sort_key" do
    it "trie les IP du vRack octet par octet (.4 < .19 < .39)" do
      keys = %w[192.168.42.39 192.168.42.19 192.168.42.4].map { |ip| Beryl::CLI::Info.ipv4_sort_key(ip) }
      keys.sort.should eq([192168042004_i64, 192168042019_i64, 192168042039_i64])
    end

    it "sans adresse ou illisible : -1 (en tête)" do
      Beryl::CLI::Info.ipv4_sort_key(nil).should eq(-1)
      Beryl::CLI::Info.ipv4_sort_key("—").should eq(-1)
      Beryl::CLI::Info.ipv4_sort_key("1.2.3.256").should eq(-1)
    end
  end

  describe ".ipv6_sort_key" do
    it "forme complète, triable comme du texte" do
      Beryl::CLI::Info.ipv6_sort_key("2001:41d0:364:4100::1").should eq("2001:41d0:0364:4100:0000:0000:0000:0001")
      Beryl::CLI::Info.ipv6_sort_key("fe80::1").should eq("fe80:0000:0000:0000:0000:0000:0000:0001")
      Beryl::CLI::Info.ipv6_sort_key("2001:db8:0:1:2:3:4:5").should eq("2001:0db8:0000:0001:0002:0003:0004:0005")
    end

    it "l'ordre suit les adresses, pas leur écriture abrégée" do
      a = Beryl::CLI::Info.ipv6_sort_key("2001:41d0:303:9cd0::1")
      b = Beryl::CLI::Info.ipv6_sort_key("2001:41d0:1000::1")
      (a < b).should be_true
    end

    it "sans adresse : chaîne vide" do
      Beryl::CLI::Info.ipv6_sort_key(nil).should eq("")
    end
  end

  describe ".size_bytes" do
    it "convertit les tailles humaines en octets (tri numérique correct)" do
      Beryl::CLI::Info.size_bytes("14T").should be > Beryl::CLI::Info.size_bytes("460G")
      Beryl::CLI::Info.size_bytes("512K").should eq(512_i64 * 1024)
      Beryl::CLI::Info.size_bytes("8.0G").should eq((8.0 * 1024 ** 3).to_i64)
      Beryl::CLI::Info.size_bytes("—").should eq(0_i64)
    end
  end

  describe ".hesc" do
    it "échappe les caractères HTML" do
      Beryl::CLI::Info.hesc(%(<a href="x">&)).should eq("&lt;a href=&quot;x&quot;&gt;&amp;")
    end
  end

  describe ".info_dir" do
    it "société → <config>/<société>/info ; domaine → <config>/<société>/<domaine>/info" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw") # account=initech, domain=initech.example
      Beryl::CLI::Info.info_dir("/cfg", "initech", [h]).should eq("/cfg/initech/info")
      Beryl::CLI::Info.info_dir("/cfg", "initech.example", [h]).should eq("/cfg/initech/initech.example/info")
    end
  end

  describe ".build_html_index" do
    it "index triable : date, lien serveur, tableaux sortable, alerte saturation" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      usage = {} of String => Array(Beryl::CLI::Info::UsageRow)?
      usage[h.fqdn] = [Beryl::CLI::Info::UsageRow.new("zroot", "460G", "440G", "20G", "5%")]
      os_map = {h.fqdn => "FreeBSD 15.0-RELEASE-p10"}
      out = Beryl::CLI::Info.build_html_index([h], "test", usage, "19/06/2026 16h00", os_map)
      out.should contain("<!DOCTYPE html>")
      out.should contain("Document généré le 19/06/2026 16h00.")
      out.should contain(%(class="sortable"))
      out.should contain(%(<a href="infohw.html">infohw</a>)) # lien vers la page serveur
      out.should contain(%(data-sort=))                       # tri numérique
      out.should contain("<th>OS</th>")                       # OS en colonne 2 (chapitre 4)
      out.should contain("FreeBSD 15.0-RELEASE-p10")          # valeur OS live
      out.should contain("SOUS 10 %")                         # alerte saturation
      out.should contain(%(class="low"))                      # ligne saturée surlignée
    end
  end

  describe ".build_html_host" do
    it "page serveur : fiche + usage + retour index" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      rows = [Beryl::CLI::Info::UsageRow.new("zroot", "460G", "12G", "448G", "97%")]
      out = Beryl::CLI::Info.build_html_host(h, rows, true, "19/06/2026 16h00")
      out.should contain("<h1>infohw.initech.example</h1>")
      out.should contain("← Inventaire")
      out.should contain("Service OVH")
      out.should contain("zroot")
      out.should contain("<tr><th>Rôle</th><td>apps-crystal</td></tr>")
      out.should contain("<h2>Notes</h2>\n<p class=\"notes\">Applications marteen.\nDisque à surveiller.</p>")
    end

    it "page serveur : « injoignable » quand l'usage est nil (demandé)" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      out = Beryl::CLI::Info.build_html_host(h, nil, true, "x")
      out.should contain("injoignable")
    end

    it "affiche l'OS LIVE (version + patch) déduit du serveur quand fourni" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw")
      out = Beryl::CLI::Info.build_html_host(h, nil, true, "x", "FreeBSD 15.0-RELEASE-p10")
      out.should contain("FreeBSD 15.0-RELEASE-p10 (live)")
      out.should_not contain("<td>freebsd</td>") # plus l'OS théorique du YAML
    end
  end

  describe ".ovh_block" do
    it "quote l'IPv6 → relisible par YAML (même finissant par ::)" do
      block = Beryl::CLI::Info.ovh_block("ns1.eu", "Advance-2", "16RA09", "1.2.3.4", "2001:db8::", "89.99")
      yaml = block.join("\n") + "\n"
      parsed = YAML.parse(yaml)
      parsed["ovh"]["ipv6"].as_s.should eq("2001:db8::")
      parsed["ovh"]["ipv4"].as_s.should eq("1.2.3.4")
      parsed["ovh"]["rack"].as_s.should eq("16RA09")
    end

    it "écrit les clés par ordre alphabétique (comme beryl fmt)" do
      block = Beryl::CLI::Info.ovh_block("ns1.eu", "GAME-1", "S355A02", "1.2.3.4", "2001:db8::1", "99.99", "fe80::1", "sbg1")
      keys = block[1..].map { |l| l.strip.split(':').first }
      keys.should eq(%w[commercial_name datacenter ipv4 ipv6 ipv6_gateway price_eur rack service_name])
    end

    it "ajoute le bloc IPv6 d'OVH, quoté, entre ipv6 et ipv6_gateway" do
      block = Beryl::CLI::Info.ovh_block("ns1.eu", nil, nil, "1.2.3.4", "2001:db8:1200::1", nil, "fe80::1", nil, "2001:db8:1200::/56")
      keys = block[1..].map { |l| l.strip.split(':').first }
      keys.should eq(%w[ipv4 ipv6 ipv6_block ipv6_gateway service_name])
      YAML.parse(block.join("\n") + "\n")["ovh"]["ipv6_block"].as_s.should eq("2001:db8:1200::/56")
    end

    it "ajoute la passerelle IPv6 d'OVH, quotée" do
      block = Beryl::CLI::Info.ovh_block("ns1.eu", nil, nil, "1.2.3.4", "2001:db8:0:1::1", nil, "2001:db8:0:ff:ff:ff:ff:ff")
      YAML.parse(block.join("\n") + "\n")["ovh"]["ipv6_gateway"].as_s.should eq("2001:db8:0:ff:ff:ff:ff:ff")
    end
  end

  describe ".usage_attempts" do
    it "vise l'IP vRack (ssh_host) via le bastion pour un host CACHÉ — les 2 modes" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("clientvm") # proxy_jump posé → caché
      h.hidden?.should be_true
      [true, false].each do |sys|
        targets = Beryl::CLI::Info.usage_attempts(h, sys).map { |t| t[1] }
        targets.should eq([h.ssh_host, h.ssh_host]) # IP vRack/ssh_host, PAS le FQDN public
      end
    end

    it "vise le FQDN D'ABORD puis le nom OVH (repli) pour un host OVH à route directe" do
      root = Beryl::Config::Root.load(File.join(FIXTURES, "ssh-host-override"))
      h = root.resolve("infohw") # pas de proxy_jump → route directe, service_name OVH
      h.hidden?.should be_false
      targets = Beryl::CLI::Info.usage_attempts(h, true).map { |t| t[1] }
      targets.first.should eq(h.fqdn)    # FQDN préféré
      targets.last.should eq(h.ssh_host) # nom OVH en repli
      targets.should contain(h.ssh_host)
      h.fqdn.should_not eq(h.ssh_host) # (sanity : les deux diffèrent bien)
    end
  end

  describe ".parse_zfs_roots" do
    it "une ligne par pool, libre = AVAIL de ZFS (cas réel zora), colonne % = LIBRE" do
      txt = "zroot\t958817615872\t23085449216\nzdata\t5497558138880\t9895604649984"
      rows = Beryl::CLI::Info.parse_zfs_roots(txt)
      rows.map(&.label).should eq(["zroot", "zdata"])
      rows[0].size.should eq("914G")
      rows[0].used.should eq("893G")
      rows[0].free.should eq("21.5G")
      rows[0].pct.should eq("2%")
      rows[1].pct.should eq("64%")
    end

    it "ligne illisible ignorée" do
      Beryl::CLI::Info.parse_zfs_roots("zroot\t-\t12").should be_empty
    end
  end

  describe ".zfs_size" do
    it "forme de zfs list -h" do
      Beryl::CLI::Info.zfs_size(512_i64).should eq("512B")
      Beryl::CLI::Info.zfs_size(2_523_293_286_i64).should eq("2.35G")
      Beryl::CLI::Info.zfs_size(1_099_511_627_776_i64).should eq("1.00T")
    end
  end

  describe ".free_pct" do
    it "convertit l'utilisé en libre" do
      Beryl::CLI::Info.free_pct("0%").should eq("100%")
      Beryl::CLI::Info.free_pct("100%").should eq("0%")
      Beryl::CLI::Info.free_pct("36%").should eq("64%")
    end
  end

  describe ".sort_volumes" do
    it "zroot d'abord, puis les autres pools par ordre alpha" do
      mk = ->(n : String) { Beryl::CLI::Info::UsageRow.new(n, "1T", "0", "1T", "100%") }
      rows = [mk.call("zdata"), mk.call("ztank"), mk.call("zroot"), mk.call("zbackup")]
      Beryl::CLI::Info.sort_volumes(rows).map(&.label).should eq(["zroot", "zbackup", "zdata", "ztank"])
    end
  end

  describe ".parse_df" do
    it "regroupe les datasets ZFS par pool (montage racine), filtre les pseudo-FS" do
      df = <<-DF
        Filesystem            Size    Used   Avail Capacity  Mounted on
        zroot/ROOT/default    430G    8.0G    422G     2%    /
        zroot/usr/home        422G    100K    422G     0%    /usr/home
        zdata                  14T    5.0T    9.0T    36%    /data
        devfs                  1.0K    1.0K      0B   100%    /dev
        tmpfs                  4.0G    1.0M    4.0G     0%    /tmp
        DF
      rows = Beryl::CLI::Info.parse_df(df)
      rows.map(&.label).should eq(["zroot", "zdata"])
      rows[0].used.should eq("8.0G") # racine du pool (/), pas /usr/home
      rows[1].pct.should eq("64%")   # 36% utilisé → 64% libre
    end

    it "garde les devices classiques par montage (Linux/UFS)" do
      df = <<-DF
        Filesystem      Size  Used Avail Use% Mounted on
        /dev/sda1        50G   20G   30G  40% /
        /dev/sdb1       2.0T  1.2T  800G  60% /data
        tmpfs           7.8G     0  7.8G   0% /run
        DF
      rows = Beryl::CLI::Info.parse_df(df)
      rows.map(&.label).should eq(["/", "/data"])
      rows[1].used.should eq("1.2T")
    end
  end

  describe ".upsert_block" do
    it "remplace un bloc existant en préservant les autres clés" do
      content = "provider: ovh\novh:\n  service_name: old\nvrack:\n  name: pn-1\n"
      out = Beryl::CLI::Info.upsert_block(content, "ovh",
        ["ovh:", "  service_name: new", "  commercial_name: Advance-2"])
      out.should eq("provider: ovh\novh:\n  service_name: new\n  commercial_name: Advance-2\nvrack:\n  name: pn-1\n")
    end

    it "ajoute le bloc en fin si absent, en préservant les commentaires" do
      content = "# Clients : all\nprovider: ovh\n"
      out = Beryl::CLI::Info.upsert_block(content, "hardware",
        ["hardware:", "  cpu: EPYC", "  ram_gb: 64"])
      out.should contain("# Clients : all")
      out.should contain("provider: ovh")
      out.should contain("hardware:\n  cpu: EPYC\n  ram_gb: 64")
    end

    it "ne déborde pas sur le bloc suivant lors du remplacement" do
      content = "provider: ovh\novh:\n  service_name: x\napply_recipes:\n  - clamav\n"
      out = Beryl::CLI::Info.upsert_block(content, "ovh", ["ovh:", "  service_name: y"])
      out.should contain("apply_recipes:\n  - clamav")
      out.should contain("  service_name: y")
      out.should_not contain("service_name: x")
    end
  end

  describe ".packages_in_dirs" do
    central = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "recipes", "central", "recipes"))

    it "extrait les paquets des steps pkg-install, triés et dédupliqués" do
      Beryl::CLI::Info.packages_in_dirs([central]).should eq(["bash", "ca_root_nss", "curl", "git", "tmux", "zsh"])
    end

    it "ignore un dossier inexistant sans planter" do
      Beryl::CLI::Info.packages_in_dirs(["/n/existe/pas"]).should be_empty
    end
  end

  describe ".freebsd_upgrade_hint" do
    by = {13 => "13.5", 14 => "14.4", 15 => "15.1"}

    it "signale une minor plus récente dans la même branche" do
      Beryl::CLI::Info.freebsd_upgrade_hint("FreeBSD 15.0-RELEASE-p10", by).should eq("↑ 15.1-RELEASE dispo")
    end

    it "nil si déjà à jour (dernière de la branche, pas de branche supérieure)" do
      Beryl::CLI::Info.freebsd_upgrade_hint("FreeBSD 15.1-RELEASE", by).should be_nil
    end

    it "signale minor ET nouvelle branche majeure" do
      Beryl::CLI::Info.freebsd_upgrade_hint("FreeBSD 14.3-RELEASE-p2", by)
        .should eq("↑ 14.4-RELEASE dispo ; branche 15.1-RELEASE dispo")
    end

    it "à jour dans sa branche mais une branche majeure plus récente existe" do
      Beryl::CLI::Info.freebsd_upgrade_hint("FreeBSD 14.4-RELEASE", by).should eq("branche 15.1-RELEASE dispo")
    end

    it "nil si la version est illisible (OS non FreeBSD)" do
      Beryl::CLI::Info.freebsd_upgrade_hint("Linux 6.1", by).should be_nil
    end
  end

  describe ".parse_pkg_lines" do
    it "parse une sortie `pkg query '%n %v'` en map nom→version" do
      m = Beryl::CLI::Info.parse_pkg_lines("bash 5.2.37\ngit 2.47.1\ncurl 8.11.0\n")
      m.should eq({"bash" => "5.2.37", "git" => "2.47.1", "curl" => "8.11.0"})
    end

    it "ignore les lignes vides et tolère une version absente" do
      m = Beryl::CLI::Info.parse_pkg_lines("\nzsh\n\ntmux 3.5\n")
      m["zsh"].should eq("")
      m["tmux"].should eq("3.5")
      m.size.should eq(2)
    end
  end
end
