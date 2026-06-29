require "../../spec_helper"
require "../../../src/beryl/config"

# Racine où vivent les fixtures : `spec/fixtures/config/<cas>/`.
# Chaque cas est une arborescence ~/.config/beryl/ complète :
#   <cas>/<société>/<domaine>.yml
#   <cas>/<société>/<domaine>/<host>.yml
#
# Note Philippe 23 avril 2026 : migration ADR-014 vers
# multi-société.  Tous les fixtures sont désormais sous
# `<cas>/<société>/<domaine>.yml`.
private FIXTURES_ROOT = File.expand_path(
  File.join(__DIR__, "..", "..", "fixtures", "config"),
)

private def fixture(name : String) : String
  File.join(FIXTURES_ROOT, name)
end

describe Beryl::Config::Root do
  describe ".load" do
    it "charge une arborescence minimale (une société avec un domaine)" do
      cfg = Beryl::Config::Root.load(fixture("minimal-domain"))
      cfg.account_names.should eq(["aloli"])
      aloli = cfg.account?("aloli").not_nil!
      aloli.domain_names.should eq(["aloli.net"])
      aloli.domain?("aloli.net").not_nil!.ssh_keys.should eq(["ssh-ed25519 AAAA philippe@aloli.fr"])
    end

    it "ignore _default.yml (à la racine) et .env.yml comme sociétés" do
      cfg = Beryl::Config::Root.load(fixture("with-defaults-and-env"))
      cfg.account_names.should eq(["aloli"])
      cfg.defaults[YAML::Any.new("freebsd")].as_h[YAML::Any.new("timezone")].as_s.should eq("Europe/Paris")
      cfg.env_file.for_account_provider("aloli", "ovh")["OVH_APPLICATION_KEY"].should eq("xxx")
    end

    it "charge des hosts directs dans un domaine" do
      aloli = Beryl::Config::Root.load(fixture("direct-hosts")).account?("aloli").not_nil!
      domain = aloli.domain?("aloli.net").not_nil!
      domain.direct_hosts.size.should eq(1)
      domain.direct_hosts["loulou"].name.should eq("loulou")
    end

    it "charge des groupes avec fichier + dossier" do
      aloli = Beryl::Config::Root.load(fixture("with-group")).account?("aloli").not_nil!
      domain = aloli.domain?("aloli.net").not_nil!
      domain.direct_hosts.should be_empty
      domain.groups.size.should eq(1)
      web = domain.groups["web"]
      web.hosts.size.should eq(2)
      web.hosts.keys.sort.should eq(["rails01", "rails02"])
    end

    it "charge un groupe à définition vide (api.group.yml sans contenu)" do
      aloli = Beryl::Config::Root.load(fixture("group-dir-without-yml")).account?("aloli").not_nil!
      domain = aloli.domain?("aloli.net").not_nil!
      api = domain.groups["api"]
      api.raw.should be_empty
      api.source_path.should_not be_nil
      api.hosts.size.should eq(1)
    end

    it "supporte plusieurs sociétés en parallèle" do
      cfg = Beryl::Config::Root.load(fixture("multi-domains"))
      cfg.account_names.should eq(["aloli", "popi"])
      cfg.account?("aloli").not_nil!.domain_names.should eq(["aloli.net"])
      cfg.account?("popi").not_nil!.domain_names.should eq(["popi.fr"])
    end

    it "renvoie une Root vide si la racine n'existe pas" do
      cfg = Beryl::Config::Root.load(File.join(FIXTURES_ROOT, "NON-EXISTENT"))
      cfg.account_names.should be_empty
    end
  end

  describe "#resolve" do
    it "résout un FQDN par suffix match" do
      cfg = Beryl::Config::Root.load(fixture("direct-hosts"))
      rh = cfg.resolve("loulou.aloli.net")
      rh.short_name.should eq("loulou")
      rh.account.name.should eq("aloli")
      rh.domain.name.should eq("aloli.net")
      rh.group.should be_nil
      rh.fqdn.should eq("loulou.aloli.net")
      rh.virtual.should be_false
    end

    it "résout un nom court via recherche globale" do
      rh = Beryl::Config::Root.load(fixture("direct-hosts")).resolve("loulou")
      rh.fqdn.should eq("loulou.aloli.net")
      rh.account.name.should eq("aloli")
    end

    it "résout via provider-name (ovh.service_name)" do
      rh = Beryl::Config::Root.load(fixture("provider-name-search")).resolve("ns3156789.ip-51-83-6.eu")
      rh.fqdn.should eq("loulou.aloli.net")
      rh.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "lève AmbiguousHost si le nom court existe dans plusieurs sociétés" do
      expect_raises(Beryl::Config::Root::AmbiguousHost, /plusieurs sociétés/) do
        Beryl::Config::Root.load(fixture("ambiguous-name")).resolve("loulou")
      end
    end

    it "--account=X + --domain=Y court-circuite l'ambiguïté" do
      rh = Beryl::Config::Root.load(fixture("ambiguous-name")).resolve(
        "loulou", account_hint: "aloli", domain_hint: "aloli.net")
      rh.account.name.should eq("aloli")
      rh.domain.name.should eq("aloli.net")
    end

    it "--domain=X sans fichier crée un host virtuel (nom court)" do
      rh = Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
        "rails99",
        domain_hint: "aloli.net",
      )
      rh.virtual.should be_true
      rh.fqdn.should eq("rails99.aloli.net")
      rh.account.name.should eq("aloli")
    end

    it "--domain=X + FQDN externe (nom hébergeur) : fqdn reste tel quel" do
      rh = Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
        "ns3156789.ip-51-83-6.eu",
        domain_hint: "aloli.net",
      )
      rh.virtual.should be_true
      rh.fqdn.should eq("ns3156789.ip-51-83-6.eu")
      rh.ssh_host.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "lève HostNotFound si rien ne matche" do
      expect_raises(Beryl::Config::Root::HostNotFound, /hôte inconnu/) do
        Beryl::Config::Root.load(fixture("minimal-domain")).resolve("pas-de-nom")
      end
    end

    it "lève UnknownDomain si --domain=X cible un domaine inexistant" do
      expect_raises(Beryl::Config::Root::UnknownDomain, /domaine inconnu/) do
        Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
          "serveur", domain_hint: "pas-domaine.com")
      end
    end

    it "lève UnknownAccount si --account=X cible une société inexistante" do
      expect_raises(Beryl::Config::Root::UnknownAccount, /société inconnue/) do
        Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
          "serveur", account_hint: "inexistant", domain_hint: "aloli.net")
      end
    end
  end
