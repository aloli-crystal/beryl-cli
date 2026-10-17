require "../../spec_helper"

describe "Beryl::Bootstrap::QemuInRescue.denied_verdict" do
  it "reconnaît un retour au rescue quand admin est refusé" do
    Beryl::Bootstrap::QemuInRescue.denied_verdict("Linux").should eq(:rescue)
  end

  it "reconnaît un FreeBSD démarré qui refuse la clé d'admin" do
    Beryl::Bootstrap::QemuInRescue.denied_verdict("FreeBSD").should eq(:freebsd)
  end

  it "ne conclut rien sans réponse" do
    Beryl::Bootstrap::QemuInRescue.denied_verdict(nil).should eq(:unknown)
  end
end
