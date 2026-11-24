require "../spec_helper"
require "../../src/beryl/vuln_accept"

private def entries(yaml : String) : Array(Beryl::VulnAccept::Entry)
  Beryl::VulnAccept.entries(YAML.parse(yaml)["vuln_accepted"]?)
end

describe Beryl::VulnAccept do
  vulns = ["openssl111-1.1.1w_5", "mariadb123-server-12.3.3"]
  yaml = <<-Y
    vuln_accepted:
      openssl111:
        reason: "fin de vie, requis par Ruby 2.7"
        until: 2027-05-31
    Y

  it "sort le paquet accepté de l'alerte, mais l'affiche avec sa raison" do
    res = Beryl::VulnAccept.split(vulns, entries(yaml), "2026-11-24")
    res.alert.should eq ["mariadb123-server-12.3.3"]
    res.notes.should eq ["openssl111-1.1.1w_5 : faille acceptée jusqu'au 2027-05-31 — fin de vie, requis par Ruby 2.7"]
  end

  it "le jour de l'échéance compte encore, le lendemain l'acceptation est ÉCHUE" do
    Beryl::VulnAccept.split(vulns, entries(yaml), "2027-05-31").alert.should eq ["mariadb123-server-12.3.3"]
    res = Beryl::VulnAccept.split(vulns, entries(yaml), "2027-06-01")
    res.alert.should eq vulns
    res.notes.first.should contain("ÉCHUE le 2027-05-31")
  end

  it "sans raison ou sans date : refusée, le paquet reste en alerte" do
    ["vuln_accepted:\n  openssl111:\n    until: 2027-05-31\n",
     "vuln_accepted:\n  openssl111:\n    reason: x\n",
     "vuln_accepted:\n  openssl111:\n    reason: x\n    until: bientôt\n"].each do |y|
      res = Beryl::VulnAccept.split(vulns, entries(y), "2026-11-24")
      res.alert.should eq vulns
      res.notes.first.should contain("INVALIDE")
    end
  end

  it "nom exact : openssl111 n'accepte pas openssl111-devel" do
    res = Beryl::VulnAccept.split(["openssl111-devel-1.1.1w_5"], entries(yaml), "2026-11-24")
    res.alert.should eq ["openssl111-devel-1.1.1w_5"]
    res.notes.should be_empty
  end

  it "date écrite en texte acceptée" do
    y = "vuln_accepted:\n  openssl111:\n    reason: x\n    until: \"2027-05-31\"\n"
    Beryl::VulnAccept.split(vulns, entries(y), "2026-11-24").alert.should eq ["mariadb123-server-12.3.3"]
  end

  it "aucune clé : tout reste en alerte" do
    Beryl::VulnAccept.split(vulns, Beryl::VulnAccept.entries(nil), "2026-11-24").alert.should eq vulns
  end
end
