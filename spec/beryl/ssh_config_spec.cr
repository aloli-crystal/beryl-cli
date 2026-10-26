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

  it "render : un fichier par société, TOUS les hosts, FQDN et nom court" do
    files = Beryl::SshConfig.render(fallback_hosts)
    files.keys.should eq ["initech"]
    out = files["initech"]
    out.should contain("# app1.initech.example — caché, via zb, puis za, puis zc\n" \
                       "Host app1 app1.initech.example\n  HostName 192.168.42.11\n" \
                       "  HostKeyAlias app1.initech.example\n  User admin\n  IdentityFile /keys/ops.key\n" \
                       "  IdentitiesOnly yes\n  ProxyCommand sh -c '")
    out.should contain("# pub.initech.example — public\nHost pub pub.initech.example\n  HostName pub.initech.example\n  User admin\n")
    out.lines.count(&.starts_with?("Host ")).should eq 6 # un bloc par host (za, zb, zc, app1, pub, viaother)
    out.should contain("# za.initech.example — bastion\nHost za za.initech.example\n")
    out.should contain("Host viaother viaother.initech.example\n  HostName 192.168.42.40\n" \
                       "  HostKeyAlias viaother.initech.example\n  User admin\n  ProxyJump admin@jump.other.example\n")
    out.should_not contain("HostKeyAlias pub.initech.example")
    out.should_not contain("old1") # groupe `anciens` en ssh_config: false
  end

  it "with_include : en tête, une seule fois" do
    added = Beryl::SshConfig.with_include("Host github.com\n  User git\n").not_nil!
    added.lines.reject(&.starts_with?('#')).first.should eq "Include beryl--*.conf"
    added.should end_with("\n\nHost github.com\n  User git\n")
    Beryl::SshConfig.with_include(added).should be_nil
  end

  it "with_include : remplace l'ancien `Include beryl.conf` (0.6.124)" do
    old = "#{Beryl::SshConfig::LEGACY_COMMENT}\nInclude beryl.conf\n\nHost github.com\n  User git\n"
    fixed = Beryl::SshConfig.with_include(old).not_nil!
    fixed.should eq "#{Beryl::SshConfig::INCLUDE_COMMENT}\nInclude beryl--*.conf\n\nHost github.com\n  User git\n"
    Beryl::SshConfig.with_include(fixed).should be_nil
  end

  it "ancien fichier retiré seulement s'il vient de beryl" do
    Beryl::SshConfig.legacy_generated?("#{Beryl::SshConfig::HEADER}\n\nHost a\n").should be_true
    Beryl::SshConfig.legacy_generated?("Host perso\n").should be_false
  end
end
