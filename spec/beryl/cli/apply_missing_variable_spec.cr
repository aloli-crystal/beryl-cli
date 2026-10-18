require "../../spec_helper"
require "../../../src/beryl/cli/apply"

private FIXTURE = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "ssh-host-override"))

describe "Beryl::CLI::Apply.missing_variable_message" do
  host = Beryl::Config::Root.load(FIXTURE).resolve("rescuehidden")

  it "dit quel champ du host.yml renseigner pour une variable de l'hôte" do
    ex = Beryl::Apply::MissingVariable.new("netif-ipv6", "public_ip6", ["fqdn", "public_ip"])
    msg = Beryl::CLI::Apply.missing_variable_message(ex, host)
    msg.should start_with("recette `netif-ipv6` : variable `public_ip6` non définie — renseignez `ovh.ipv6` dans ")
    msg.should end_with(".host.yml")
  end

  it "liste les variables connues pour une variable inconnue" do
    ex = Beryl::Apply::MissingVariable.new("site", "port", ["fqdn", "hostname"])
    Beryl::CLI::Apply.missing_variable_message(ex, host).should eq(
      "recette `site` : variable `port` non définie — ni paramètre de la recette, ni variable de l'hôte (connues : fqdn, hostname)"
    )
  end
end
