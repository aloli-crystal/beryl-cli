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
