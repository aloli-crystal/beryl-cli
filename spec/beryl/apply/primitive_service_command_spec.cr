require "../../spec_helper"

describe "Beryl::Apply::Primitive.service_command" do
  it "détache le démon de la session (stdin /dev/null, sortie dans un fichier relu)" do
    cmd = Beryl::Apply::Primitive.service_command("partiduo_admin", "start")
    cmd.should contain("service partiduo_admin start </dev/null >\"$out\" 2>&1")
    cmd.should contain("exit $rc")
  end

  it "conserve la sortie et le code de retour (exécution locale)" do
    script = Beryl::Apply::Primitive.service_command("x", "start").sub("service x start", "sh -c 'echo coucou; exit 3'")
    buf = IO::Memory.new
    status = Process.run("sh", ["-c", script], output: buf)
    status.exit_code.should eq(3)
    buf.to_s.should contain("coucou")
  end
end

describe "Beryl::Apply::Primitive.service_command (délai et démon)" do
  it "borne l'action par timeout(1) quand un délai est donné" do
    cmd = Beryl::Apply::Primitive.service_command("strongswan", "restart", timeout: 120)
    cmd.should contain("timeout --foreground -k 10 120 service strongswan restart </dev/null >\"$out\" 2>&1")
  end

  it "rend la main malgré un démon resté en arrière-plan (exécution locale)" do
    script = Beryl::Apply::Primitive.service_command("x", "restart").sub("service x restart", "sh -c '(sleep 30 &); echo relance'")
    buf = IO::Memory.new
    started = Time.instant
    status = Process.run("sh", ["-c", script], output: buf)
    (Time.instant - started).should be < 10.seconds
    status.exit_code.should eq(0)
    buf.to_s.should contain("relance")
  end
end
