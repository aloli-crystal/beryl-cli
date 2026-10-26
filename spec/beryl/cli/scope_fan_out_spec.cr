require "../../spec_helper"
require "option_parser"
require "../../../src/beryl/cli/scope"

private FAN_FIXTURE = File.expand_path(File.join(__DIR__, "..", "..", "fixtures", "config", "scope-groups"))

# Lance `fan_out` en capturant les arguments de chaque rejeu.
private def fan(args : Array(String), positional : Array(String)) : {Int32?, Array(Array(String))}
  calls = [] of Array(String)
  code = Beryl::CLI::Scope.fan_out("test", FAN_FIXTURE, args, positional) { |a| calls << a; 0 }
  {code, calls}
end

describe Beryl::CLI::Scope do
  describe ".join_list" do
    it "recolle `ah, be, ga` coupé par le shell" do
      Beryl::CLI::Scope.join_list(["ah,", "be,", "ga", "--x"]).should eq(["ah,be,ga", "--x"])
      Beryl::CLI::Scope.join_list(["ah", ",be"]).should eq(["ah,be"])
      Beryl::CLI::Scope.join_list(["loulou", "recette"]).should eq(["loulou", "recette"])
      Beryl::CLI::Scope.join_list([] of String).should be_empty
    end
  end

  describe ".without_scope" do
    it "retire les morceaux de la portée, garde les options" do
      Beryl::CLI::Scope.without_scope(["ah,", "--apply", "be"], 2, ["ah,", "be"]).should eq(["--apply"])
    end
  end

  describe ".fan_out" do
    it "un seul serveur : nil, la commande suit son cours" do
      fan(["db01"], ["db01"])[0].should be_nil
    end

    it "un groupe : rejouée pour chaque serveur, options gardées" do
      code, calls = fan(["web", "--apply"], ["web"])
      code.should eq 0
      calls.size.should eq 2
      calls.each { |c| c.first.should eq "--apply" }
      calls.map(&.last.split('/').last).should eq(%w[rails01 rails02])
    end

    it "une liste avec espaces : recollée puis rejouée" do
      code, calls = fan(["rails02,", "db01"], ["rails02,", "db01"])
      code.should eq 0
      calls.map(&.last.split('/').last).should eq(%w[rails02 db01])
    end

    it "élément inconnu dans une liste : erreur, rien n'est lancé" do
      code, calls = fan(["db01,zgar"], ["db01,zgar"])
      code.should eq 1
      calls.should be_empty
    end

    it "garde les options déjà analysées : la copie prise AVANT `parse` les contient" do
      args = ["web", "--apply"]
      positional = [] of String
      all_args = args.dup
      OptionParser.new { |op| op.on("--apply", "") { }; op.unknown_args { |r, _| positional = r } }.parse(args)
      args.should eq(["web"]) # parse a retiré --apply : c'est pourquoi on passe la copie
      calls = [] of Array(String)
      Beryl::CLI::Scope.fan_out("test", FAN_FIXTURE, all_args, positional) { |x| calls << x; 0 }
      calls.all?(&.includes?("--apply")).should be_true
    end

    it "code du premier échec" do
      calls = 0
      code = Beryl::CLI::Scope.fan_out("test", FAN_FIXTURE, ["web"], ["web"]) { |_| calls += 1; calls == 2 ? 5 : 0 }
      code.should eq 5
    end
  end
end
