require "../../spec_helper"
require "../../../src/beryl/cli/root_conn"

describe Beryl::CLI::RootConn do
  it "connecté en root : la commande telle quelle" do
    Beryl::CLI::RootConn.line("zpool import -N zbackup", true).should eq("zpool import -N zbackup")
  end

  it "autre compte : via sudo -n, pipes et redirections compris" do
    Beryl::CLI::RootConn.line("zpool import -N zbackup", false).should eq("sudo -n sh -c 'zpool import -N zbackup'")
    Beryl::CLI::RootConn.line("zfs list -H | head -1 2>/dev/null", false).should start_with("sudo -n sh -c ")
  end
end
