require "../../spec_helper"
require "../../../src/beryl/config"
require "file_utils"

# Helper : crée une arborescence ~/.beryl/ factice dans un dossier
# temporaire, yield son chemin, nettoie à la fin.
private def with_beryl_tree(files : Hash(String, String), &)
  root = File.tempname("beryl-config-test-")
  Dir.mkdir_p(root)
  files.each do |relative, content|
    path = File.join(root, relative)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Beryl::Config::Root do
  describe ".load" do
    it "charge une arborescence minimale (juste un domaine vide)" do
      with_beryl_tree({
        "aloli.net.yml" => <<-YAML,
        ovh:
          ssh_key_name: philippe.aloli.fr
        ssh_keys:
          - ssh-ed25519 AAAA philippe@aloli.fr
        YAML
      }) do |root|
        cfg = Beryl::Config::Root.load(root)
        cfg.domain_names.should eq(["aloli.net"])
        cfg.domain?("aloli.net").not_nil!.ssh_keys.should eq(["ssh-ed25519 AAAA philippe@aloli.fr"])
      end
    end

    it "ignore _default.yml et .env.yml comme noms de domaine" do
      with_beryl_tree({
        "_default.yml"  => "freebsd:\n  timezone: Europe/Paris\n",
        ".env.yml"      => "aloli.net:\n  OVH_APPLICATION_KEY: xxx\n",
        "aloli.net.yml" => "ssh_keys: [k1]\n",
      }) do |root|
        cfg = Beryl::Config::Root.load(root)
        cfg.domain_names.should eq(["aloli.net"])
        cfg.defaults[YAML::Any.new("freebsd")].as_h[YAML::Any.new("timezone")].as_s.should eq("Europe/Paris")
        cfg.env_file.for_domain("aloli.net")["OVH_APPLICATION_KEY"].should eq("xxx")
      end
    end

    it "charge des hosts directs dans un domaine" do
      with_beryl_tree({
        "aloli.net.yml"        => "ssh_keys: [k]\n",
        "aloli.net/loulou.yml" => "freebsd:\n  hostname: loulou\n  disks: [/dev/sda]\n",
      }) do |root|
        domain = Beryl::Config::Root.load(root).domain?("aloli.net").not_nil!
        domain.direct_hosts.size.should eq(1)
        domain.direct_hosts["loulou"].name.should eq("loulou")
      end
    end

    it "charge des groupes avec fichier + dossier (Ruby/Crystal)" do
      with_beryl_tree({
        "aloli.net.yml"             => "ssh_keys: [k]\n",
        "aloli.net/web.yml"         => "freebsd:\n  packages: [nginx, postgresql16-server]\n",
        "aloli.net/web/rails01.yml" => "freebsd:\n  hostname: rails01\n  disks: [/dev/sda]\n",
        "aloli.net/web/rails02.yml" => "freebsd:\n  hostname: rails02\n  disks: [/dev/sdb]\n",
      }) do |root|
        domain = Beryl::Config::Root.load(root).domain?("aloli.net").not_nil!
        domain.direct_hosts.should be_empty
        domain.groups.size.should eq(1)
        web = domain.groups["web"]
        web.hosts.size.should eq(2)
        web.hosts.keys.sort.should eq(["rails01", "rails02"])
      end
    end

    it "tolère un groupe-dossier sans fichier de définition" do
      # aloli.net/api/ existe mais pas aloli.net/api.yml (propriétés vides)
      with_beryl_tree({
        "aloli.net.yml"             => "ssh_keys: [k]\n",
        "aloli.net/api/serveur.yml" => "freebsd:\n  hostname: api1\n",
      }) do |root|
        domain = Beryl::Config::Root.load(root).domain?("aloli.net").not_nil!
        api = domain.groups["api"]
        api.raw.should be_empty
        api.source_path.should be_nil
        api.hosts.size.should eq(1)
      end
    end

    it "supporte plusieurs domaines en parallèle" do
      with_beryl_tree({
        "aloli.net.yml"        => "ssh_keys: [ka]\n",
        "aloli.net/loulou.yml" => "freebsd:\n  hostname: loulou\n",
        "quimeo.fr.yml"        => "ssh_keys: [kq]\n",
        "quimeo.fr/site.yml"   => "freebsd:\n  hostname: site\n",
      }) do |root|
        cfg = Beryl::Config::Root.load(root)
        cfg.domain_names.should eq(["aloli.net", "quimeo.fr"])
      end
    end

    it "renvoie une Root vide si la racine n'existe pas" do
      cfg = Beryl::Config::Root.load("/tmp/inexistant-beryl-root-xyz")
      cfg.domain_names.should be_empty
    end
  end

  describe "#resolve" do
    it "résout un FQDN par suffix match" do
      with_beryl_tree({
        "_default.yml"         => "freebsd:\n  timezone: Europe/Paris\n",
        "aloli.net.yml"        => "ssh_keys: [k]\n",
        "aloli.net/loulou.yml" => "freebsd:\n  hostname: loulou\n  disks: [/dev/sda]\n",
      }) do |root|
        cfg = Beryl::Config::Root.load(root)
        rh = cfg.resolve("loulou.aloli.net")
        rh.short_name.should eq("loulou")
        rh.domain.name.should eq("aloli.net")
        rh.group.should be_nil
        rh.fqdn.should eq("loulou.aloli.net")
        rh.virtual.should be_false
      end
    end

    it "résout un nom court via recherche de fichier" do
      with_beryl_tree({
        "aloli.net.yml"        => "ssh_keys: [k]\n",
        "aloli.net/loulou.yml" => "freebsd:\n  hostname: loulou\n",
      }) do |root|
        rh = Beryl::Config::Root.load(root).resolve("loulou")
        rh.fqdn.should eq("loulou.aloli.net")
      end
    end

    it "résout via provider-name (ovh.service_name)" do
      with_beryl_tree({
        "aloli.net.yml"        => "ssh_keys: [k]\n",
        "aloli.net/loulou.yml" => <<-YAML,
        provider: ovh
        ovh:
          service_name: ns3156789.ip-51-83-6.eu
        freebsd:
          hostname: loulou
        YAML
      }) do |root|
        rh = Beryl::Config::Root.load(root).resolve("ns3156789.ip-51-83-6.eu")
        rh.fqdn.should eq("loulou.aloli.net")
      end
    end

    it "lève AmbiguousHost si le nom court existe dans plusieurs domaines" do
      with_beryl_tree({
        "aloli.net.yml"        => "ssh_keys: [ka]\n",
        "aloli.net/loulou.yml" => "freebsd:\n  hostname: loulou\n",
        "quimeo.fr.yml"        => "ssh_keys: [kq]\n",
        "quimeo.fr/loulou.yml" => "freebsd:\n  hostname: loulou\n",
      }) do |root|
        expect_raises(Beryl::Config::Root::AmbiguousHost, /plusieurs domaines/) do
          Beryl::Config::Root.load(root).resolve("loulou")
        end
      end
    end

    it "--domain=X court-circuite l'ambiguïté" do
      with_beryl_tree({
        "aloli.net.yml"        => "ssh_keys: [ka]\n",
        "aloli.net/loulou.yml" => "freebsd:\n  hostname: loulou\n",
        "quimeo.fr.yml"        => "ssh_keys: [kq]\n",
        "quimeo.fr/loulou.yml" => "freebsd:\n  hostname: loulou\n",
      }) do |root|
        rh = Beryl::Config::Root.load(root).resolve("loulou", domain_hint: "aloli.net")
        rh.domain.name.should eq("aloli.net")
      end
    end

    it "--domain=X sans fichier crée un host virtuel" do
      with_beryl_tree({
        "aloli.net.yml" => "ssh_keys: [k]\n",
      }) do |root|
        rh = Beryl::Config::Root.load(root).resolve(
          "ns3156789.ip-51-83-6.eu",
          domain_hint: "aloli.net",
        )
        rh.virtual.should be_true
        rh.fqdn.should eq("ns3156789.ip-51-83-6.eu.aloli.net")
      end
    end

    it "lève HostNotFound si rien ne matche" do
      with_beryl_tree({
        "aloli.net.yml" => "ssh_keys: [k]\n",
      }) do |root|
        expect_raises(Beryl::Config::Root::HostNotFound, /hôte inconnu/) do
          Beryl::Config::Root.load(root).resolve("pas-de-nom")
        end
      end
    end

    it "lève UnknownDomain si --domain=X cible un domaine inexistant" do
      with_beryl_tree({
        "aloli.net.yml" => "ssh_keys: [k]\n",
      }) do |root|
        expect_raises(Beryl::Config::Root::UnknownDomain, /domaine inconnu/) do
          Beryl::Config::Root.load(root).resolve("serveur", domain_hint: "pas-domaine.com")
        end
      end
    end
  end
end
