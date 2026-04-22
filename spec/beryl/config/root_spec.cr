require "../../spec_helper"
require "../../../src/beryl/config"

# Racine où vivent les fixtures : `spec/fixtures/config/<cas>/`.
# Chaque cas est une arborescence ~/.beryl/ complète, versionnée dans
# le dépôt pour rendre les tests reproductibles et lisibles (Philippe
# 22 avril 2026 : « Tous les tests de .yaml doivent être fait à partir
# du dossier du code et non dans ~/.beryl »).
private FIXTURES_ROOT = File.expand_path(
  File.join(__DIR__, "..", "..", "fixtures", "config"),
)

private def fixture(name : String) : String
  File.join(FIXTURES_ROOT, name)
end

describe Beryl::Config::Root do
  describe ".load" do
    it "charge une arborescence minimale (juste un domaine vide)" do
      cfg = Beryl::Config::Root.load(fixture("minimal-domain"))
      cfg.domain_names.should eq(["aloli.net"])
      cfg.domain?("aloli.net").not_nil!.ssh_keys.should eq(["ssh-ed25519 AAAA philippe@aloli.fr"])
    end

    it "ignore _default.yml et .env.yml comme noms de domaine" do
      cfg = Beryl::Config::Root.load(fixture("with-defaults-and-env"))
      cfg.domain_names.should eq(["aloli.net"])
      cfg.defaults[YAML::Any.new("freebsd")].as_h[YAML::Any.new("timezone")].as_s.should eq("Europe/Paris")
      cfg.env_file.for_domain("aloli.net")["OVH_APPLICATION_KEY"].should eq("xxx")
    end

    it "charge des hosts directs dans un domaine" do
      domain = Beryl::Config::Root.load(fixture("direct-hosts")).domain?("aloli.net").not_nil!
      domain.direct_hosts.size.should eq(1)
      domain.direct_hosts["loulou"].name.should eq("loulou")
    end

    it "charge des groupes avec fichier + dossier (Ruby/Crystal)" do
      domain = Beryl::Config::Root.load(fixture("with-group")).domain?("aloli.net").not_nil!
      domain.direct_hosts.should be_empty
      domain.groups.size.should eq(1)
      web = domain.groups["web"]
      web.hosts.size.should eq(2)
      web.hosts.keys.sort.should eq(["rails01", "rails02"])
    end

    it "tolère un groupe-dossier sans fichier de définition" do
      domain = Beryl::Config::Root.load(fixture("group-dir-without-yml")).domain?("aloli.net").not_nil!
      api = domain.groups["api"]
      api.raw.should be_empty
      api.source_path.should be_nil
      api.hosts.size.should eq(1)
    end

    it "supporte plusieurs domaines en parallèle" do
      cfg = Beryl::Config::Root.load(fixture("multi-domains"))
      cfg.domain_names.should eq(["aloli.net", "quimeo.fr"])
    end

    it "renvoie une Root vide si la racine n'existe pas" do
      cfg = Beryl::Config::Root.load(File.join(FIXTURES_ROOT, "NON-EXISTENT"))
      cfg.domain_names.should be_empty
    end
  end

  describe "#resolve" do
    it "résout un FQDN par suffix match" do
      cfg = Beryl::Config::Root.load(fixture("direct-hosts"))
      rh = cfg.resolve("loulou.aloli.net")
      rh.short_name.should eq("loulou")
      rh.domain.name.should eq("aloli.net")
      rh.group.should be_nil
      rh.fqdn.should eq("loulou.aloli.net")
      rh.virtual.should be_false
    end

    it "résout un nom court via recherche de fichier" do
      rh = Beryl::Config::Root.load(fixture("direct-hosts")).resolve("loulou")
      rh.fqdn.should eq("loulou.aloli.net")
    end

    it "résout via provider-name (ovh.service_name)" do
      rh = Beryl::Config::Root.load(fixture("provider-name-search")).resolve("ns3156789.ip-51-83-6.eu")
      rh.fqdn.should eq("loulou.aloli.net")
      rh.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "lève AmbiguousHost si le nom court existe dans plusieurs domaines" do
      expect_raises(Beryl::Config::Root::AmbiguousHost, /plusieurs domaines/) do
        Beryl::Config::Root.load(fixture("ambiguous-name")).resolve("loulou")
      end
    end

    it "--domain=X court-circuite l'ambiguïté" do
      rh = Beryl::Config::Root.load(fixture("ambiguous-name")).resolve("loulou", domain_hint: "aloli.net")
      rh.domain.name.should eq("aloli.net")
    end

    it "--domain=X sans fichier crée un host virtuel (nom court)" do
      rh = Beryl::Config::Root.load(fixture("minimal-domain")).resolve(
        "rails99",
        domain_hint: "aloli.net",
      )
      rh.virtual.should be_true
      rh.fqdn.should eq("rails99.aloli.net")
    end

    it "--domain=X + FQDN externe (nom hébergeur) : fqdn reste tel quel" do
      # Cas `beryl rescue ns3156789.ip-51-83-6.eu --domain=aloli.net` :
      # le nom passé est le FQDN hébergeur, on ne doit PAS fabriquer
      # un `ns3156789.ip-51-83-6.eu.aloli.net` (qui ne résout pas).
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
        Beryl::Config::Root.load(fixture("minimal-domain")).resolve("serveur", domain_hint: "pas-domaine.com")
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

  describe "#provider" do
    it "hérite `provider:` du domaine même pour un host virtuel (serveur neuf)" do
      # Cas premier : beryl rescue <nom_externe> --domain=aloli.net où
      # le domaine déclare `provider: ovh` et pas de fichier host.
      rh = Beryl::Config::Root.load(fixture("multi-provider-domain")).resolve(
        "ns3156789.ip-51-83-6.eu", domain_hint: "aloli.net")
      rh.virtual.should be_true
      rh.provider.should eq("ovh")
    end

    it "retourne nil si aucun niveau (default, domaine, host) ne déclare provider:" do
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
      # Cas : beryl rescue ns3156789.ip-51-83-6.eu --domain=aloli.net
      # où aloli.net a `provider: ovh` et pas de fichier host. Le nom
      # CLI EST le service_name côté OVH.
      rh = Beryl::Config::Root.load(fixture("multi-provider-domain")).resolve(
        "ns3156789.ip-51-83-6.eu", domain_hint: "aloli.net")
      rh.virtual.should be_true
      rh.ovh_service_name.should eq("ns3156789.ip-51-83-6.eu")
    end

    it "pas de fallback pour un virtual avec short_name sans point" do
      # `rails99` est un nom logique court, pas un service_name OVH.
      # On refuse de l'inférer pour éviter une API OVH qui échoue au
      # loin avec un 404 sur un service_name inventé.
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
      # with-defaults-and-env n'a que ssh_keys + freebsd, aucun bloc ovh/scaleway.
      rh = Beryl::Config::Root.load(fixture("with-defaults-and-env")).resolve(
        "loulou.aloli.net",
      )
      rh.present_provider_blocks.should be_empty
    end
  end
end
