require "file_utils"

# Clé d'hôte SSH (ed25519) d'un serveur, créée par beryl AU BOOTSTRAP et non
# par sshd au premier démarrage : beryl la connaît donc avant que le serveur
# ne réponde, et la publie dans le `known_hosts` de la société
# (`<société>/known_hosts`, dépôt de config), que `~/.ssh/beryl--<société>.conf`
# désigne (`GlobalKnownHostsFile`). Premier `ssh` sans question, et clé
# réellement vérifiée.
module Beryl::HostKey
  extend self

  FILE_NAME   = "known_hosts"
  REMOTE_PATH = "/etc/ssh/ssh_host_ed25519_key"
  HEADER      = "# Clés d'hôte des serveurs, posées par `beryl bootstrap` — ne pas modifier à la main."

  record Pair, private_key : String, public_key : String

  # Paire neuve, générée par `ssh-keygen` dans un dossier temporaire aussitôt
  # effacé : la clé privée ne reste que dans le script d'installation.
  def generate(comment : String) : Pair
    dir = File.tempname("beryl-hostkey")
    Dir.mkdir(dir, 0o700)
    path = File.join(dir, "key")
    err = IO::Memory.new
    st = Process.run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path],
      output: Process::Redirect::Close, error: err)
    raise "ssh-keygen a échoué : #{err.to_s.strip}" unless st.success?
    Pair.new(File.read(path), File.read("#{path}.pub").strip)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Empreinte SHA256 (comme l'affiche ssh), ou « ? ».
  def fingerprint(public_key : String) : String
    buf = IO::Memory.new
    st = Process.run("ssh-keygen", ["-l", "-f", "-"], input: IO::Memory.new(public_key + "\n"),
      output: buf, error: Process::Redirect::Close)
    st.success? ? (buf.to_s.split[1]? || "?") : "?"
  end

  # `known_hosts` de la société.
  def path(account_path : String) : String
    File.join(account_path, FILE_NAME)
  end

  # Contenu avec l'entrée de `fqdn` remplacée (ou ajoutée) ; commentaire de la
  # clé retiré, entrées triées, en-tête en tête. Pur.
  def with_entry(content : String, fqdn : String, public_key : String) : String
    type, b64 = public_key.split[0, 2]
    entries = content.each_line.map(&.strip)
      .reject { |l| l.empty? || l.starts_with?('#') || l.split.first? == fqdn }
      .to_a
    entries << "#{fqdn} #{type} #{b64}"
    ([HEADER] + entries.sort).join("\n") + "\n"
  end
end
