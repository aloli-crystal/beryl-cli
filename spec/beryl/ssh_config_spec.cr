require "../spec_helper"
require "file_utils"
require "../../src/beryl/ssh_config"

private FALLBACK_FIXTURE = File.expand_path(File.join(__DIR__, "..", "fixtures", "config", "vrack-fallback"))

private def fallback_root : Beryl::Config::Root
  Beryl::Config::Root.load(FALLBACK_FIXTURE)
end

private def fallback_hosts : Array(Beryl::Config::ResolvedHost)
  root = fallback_root
  root.all_hosts_by_fqdn.keys.map { |f| root.resolve(f) }
end

describe "Rebonds à replis (bastions du domaine)" do
  it "host caché : bastion préféré, puis les autres bastions du domaine, même user" do
    fallback_root.resolve("app1").proxy_jumps("admin").should eq [
      "admin@zb.initech.example", "admin@za.initech.example", "admin@zc.initech.example",
    ]
  end

  it "rebond hors des bastions du domaine : seul, sans repli" do
    fallback_root.resolve("viaother").proxy_jumps("admin").should eq ["admin@jump.other.example"]
  end

  it "host public ou bastion : aucun rebond" do
    fallback_root.resolve("pub").proxy_jumps.should be_empty
    fallback_root.resolve("za").proxy_jumps.should be_empty
  end

  it "connexion de beryl : ProxyCommand à replis, la clé à chaque saut" do
    args = fallback_root.resolve("app1").connection.ssh_args("uname -s")
    pc = args.find!(&.starts_with?("ProxyCommand=")).lchop("ProxyCommand=")
    pc.should start_with("sh -c '")
    pc.should contain("-W %h:%p admin@zb.initech.example")
    pc.should contain("-W %h:%p admin@zc.initech.example")
    args.should contain("admin@192.168.42.11")
  end
end

describe Beryl::SshConfig do
  it "un seul rebond : ProxyJump ; plusieurs : ProxyCommand ; aucun : rien" do
    Beryl::SshConfig.jump_options([] of String).should be_empty
    Beryl::SshConfig.jump_options(["a@b"]).should eq ["-o", "ProxyJump=a@b"]
    Beryl::SshConfig.jump_options(["a@b", "a@c"]).last.should start_with("ProxyCommand=sh -c '")
  end

  it "la chaîne s'arrête au premier bastion qui mène à la cible et annonce le repli" do
    dir = File.tempname("beryl-ssh-fallback")
    Dir.mkdir(dir)
    File.write(File.join(dir, "ssh"), "#!/bin/sh\nfor a; do last=$a; done\necho $last >> #{dir}/log\ncase $last in *dead*) exit 255;; esac\n")
    File.chmod(File.join(dir, "ssh"), 0o755)
    pc = Beryl::SshConfig.proxy_command(["u@dead1", "u@dead2", "u@ok", "u@spare"]).gsub("%h:%p", "t:22")
    err = IO::Memory.new
    st = Process.run("sh", ["-c", pc], env: {"PATH" => "#{dir}:/usr/bin:/bin"}, error: err)
    st.success?.should be_true
    File.read_lines(File.join(dir, "log")).should eq ["u@dead1", "u@dead2", "u@ok"]
    err.to_s.should contain("bastion u@dead1 injoignable, essai par u@dead2")
    err.to_s.should contain("bastion u@dead2 injoignable, essai par u@ok")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "render : hosts cachés seulement ; FQDN sans user ni clé, nom court complet" do
    out = Beryl::SshConfig.render(fallback_hosts)
    out.should contain("Host app1.initech.example\n  HostName 192.168.42.11\n  ProxyCommand sh -c '")
    out.should contain("Host app1\n  HostName 192.168.42.11\n  User admin\n  IdentityFile /keys/ops.key\n  IdentitiesOnly yes\n")
    out.should contain("# app1.initech.example — via zb, puis za, puis zc")
    out.should contain("Host viaother.initech.example\n  HostName 192.168.42.40\n  ProxyJump admin@jump.other.example\n")
    out.should_not contain("Host pub")
    out.should_not contain("Host za")
  end

  it "with_include : en tête, une seule fois" do
    added = Beryl::SshConfig.with_include("Host github.com\n  User git\n").not_nil!
    added.lines.reject { |l| l.starts_with?('#') }.first.should eq "Include beryl.conf"
    added.should end_with("Host github.com\n  User git\n")
    Beryl::SshConfig.with_include(added).should be_nil
  end
end