end

describe Beryl::Config::ResolvedHost do
  it "expose ssh_host (FQDN OVH si provider=ovh+service_name, sinon FQDN)" do
    rh = Beryl::Config::Root.load(fixture("provider-name-search")).resolve("loulou")
    rh.ssh_host.should eq("ns3156789.ip-51-83-6.eu")
    rh.ssh_host_is_provider_name?.should be_true
  end

  it "ssh_host == fqdn quand pas de provider service_name" do
    rh = Beryl::Config::Root.load(fixture("direct-hosts")).resolve("loulou")
    rh.ssh_host.should eq("loulou.aloli.net")
    rh.ssh_host_is_provider_name?.should be_false
  end

  it "respecte `ssh_host:` explicite du YAML (override prime sur tout)" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("clientvm")
    rh.ssh_host.should eq("127.0.0.1")
    rh.ssh_host_explicit?.should be_true
    rh.ssh_host_is_provider_name?.should be_false
    rh.connection.host.should eq("127.0.0.1")
    rh.connection.port.should eq(2223)
    rh.connection.user.should eq("root")
  end

  it "bastion: true → le host EST un bastion (pas de routage dérivé)" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("bast")
    rh.bastion?.should be_true
    rh.bastion_name.should be_nil
    rh.proxy_jump.should be_nil
  end

  it "bastion: <nom> → dérive ssh_host (IP vRack) + proxy_jump (user@nom.domaine)" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("hidden")
    rh.bastion?.should be_false
    rh.bastion_name.should eq("bast")
    rh.ssh_host.should eq("192.168.42.99")                   # = vrack_ip
    rh.proxy_jump("admin").should eq("admin@bast.aloli.net") # user de connexion
    rh.proxy_jump.should eq("admin@bast.aloli.net")          # défaut = host.user (admin)
  end

  it "vrack: ip (liste) + proxy_jump → host caché, ssh_host = 1ʳᵉ IP vRack" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("netapp")
    rh.vrack_name.should eq("pn-1049829")
    rh.vrack_ips.should eq(["192.168.42.31", "192.168.42.131"])
    rh.vrack_ip.should eq("192.168.42.31")
    rh.hidden?.should be_true
    rh.proxy_jump.should eq("admin@zsbg.aloli.net") # chaîne complète, user inclus
    rh.ssh_host.should eq("192.168.42.31")          # 1ʳᵉ IP vRack (caché)
  end

  it "rescue_ssh_host : host caché OVH → IP publique (service_name), PAS l'IP vRack" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("rescuehidden")
    rh.hidden?.should be_true
    rh.ssh_host.should eq("192.168.42.50")             # prod : 1ʳᵉ IP vRack
    rh.rescue_ssh_host.should eq("ns9999.ip-1-2-3.eu") # rescue : service OVH public
  end

  it "rescue_ssh_host : host NON caché → identique à ssh_host (aucun changement)" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("netbast")
    rh.hidden?.should be_false
    rh.rescue_ssh_host.should eq(rh.ssh_host)
  end

  it "ovh.commercial_name + bloc hardware: lus pour `beryl info`" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("infohw")
    rh.ovh_commercial_name.should eq("Advance-2")
    rh.ovh_rack.should eq("16RA09")
    rh.ovh_ipv4.should eq("1.2.3.4")
    rh.ovh_price.should eq("89.99") # lu depuis un NOMBRE YAML
    hw = rh.hardware.not_nil!
    hw.cpu.should eq("AMD EPYC 4344P")
    hw.cores.should eq(8)
    hw.threads.should eq(16)
    hw.ram_gb.should eq(64)
    hw.raid.should eq("9361-4i")
    hw.disks.should eq(["2 x 960 GB SSD", "4 x 7680 GB SSD"])
  end

  it "hardware = nil si le host n'a pas été scanné (pas de bloc hardware:)" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("netbast")
    rh.hardware.should be_nil
    rh.ovh_commercial_name.should be_nil
  end

  it "vrack.bastion: true → bastion public (non caché, ssh_host = fqdn)" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("netbast")
    rh.bastion?.should be_true
    rh.hidden?.should be_false
    rh.vrack_name.should eq("pn-1049829")
    rh.vrack_ips.should eq(["192.168.42.3"]) # scalaire normalisé en liste
    rh.ssh_host.should eq("netbast.aloli.net")
    rh.ssh_host_is_provider_name?.should be_false
  end

  it "passe `proxy_jump:` à ssh via un ProxyCommand vers le bastion vRack" do
    rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("clientvm")
    rh.proxy_jump.should eq("deploy@bastion.example.net")
    # Le shard ssh (>= 0.2.4) convertit `ProxyJump` en `ProxyCommand` explicite
    # (pour transporter la clé `-i` jusqu'au bastion sous `-F /dev/null`).
    joined = rh.connection.ssh_args("true").join(" ")
    joined.should_not contain("ProxyJump=")
    joined.should contain("ProxyCommand=")
    joined.should contain("-W %h:%p deploy@bastion.example.net")
  end

  it "expose les accesseurs freebsd (hostname, disks, timezone)" do
    rh = Beryl::Config::Root.load(fixture("with-defaults-and-env")).resolve(
      "quelconque", domain_hint: "aloli.net")
    rh.freebsd_string("timezone").should eq("Europe/Paris") # depuis _default
  end

  it "connection.host == ssh_host" do
    rh = Beryl::Config::Root.load(fixture("provider-name-search")).resolve("loulou")
    rh.connection.host.should eq("ns3156789.ip-51-83-6.eu")
    rh.connection.port.should eq(22)
    rh.connection.user.should eq("root")
  end

  describe "#account" do
    it "porte la société payeuse résolue" do
      rh = Beryl::Config::Root.load(fixture("direct-hosts")).resolve("loulou")
      rh.account.name.should eq("aloli")
      rh.account_name.should eq("aloli")
    end
  end

  describe "#credentials_for(provider)" do
    it "récupère les credentials du couple (société, provider) depuis .env.yml" do
      rh = Beryl::Config::Root.load(fixture("with-defaults-and-env")).resolve(
        "serveur", domain_hint: "aloli.net")
      creds = rh.credentials_for("ovh")
      creds["OVH_APPLICATION_KEY"].should eq("xxx")
    end

    it "retourne un hash vide si le provider n'a pas de credentials" do
      rh = Beryl::Config::Root.load(fixture("with-defaults-and-env")).resolve(
        "serveur", domain_hint: "aloli.net")
      rh.credentials_for("scaleway").should be_empty
    end
  end

  describe "#provider" do
    it "hérite `provider:` du domaine même pour un host virtuel" do
      rh = Beryl::Config::Root.load(fixture("multi-provider-domain")).resolve(
        "ns3156789.ip-51-83-6.eu", domain_hint: "aloli.net")
      rh.virtual.should be_true
      rh.provider.should eq("ovh")
    end

    it "retourne nil si aucun niveau ne déclare provider:" do
      rh = Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
        "serveur-neuf", domain_hint: "aloli.net")
      rh.provider.should be_nil
    end
  end

  describe "#ovh_service_name (fallback virtual host)" do
    it "lit ovh.service_name explicite si présent (host déclaré)" do
      rh = Beryl::Config::Root.load(fixture("provider-name-search")).resolve("loulou")
      rh.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "fallback sur short_name pour un virtual host OVH avec FQDN" do
      rh = Beryl::Config::Root.load(fixture("multi-provider-domain")).resolve(
        "ns3156789.ip-51-83-6.eu", domain_hint: "aloli.net")
      rh.virtual.should be_true
      rh.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "pas de fallback pour un virtual avec short_name sans point" do
      rh = Beryl::Config::Root.load(fixture("multi-provider-domain")).resolve(
        "rails99", domain_hint: "aloli.net")
      rh.virtual.should be_true
      rh.ovh_service_name.should be_nil
    end
  end

  describe "#present_provider_blocks" do
    it "liste les blocs providers présents dans le merged (ovh + scaleway)" do
      rh = Beryl::Config::Root.load(fixture("multi-provider-domain")).resolve(
        "serveur-neuf", domain_hint: "aloli.net")
      rh.present_provider_blocks.sort.should eq(%w[ovh scaleway])
    end

    it "vide si aucun bloc provider dans la config mergée" do
      rh = Beryl::Config::Root.load(fixture("with-defaults-and-env")).resolve(
        "loulou.aloli.net")
      rh.present_provider_blocks.should be_empty
    end
  end

  describe "#os" do
    it "retourne 'freebsd' par défaut si le YAML ne déclare rien" do
      rh = Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
        "serveur", domain_hint: "aloli.net")
      rh.os.should eq("freebsd")
    end
  end

  describe "#ssh_key_diagnostic" do
    it "alerte si un host OVH n'a pas de `ovh.ssh_key_name` (clé non résolue)" do
      rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("infohw")
      diag = rh.ssh_key_diagnostic
      diag.should_not be_nil
      diag.not_nil!.should contain("ovh.ssh_key_name")
      diag.not_nil!.should contain("RACINE") # pointe le piège du mauvais niveau
    end

    it "ne dit rien pour un host non-OVH (absence de clé légitime)" do
      rh = Beryl::Config::Root.load(fixture("ssh-host-override")).resolve("clientvm")
      rh.ssh_key_diagnostic.should be_nil
    end
  end
end
