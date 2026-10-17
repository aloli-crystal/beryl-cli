require "../../spec_helper"

private GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"

# Variable EFI Boot#### : attributs (4) + attributs d'entrée (4) + longueur du
# chemin (2) + libellé UTF-16LE terminé par un NUL + chemin de périphérique.
private def boot_var(label : String) : Bytes
  io = IO::Memory.new
  io.write_bytes(7_u32, IO::ByteFormat::LittleEndian)
  io.write_bytes(1_u32, IO::ByteFormat::LittleEndian)
  io.write_bytes(4_u16, IO::ByteFormat::LittleEndian)
  label.each_char { |c| io.write_bytes(c.ord.to_u16, IO::ByteFormat::LittleEndian) }
  io.write_bytes(0_u16, IO::ByteFormat::LittleEndian)
  io.write(Bytes[0x04, 0x01, 0x2a, 0x00, 0x7f, 0xff, 0x04, 0x00])
  io.to_slice
end

private def boot_order(entries : Array(Int32)) : Bytes
  io = IO::Memory.new
  io.write_bytes(7_u32, IO::ByteFormat::LittleEndian)
  entries.each { |n| io.write_bytes(n.to_u16, IO::ByteFormat::LittleEndian) }
  io.to_slice
end

# Lance le script en essai à blanc sur un faux efivars ; renvoie sa sortie.
private def dry_run(entries : Hash(Int32, String), order : Array(Int32), disks : String) : String
  dir = File.join(Dir.tempdir, "beryl-efivars-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  entries.each { |n, label| File.write(File.join(dir, "Boot%04X-#{GUID}" % n), boot_var(label)) }
  File.write(File.join(dir, "BootOrder-#{GUID}"), boot_order(order))
  script = File.join(dir, "efi-boot-entry.sh")
  File.write(script, Beryl::Bootstrap::QemuInRescue::TEMPLATE_EFI_BOOT_ENTRY)
  buffer = IO::Memory.new
  Process.run("sh", [script], env: {"EFIVARS" => dir, "DISKS" => disks, "DRY" => "1"}, output: buffer, error: buffer)
  buffer.to_s
ensure
  FileUtils.rm_rf(dir) if dir
end

# Lignes de « ordre prévu » réduites à leur numéro (ou « ---- » + disque).
private def planned(output : String) : Array(String)
  lines = output.lines
  idx = lines.index!(&.includes?("ordre prévu"))
  lines[(idx + 1)..].map(&.strip).map { |l| l.starts_with?("----") ? l.split[2] : l.split.first }
end

# Entrées relevées sur tika (ASRock, Ryzen 5600X), 16 oct. 2026.
private TIKA = {
  5 => "UEFI: PXE IP4 P0 Intel(R) Ethernet Controller X550",
  6 => "UEFI: PXE IP4 P1 Intel(R) Ethernet Controller X550",
  7 => "UEFI: Built-in EFI Shell",
  8 => "UEFI OS",
  9 => "UEFI OS",
}

describe "efi-boot-entry.sh (essai à blanc)" do
  it "place FreeBSD juste après les démarrages réseau, le reste de l'ordre gardé" do
    text = dry_run(TIKA, [5, 6, 8, 9, 7], "/dev/nvme0n1 /dev/nvme1n1")
    text.should contain("0005  UEFI: PXE IP4 P0 Intel(R) Ethernet Controller X550")
    planned(text).should eq(["0005", "0006", "nvme0n1", "nvme1n1", "0008", "0009", "0007"])
  end

  it "remplace les entrées FreeBSD d'un bootstrap précédent" do
    entries = TIKA.merge({10 => "FreeBSD nvme0n1", 11 => "FreeBSD nvme1n1"})
    text = dry_run(entries, [5, 6, 10, 11, 8, 9, 7], "/dev/nvme0n1 /dev/nvme1n1")
    planned(text).should eq(["0005", "0006", "nvme0n1", "nvme1n1", "0008", "0009", "0007"])
  end

  it "sans démarrage réseau en tête, FreeBSD passe en premier" do
    text = dry_run({8 => "UEFI OS", 7 => "UEFI: Built-in EFI Shell"}, [8, 7], "/dev/sda")
    planned(text).should eq(["sda", "0008", "0007"])
  end
end

describe "Beryl::Bootstrap::QemuInRescue" do
  it "envoie le script en base64 avec les disques et le mode" do
    cmd = Beryl::Bootstrap::QemuInRescue.efi_boot_entry_command(["/dev/nvme0n1", "/dev/nvme1n1"], dry: true)
    cmd.should contain("base64 -d")
    cmd.should contain("DISKS='/dev/nvme0n1 /dev/nvme1n1'")
    cmd.should contain("DRY=1 sh")
    b64 = cmd[%r{printf '%s' '?([A-Za-z0-9+/=]+)}, 1]
    Base64.decode_string(b64).should eq(Beryl::Bootstrap::QemuInRescue::TEMPLATE_EFI_BOOT_ENTRY)
  end

  it "reconnaît un retour au rescue quand admin est refusé" do
    Beryl::Bootstrap::QemuInRescue.denied_verdict("Linux").should eq(:rescue)
    Beryl::Bootstrap::QemuInRescue.denied_verdict("FreeBSD").should eq(:freebsd)
    Beryl::Bootstrap::QemuInRescue.denied_verdict(nil).should eq(:unknown)
  end
end
