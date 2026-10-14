require "../spec_helper"

private def host_key_line : String
  dir = File.tempname("beryl-hk")
  Dir.mkdir(dir)
  key = File.join(dir, "hk")
  Process.run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key])
  File.read("#{key}.pub").split(' ')[0, 2].join(' ')
ensure
  FileUtils.rm_rf(dir) if dir
end

private def known_hosts_file(content : String) : String
  path = File.tempname("beryl-known-hosts")
  File.write(path, content)
  path
end

describe Beryl::KnownHosts do
  it "décline chaque nom avec et sans port, sans doublon ni nom vide" do
    Beryl::KnownHosts.patterns(["a.example.net", "", "a.example.net"], 22)
      .should eq(["a.example.net", "[a.example.net]:22"])
    Beryl::KnownHosts.patterns(["1.2.3.4"], 2222)
      .should eq(["1.2.3.4", "[1.2.3.4]:22", "[1.2.3.4]:2222"])
  end

  it "retire les lignes du serveur (claires, hachées, port non standard), garde les autres et l'état d'avant en .old" do
    key = host_key_line
    other = "autre.example.net #{key}\n"
    before = "a.example.net,1.2.3.4 #{key}\n[a.example.net]:2222 #{key}\n#{other}"
    path = known_hosts_file(before)
    hashed = known_hosts_file("1.2.3.4 #{key}\n#{other}")
    Process.run("ssh-keygen", ["-H", "-f", hashed]).success?.should be_true
    begin
      Beryl::KnownHosts.forget(["a.example.net", "1.2.3.4"], 2222, path)
        .should eq(["a.example.net", "[a.example.net]:2222"])
      File.read(path).should eq(other)
      File.read("#{path}.old").should eq(before)
      Beryl::KnownHosts.forget(["1.2.3.4"], 22, hashed).should eq(["1.2.3.4"])
      File.read(hashed).lines.size.should eq(1)
    ensure
      [path, "#{path}.old", hashed, "#{hashed}.old"].each { |f| File.delete?(f) }
    end
  end

  it "ne réécrit rien si le serveur est inconnu ou si le fichier n'existe pas" do
    path = known_hosts_file("autre.example.net #{host_key_line}\n")
    begin
      Beryl::KnownHosts.forget(["a.example.net"], 22, path).should be_empty
      File.exists?("#{path}.old").should be_false
      Beryl::KnownHosts.forget(["a.example.net"], 22, "#{path}.absent").should be_empty
    ensure
      File.delete?(path)
    end
  end
end
