require "../../spec_helper"
require "../../../src/beryl/cli/apply"

private alias Req = Beryl::CLI::Apply::RecipeRequest

private def req(name : String, args = {} of String => String) : Req
  Req.new(name, args)
end

describe "Beryl::CLI::Apply.adhoc_requests" do
  declared = [
    req("monit"),
    req("zfs-scrub", {"scrub_schedule" => "0 3 * * 3"}),
    req("oh-my-zsh", {"user" => "admin"}),
    req("oh-my-zsh", {"user" => "deploy"}),
  ]

  it "reprend les arguments déclarés dans le host.yml" do
    Beryl::CLI::Apply.adhoc_requests("zfs-scrub", declared, [] of String, restrict: true)
      .should eq([req("zfs-scrub", {"scrub_schedule" => "0 3 * * 3"})])
  end

  it "garde chaque jeu d'arguments d'une recette déclarée plusieurs fois" do
    Beryl::CLI::Apply.adhoc_requests("oh-my-zsh", declared, [] of String, restrict: true).try(&.size).should eq(2)
  end

  it "applique sans argument une recette tirée par une déclarée" do
    Beryl::CLI::Apply.adhoc_requests("acme", declared, ["acme", "monit"], restrict: true)
      .should eq([req("acme")])
  end

  it "saute une recette non déclarée sur un domaine ou une société" do
    Beryl::CLI::Apply.adhoc_requests("nginx-lite", declared, ["monit"], restrict: true).should be_nil
  end

  it "applique une recette non déclarée sur un serveur nommé" do
    Beryl::CLI::Apply.adhoc_requests("rotate-key", declared, [] of String, restrict: false)
      .should eq([req("rotate-key")])
  end
end

describe "Beryl::CLI::Apply.recipe_arguments" do
  declared = [
    req("monit", {"smarthost" => "relay.example.net"}),
    req("vuln-fix-alert"),
    req("periodic-quiet"),
  ]

  it "une dépendance déclarée reprend ses arguments du host.yml" do
    args = Beryl::CLI::Apply.recipe_arguments([req("periodic-quiet")], declared,
      ["monit", "vuln-fix-alert", "periodic-quiet"])
    args["monit"].should eq([{"smarthost" => "relay.example.net"}])
    args["periodic-quiet"].should eq([{} of String => String])
  end

  it "une dépendance non déclarée reste sans argument" do
    args = Beryl::CLI::Apply.recipe_arguments([req("periodic-quiet")], [req("periodic-quiet")],
      ["monit", "periodic-quiet"])
    args.has_key?("monit").should be_false
  end
end
