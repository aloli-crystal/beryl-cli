require "../spec_helper"

describe Beryl::SSH::Result do
  it "est en succès quand exit_code vaut zéro" do
    Beryl::SSH::Result.new("", "", 0).success?.should be_true
  end

  it "est en échec quand exit_code est non nul" do
    Beryl::SSH::Result.new("", "", 1).success?.should be_false
  end
end

describe Beryl::SSH::CommandFailed do
  it "inclut le code de sortie et la commande dans le message" do
    result = Beryl::SSH::Result.new("", "", 42)
    err = Beryl::SSH::CommandFailed.new("pkg info", result)
    err.message.to_s.should contain("exit 42")
    err.message.to_s.should contain("pkg info")
  end

  it "ajoute la stderr au message quand elle est présente" do
    result = Beryl::SSH::Result.new("", "pkg not found\n", 1)
    err = Beryl::SSH::CommandFailed.new("pkg info frobnicator", result)
    err.message.to_s.should contain("pkg not found")
  end
end

describe Beryl::SSH::Connection do
  describe "#ssh_args" do
    it "utilise le port par défaut et l'utilisateur par défaut" do
      conn = Beryl::SSH::Connection.new(host: "web01.aloli.fr")
      args = conn.ssh_args("uname -r")
      args.should eq(["-p", "22", "root@web01.aloli.fr", "uname -r"])
    end

    it "honore l'utilisateur et le port personnalisés" do
      conn = Beryl::SSH::Connection.new(
        host: "web01.aloli.fr",
        user: "admin",
        port: 2222,
      )
      conn.ssh_args("hostname").should eq(["-p", "2222", "admin@web01.aloli.fr", "hostname"])
    end

    it "injecte la clé privée quand fournie" do
      conn = Beryl::SSH::Connection.new(
        host: "web01.aloli.fr",
        identity_file: "/home/me/.ssh/id_ed25519",
      )
      args = conn.ssh_args("whoami")
      args.should contain("-i")
      args.should contain("/home/me/.ssh/id_ed25519")
    end

    it "injecte chaque option -o au format Key=Value" do
      conn = Beryl::SSH::Connection.new(
        host: "web01.aloli.fr",
        options: {"ConnectTimeout" => "5", "BatchMode" => "yes"},
      )
      args = conn.ssh_args("true")
      args.should contain("-o")
      args.should contain("ConnectTimeout=5")
      args.should contain("BatchMode=yes")
    end
  end

  describe "#scp_args" do
    it "utilise -P (majuscule) pour le port, contrairement à ssh" do
      conn = Beryl::SSH::Connection.new(host: "web01.aloli.fr", port: 2222)
      args = conn.scp_args("local.txt", "root@web01.aloli.fr:/tmp/x")
      args.first(2).should eq(["-P", "2222"])
    end

    it "place source puis destination en fin d'arguments" do
      conn = Beryl::SSH::Connection.new(host: "web01.aloli.fr")
      args = conn.scp_args("/a/b", "/c/d")
      args.last(2).should eq(["/a/b", "/c/d"])
    end
  end

  describe ".insecure_bootstrap" do
    it "désactive la vérification de clé d'hôte pour le bootstrap mfsBSD" do
      conn = Beryl::SSH::Connection.insecure_bootstrap("web01.aloli.fr")
      conn.options["StrictHostKeyChecking"].should eq("no")
      conn.options["UserKnownHostsFile"].should eq("/dev/null")
    end

    it "conserve les valeurs par défaut utilisateur et port si non précisés" do
      conn = Beryl::SSH::Connection.insecure_bootstrap("web01.aloli.fr")
      conn.user.should eq("root")
      conn.port.should eq(22)
    end
  end
end
