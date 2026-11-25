require "digest/sha256"
require "../../spec_helper"

# Les sondes combinées sont jouées pour de vrai dans un `sh` local : stat BSD
# (macOS) ou GNU (Linux, CI), comme sur FreeBSD ou Linux côté serveur.
private def local_os : String
  {% if flag?(:linux) %} Beryl::Apply::LINUX {% else %} Beryl::Apply::FREEBSD {% end %}
end

private def run_sh(script : String) : String
  stdout = IO::Memory.new
  Process.run("sh", ["-c", script], output: stdout).success?.should be_true
  stdout.to_s
end

describe Beryl::Apply::PathState do
  it "lit empreinte, mode et propriétaire d'un fichier en un seul appel" do
    dir = File.tempname("beryl-state")
    Dir.mkdir(dir)
    path = File.join(dir, "f.conf")
    File.write(path, "abc\n")
    File.chmod(path, 0o640)
    state = Beryl::Apply::PathState.parse(run_sh(Beryl::Apply::Posix.file_state(path, local_os)))
    state.head.should eq(Digest::SHA256.hexdigest("abc\n"))
    state.mode.should eq("640")
    state.owner.not_nil!.should match(/\A[^:\s]+:[^:\s]+\z/)
    state.mode_differs?("0640").should be_false
    state.mode_differs?("0644").should be_true
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "fichier absent : empreinte vide, ni mode ni propriétaire" do
    state = Beryl::Apply::PathState.parse(run_sh(Beryl::Apply::Posix.file_state("/nonexistent/beryl", local_os)))
    state.head.should eq("")
    state.mode.should be_nil
    state.owner.should be_nil
    state.owner_differs?("root").should be_true
  end

  it "distingue dossier, autre chose et absent" do
    dir = File.tempname("beryl-state")
    Dir.mkdir(dir)
    File.write(File.join(dir, "f"), "")
    Beryl::Apply::PathState.parse(run_sh(Beryl::Apply::Posix.dir_state(dir, local_os))).head.should eq("dir")
    Beryl::Apply::PathState.parse(run_sh(Beryl::Apply::Posix.dir_state(File.join(dir, "f"), local_os))).head.should eq("other")
    Beryl::Apply::PathState.parse(run_sh(Beryl::Apply::Posix.dir_state(File.join(dir, "x"), local_os))).head.should eq("absent")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "owner sans groupe : ne compare que le propriétaire" do
    state = Beryl::Apply::PathState.parse("dir\n700 postgres:postgres\n")
    state.owner_differs?("postgres").should be_false
    state.owner_differs?("postgres:postgres").should be_false
    state.owner_differs?("postgres:wheel").should be_true
    state.owner_differs?("root").should be_true
  end
end
