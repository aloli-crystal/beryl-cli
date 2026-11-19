require "../spec_helper"
require "../../src/beryl/unlock_gate"

# Exécute le VRAI script de la commande imposée sous /bin/sh, avec la demande
# dans SSH_ORIGINAL_COMMAND. Ni zpool ni zfs ici : une demande AUTORISÉE
# tente de les lancer (introuvables ici), une demande REFUSÉE sort en 126
# avec le message de refus.
private def gate(request : String) : {Int32, String}
  dir = File.tempname("beryl-gate")
  Dir.mkdir_p(dir)
  path = File.join(dir, "beryl-unlock")
  File.write(path, Beryl::UnlockGate::SCRIPT + "\n")
  err = IO::Memory.new
  st = Process.run("/bin/sh", [path], env: {"SSH_ORIGINAL_COMMAND" => request}, output: Process::Redirect::Close, error: err)
  {st.exit_code, err.to_s}
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Beryl::UnlockGate do
  it "laisse passer les opérations ZFS de beryl unlock" do
    [
      "zpool list -H -o name zdata",
      "zpool import -N 'zdata'",
      "zfs get -H -o value keystatus zroot/encrypted",
      "zfs load-key zroot/encrypted",
      "zfs mount -a -l",
      "zfs list -H -o name,mounted,mountpoint -r zroot/encrypted",
      "/usr/local/sbin/clevis-zfs unlock --no-mount --dataset zdata",
    ].each do |req|
      _, err = gate(req)
      err.should_not contain("refusée")
      # La commande a bien été LANCÉE (introuvable sur ce poste).
      err.should match(/not found|No such file/)
    end
  end

  it "refuse tout le reste : shell, autres commandes, noms douteux, arguments en trop" do
    [
      "",
      "sh",
      "id",
      "zfs destroy zdata",
      "zfs load-key zdata; rm -rf /",
      "zfs load-key -a",
      "zfs load-key zdata zother",
      "zpool import -N zdata -f",
      "zfs list -H -o name,mounted,mountpoint -r $(id)",
      "service sshd stop",
    ].each do |req|
      code, err = gate(req)
      code.should eq(126)
      err.should contain("refusée")
    end
  end

  it "ligne d'authorized_keys restreinte" do
    Beryl::UnlockGate.root_key_line("ssh-ed25519 AAAA x@y\n")
      .should eq(%(restrict,command="/usr/local/sbin/beryl-unlock" ssh-ed25519 AAAA x@y))
  end
end
