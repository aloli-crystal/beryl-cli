require "../../spec_helper"
require "../../../src/beryl/cli/option_errors"

private def parser_with(banner : String) : OptionParser
  OptionParser.new { |p| p.banner = banner }
end

describe "Beryl::CLI.option_command" do
  it "tire la commande du banner" do
    Beryl::CLI.option_command(parser_with("USAGE : beryl bootstrap <host> [options]")).should eq("beryl bootstrap")
  end

  it "garde les sous-commandes en plusieurs mots" do
    Beryl::CLI.option_command(parser_with("USAGE : beryl env migrate [--force] [<société>...]")).should eq("beryl env migrate")
  end

  it "retombe sur « beryl » sans banner exploitable" do
    Beryl::CLI.option_command(OptionParser.new).should eq("beryl")
  end
end
