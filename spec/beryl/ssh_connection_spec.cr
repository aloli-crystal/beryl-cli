require "../spec_helper"

describe "Beryl.ssh_connection" do
  it "demande IPQoS=ef à l'appel (le shard n'impose rien)" do
    conn = Beryl.ssh_connection(host: "h", user: "admin")
    conn.options["IPQoS"].should eq("ef")
    conn.ssh_args("true").join(" ").should contain("-o IPQoS=ef")
  end

  it "laisse l'appelant surcharger une option commune" do
    Beryl.ssh_connection(host: "h", options: {"IPQoS" => "cs1"}).options["IPQoS"].should eq("cs1")
  end

  it "étend IPQoS au rebond par bastion (c'est lui qui traverse le réseau local)" do
    conn = Beryl.ssh_connection(host: "10.0.0.5", identity_file: "/k", options: {"ProxyJump" => "admin@bastion"})
    conn.ssh_args("true").join(" ").partition("ProxyCommand=")[2].should contain("-o IPQoS=ef")
  end

  it "est la SEULE fabrique de connexions de beryl" do
    offenders = Dir.glob("src/**/*.cr").reject(&.ends_with?("ssh_connection.cr")).select do |f|
      File.read(f).includes?("SSH::Connection.new")
    end
    offenders.should be_empty
  end
end

describe "Beryl::Apply.root_shell" do
  it "sudo pour un compte non root, direct pour root (ssh par commande)" do
    conn = Beryl.ssh_connection(host: "h", user: "admin")
    Beryl::Apply.root_shell(conn, "admin", persistent: false).should be_a(Beryl::Apply::SudoShell)
    Beryl::Apply.root_shell(conn, "root", persistent: false).should be_a(Beryl::Apply::SshShell)
  end

  it "désactivé par BERYL_SSH_PERSISTENT=0 : rend le shell classique" do
    ENV["BERYL_SSH_PERSISTENT"] = "0"
    conn = Beryl.ssh_connection(host: "h", user: "admin")
    Beryl::Apply.root_shell(conn, "admin").should be_a(Beryl::Apply::SudoShell)
  ensure
    ENV.delete("BERYL_SSH_PERSISTENT")
  end
end
