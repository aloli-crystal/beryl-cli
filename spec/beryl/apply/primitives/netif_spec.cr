require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::Netif do
  it "configure l'IP (persistant + immédiat) si l'iface n'en a aucune" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 inet 2>/, stdout: "") # aucune IPv4
    shell.stub(/sysrc -n/, stdout: "")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.10}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/ifconfig_ix1=inet 192.168.42.10/).should be_true # sysrc (valeur quotée)
    shell.ran?(%r{ifconfig ix1 inet 192.168.42.10 netmask 255.255.255.0}).should be_true
    shell.ran?(/-alias/).should be_false # rien à retirer
  end

  it "skip si l'iface porte exactement l'IP voulue et rc.conf est à jour" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 inet 2>/, stdout: "192.168.42.10")
    shell.stub(/sysrc -n/, stdout: "inet 192.168.42.10 netmask 255.255.255.0")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.10}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.ran?(/ifconfig_ix1=inet/).should be_false
  end

  it "change l'IP : retire l'ancienne et pose la nouvelle" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 inet 2>/, stdout: "192.168.42.3") # ancienne IP
    shell.stub(/sysrc -n/, stdout: "inet 192.168.42.3 netmask 255.255.255.0")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.4}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{ifconfig ix1 inet 192.168.42.3 -alias}).should be_true  # ancienne retirée
    shell.ran?(%r{ifconfig ix1 inet 192.168.42.4 netmask}).should be_true # nouvelle posée
    shell.ran?(/ifconfig_ix1=inet 192.168.42.4/).should be_true           # rc.conf à jour
  end

  it "réconcilie si l'ancienne et la nouvelle coexistent (ne skip pas)" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 inet 2>/, stdout: "192.168.42.3\n192.168.42.4") # les deux
    shell.stub(/sysrc -n/, stdout: "inet 192.168.42.4 netmask 255.255.255.0")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.4}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{ifconfig ix1 inet 192.168.42.3 -alias}).should be_true # retire la 3 résiduelle
  end

  it "échoue si `ip` est vide" do
    shell = FakeShell.new
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: \"\"}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end

  it "échoue tôt si l'interface n'existe pas et liste les dispo (rien écrit)" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 2>/, exit_code: 1)        # ix1 absent
    shell.stub(/ifconfig -l/, stdout: "igb0 igb1 lo0") # interfaces réelles
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.3}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("igb1")
    shell.ran?(/sysrc ifconfig_ix1=/).should be_false # pas d'entrée parasite dans rc.conf
  end

  it "auto-détecte le NIC vRack quand iface vaut auto" do
    shell = FakeShell.new
    shell.stub(/for i in .*ifconfig -l ether/, stdout: "ixl1\n") # 1 seul candidat
    shell.stub(/ifconfig ixl1 inet 2>/, stdout: "")              # pas encore d'IPv4
    shell.stub(/sysrc -n/, stdout: "")
    result = prim("netif").apply(
      shell, apply_params("{iface: auto, ip: 192.168.42.11}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(/ifconfig_ixl1=inet 192.168.42.11/).should be_true
  end

  it "échoue (auto) si plusieurs NIC candidats — ambigu" do
    shell = FakeShell.new
    shell.stub(/for i in .*ifconfig -l ether/, stdout: "ixl1\nixl2\n")
    result = prim("netif").apply(
      shell, apply_params("{iface: auto, ip: 192.168.42.11}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("ambig")
  end

  it "échoue (auto) si aucun NIC candidat" do
    shell = FakeShell.new
    shell.stub(/for i in .*ifconfig -l ether/, stdout: "")
    result = prim("netif").apply(
      shell, apply_params("{iface: auto, ip: 192.168.42.11}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
  end

  it "mode alias : ajoute l'IP en alias SANS retirer les autres ni persister (rotation)" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 inet 2>/, stdout: "192.168.42.31") # IP primaire en place
    shell.stub(/sysrc -n/, stdout: "inet 192.168.42.31 netmask 255.255.255.0")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.131, alias: true}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.ran?(%r{ifconfig ix1 inet 192.168.42.131 netmask 255.255.255.0 alias}).should be_true
    shell.ran?(/-alias/).should be_false        # ne retire pas l'ancienne
    shell.ran?(/ifconfig_ix1=/).should be_false # ne persiste pas (pas de sysrc)
  end

  it "mode alias : skip si l'iface porte déjà l'IP" do
    shell = FakeShell.new
    shell.stub(/ifconfig ix1 inet 2>/, stdout: "192.168.42.31 192.168.42.131")
    result = prim("netif").apply(
      shell, apply_params("{iface: ix1, ip: 192.168.42.131, alias: true}"), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
  end
end
