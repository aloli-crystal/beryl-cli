require "../../spec_helper"
require "../../../src/beryl/cli/apply"
require "../../../src/beryl/cli/bootstrap"

private FIXTURE = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "ssh-host-override"))

describe "Beryl::CLI::Apply.missing_variable_message" do
  host = Beryl::Config::Root.load(FIXTURE).resolve("rescuehidden")

  it "dit quel champ du host.yml renseigner pour une variable de l'hôte" do
    ex = Beryl::Apply::MissingVariable.new("netif-ipv6", "public_ip6", ["fqdn", "public_ip"])
    msg = Beryl::CLI::Apply.missing_variable_message(ex, host)
    msg.should start_with("recette `netif-ipv6` : variable `public_ip6` non définie — renseignez `ovh.ipv6` dans ")
    msg.should end_with(".host.yml")
  end

  it "renvoie à beryl info --refresh pour la passerelle IPv6" do
    ex = Beryl::Apply::MissingVariable.new("netif-ipv6", "public_ip6_gateway", ["fqdn"])
    Beryl::CLI::Apply.missing_variable_message(ex, host).should contain("renseignez `ovh.ipv6_gateway` (`beryl info --refresh` la lit dans l'API OVH)")
  end

  it "liste les variables connues pour une variable inconnue" do
    ex = Beryl::Apply::MissingVariable.new("site", "port", ["fqdn", "hostname"])
    Beryl::CLI::Apply.missing_variable_message(ex, host).should eq(
      "recette `site` : variable `port` non définie — ni paramètre de la recette, ni variable de l'hôte (connues : fqdn, hostname)"
    )
  end
end

describe "Beryl::CLI::Apply.root_ssh_login" do
  it "coupe root sans /home chiffré" do
    pool = Beryl::Config::Pool.new(name: "zroot", boot: true, raid: 0, disks: ["/dev/nvme0n1"])
    Beryl::CLI::Apply.root_ssh_login(pool).should eq("no")
  end

  it "root limité au déverrouillage (commande imposée) avec /home chiffré (profil standard)" do
    pool = Beryl::Config::Pool.new(
      name: "zroot", boot: true, raid: 0, disks: ["/dev/nvme0n1"],
      encryption: Beryl::Config::EncryptionConfig.new(mode: Beryl::Config::EncryptionConfig::Mode::SshUnlock),
      profile: "standard",
    )
    Beryl::CLI::Apply.root_ssh_login(pool).should eq("forced-commands-only")
  end

  it "coupe root pour un hôte sans pool boot déclaré" do
    host = Beryl::Config::Root.load(FIXTURE).resolve("rescuehidden")
    Beryl::CLI::Apply.root_ssh_login(host).should eq("no")
  end
end

private INSTALLED_FLAG = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "installed-flag"))

describe "beryl sync et installed: false" do
  it "refuse un serveur nommé qui n'est pas encore installé, sans SSH" do
    Beryl::CLI::Apply.run(INSTALLED_FLAG, ["pending"]).should eq(Beryl::CLI::Apply::EXIT_NOT_INSTALLED)
  end

  it "sépare les serveurs non installés d'une portée (sautés)" do
    root = Beryl::Config::Root.load(INSTALLED_FLAG)
    hosts = %w[explicit pending ready].map { |n| root.resolve(n) }
    pending, installed = Beryl::CLI::Apply.split_installed(hosts)
    pending.map(&.short_name).should eq(["pending"])
    installed.map(&.short_name).should eq(["explicit", "ready"])
  end

  it "refuse aussi un serveur dont le groupe déclare installed: false" do
    Beryl::CLI::Apply.run(INSTALLED_FLAG, ["grouped"]).should eq(Beryl::CLI::Apply::EXIT_NOT_INSTALLED)
  end

  it "nomme le host.yml quand le serveur lui-même est marqué" do
    host = Beryl::Config::Root.load(INSTALLED_FLAG).resolve("pending")
    Beryl::CLI::Apply.installed_origin(host).should eq({"example/example.net/pending.host.yml", nil})
    msg = Beryl::CLI::Apply.not_installed_message(host)
    msg.should contain("`installed: false` dans example/example.net/pending.host.yml")
    msg.should contain("`beryl bootstrap pending --apply`, qui retire cette ligne")
  end

  it "nomme le _defaults.yml du groupe et sa portée quand le réglage est commun" do
    host = Beryl::Config::Root.load(INSTALLED_FLAG).resolve("grouped")
    Beryl::CLI::Apply.installed_origin(host).should eq({"example/example.net/attente/_defaults.yml", "tout le groupe attente"})
    msg = Beryl::CLI::Apply.not_installed_message(host)
    msg.should contain("`installed: false` dans example/example.net/attente/_defaults.yml vaut pour tout le groupe attente")
    msg.should contain("Serveur déjà installé : retirez cette ligne")
    Beryl::CLI::Bootstrap.inherited_not_installed(host).should eq({"example/example.net/attente/_defaults.yml", "tout le groupe attente"})
  end

  it "ne signale rien d'hérité pour un serveur installé ou marqué dans son host.yml" do
    root = Beryl::Config::Root.load(INSTALLED_FLAG)
    Beryl::CLI::Bootstrap.inherited_not_installed(root.resolve("ready")).should be_nil
    Beryl::CLI::Bootstrap.inherited_not_installed(root.resolve("pending")).should be_nil
  end
end

describe "Beryl::CLI::Apply.root_unlock_keys" do
  it "union dédoublonnée des clés des comptes (clé du domaine partagée → une seule)" do
    host = Beryl::Config::Root.load(FIXTURE).resolve("connectuser")
    keys = Beryl::CLI::Apply.root_unlock_keys(host)
    keys.size.should eq 1
    keys.first.should start_with("ssh-")
  end
end
