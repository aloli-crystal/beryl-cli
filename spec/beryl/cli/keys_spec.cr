require "../../spec_helper"
require "file_utils"
require "../../../src/beryl/cli/keys"
require "../../../src/beryl/cli/unlock"
require "../../../src/beryl/cli/session_log"

private KEY_A = "a" * 64
private KEY_B = "0123456789abcdef" * 4

# Arborescence de config jetable : société initech, domaine initech.example,
# serveur web-1 (pool data zdata chiffré + datasets zroot du profil standard).
private def with_config(&)
  root = File.join(Dir.tempdir, "beryl-keys-spec-#{Random::Secure.hex(6)}")
  dom = File.join(root, "initech", "initech.example")
  Dir.mkdir_p(dom)
  File.write(File.join(root, "initech", "initech.example.yml"), "ssh_keys:\n  - ssh-ed25519 AAAA admin@initech.example\n")
  File.write(File.join(dom, "web-1.host.yml"), <<-YAML)
    freebsd:
      zfs:
        zdata:
          disks: [/dev/ada1]
          encryption: true
          mountpoint: /data
          raid: 0
        zroot:
          boot: true
          disks: [/dev/ada0]
          encryption: true
          profile: standard
          raid: 0
    YAML
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def web1(root : String) : Beryl::Config::ResolvedHost
  Beryl::Config::Root.load(root).resolve("web-1", account_hint: "initech")
end

private def throwaway_identity : {String, String}?
  return unless Process.find_executable("age-keygen")
  buf = IO::Memory.new
  return unless Process.run("age-keygen", output: buf, error: Process::Redirect::Close).success?
  text = buf.to_s
  identity = text.lines.find(&.starts_with?("AGE-SECRET-KEY-1")).try(&.strip)
  recipient = text.lines.find(&.starts_with?("# public key:")).try(&.split(' ', 4).last.strip)
  identity && recipient ? {identity, recipient} : nil
end

describe Beryl::CLI::KeyStore do
  it "chemins et variable du serveur" do
    with_config do |root|
      host = web1(root)
      Beryl::CLI::KeyStore.file_path(root, host).should eq(File.join(root, "initech", "initech.example", "web-1.key"))
      Beryl::CLI::KeyStore.var(host).should eq("WEB_1")
      Beryl::CLI::KeyStore.vault_path(host).should eq(File.join(root, "initech", ".env.toml.age"))
    end
  end

  it "obtain_or_create : clé neuve dans le fichier (0400) si aucune, sinon celle du coffre" do
    with_config do |root|
      host = web1(root)
      hex, created = Beryl::CLI::KeyStore.obtain_or_create(root, host)
      created.should be_true
      Beryl::Encryption.read(Beryl::CLI::KeyStore.file_path(root, host)).should eq(hex)
      Beryl::CLI::KeyStore.obtain_or_create(root, host).should eq({hex, false})
      host.env_file.set_account("initech", {"tang" => {"WEB_1" => KEY_B}})
      expect_raises(Beryl::ZfsKeys::Conflict) { Beryl::CLI::KeyStore.obtain_or_create(root, host) }
    end
  end

  it "ensure_in_vault : coffre absent → avertissement, rien n'est créé" do
    with_config do |root|
      host = web1(root)
      logs = [] of String
      Beryl::CLI::KeyStore.ensure_in_vault(host, KEY_A) { |m| logs << m }.should be_false
      logs.join.should contain("beryl keys import initech --apply")
      File.exists?(Beryl::CLI::KeyStore.vault_path(host)).should be_false
    end
  end

  it "ensure_in_vault : range dans un vrai coffre age (identité jetable), idempotent, Conflict sinon" do
    pair = throwaway_identity
    next pending!("age-keygen absent") unless pair
    identity, recipient = pair
    with_config do |root|
      host = web1(root)
      path = Beryl::CLI::KeyStore.vault_path(host)
      File.write(path, Secrets::Vault.encrypt("[ovh]\nOVH_APPLICATION_KEY = \"x\"\n", recipient))
      vault = Beryl::ZfsKeys::Vault.new(path,
        ->(ct : String) { Secrets::Vault.decrypt(ct, identity) },
        ->(pt : String) { Secrets::Vault.encrypt(pt, recipient) })
      logs = [] of String
      Beryl::CLI::KeyStore.ensure_in_vault(host, KEY_A, vault: vault) { |m| logs << m }.should be_true
      logs.first.should contain("[tang] WEB_1")
      vault.read_key("WEB_1").should eq(KEY_A)
      Beryl::CLI::KeyStore.ensure_in_vault(host, KEY_A, vault: vault) { |m| logs << m }.should be_true
      logs.last.should contain("déjà dans le coffre")
      expect_raises(Beryl::ZfsKeys::Conflict) do
        Beryl::CLI::KeyStore.ensure_in_vault(host, KEY_B, vault: vault) { |m| logs << m }
      end
    end
  end
end

describe Beryl::CLI::Keys do
  it "unités chiffrées : pools data (à importer) puis encryptionroot du zroot" do
    with_config do |root|
      units = Beryl::CLI::Keys.units(web1(root))
      units.map { |u| {u.name, u.import, u.mountpoints} }.should eq([
        {"zdata", true, ["/data"]},
        {"zroot/encrypted", false, ["/home", "/opt", "/usr/local/etc"]},
      ])
    end
  end

  it "réglage keys_paper.docs_url lu dans la config mergée" do
    with_config do |root|
      Beryl::CLI::Keys.paper_setting(web1(root), "docs_url").should be_nil
      File.write(File.join(root, "_defaults.yml"), "keys_paper:\n  docs_url: https://beryl.example.net/\n")
      Beryl::CLI::Keys.paper_setting(web1(root), "docs_url").should eq("https://beryl.example.net/")
    end
  end

  it "dossier de sortie du PDF : refusé s'il manque, s'il est dans un dépôt git ou sous la config" do
    with_config do |root|
      outdir = File.expand_path(File.join(root, "..", "beryl-keys-out-#{Random::Secure.hex(4)}"))
      begin
        Beryl::CLI::Keys.out_dir_refusal(File.join(root, "absent"), root).not_nil!.should contain("pas un dossier")
        Beryl::CLI::Keys.out_dir_refusal(File.join(root, "initech"), root).not_nil!.should contain("sous la configuration")
        Dir.mkdir_p(File.join(outdir, ".git"))
        Dir.mkdir_p(File.join(outdir, "papier"))
        Beryl::CLI::Keys.out_dir_refusal(File.join(outdir, "papier"), root).not_nil!.should contain("dépôt git")
        FileUtils.rm_rf(File.join(outdir, ".git"))
        Beryl::CLI::Keys.out_dir_refusal(File.join(outdir, "papier"), root).should be_nil
      ensure
        FileUtils.rm_rf(outdir)
      end
    end
  end

  it "import et paper en essai à blanc : n'écrivent rien" do
    with_config do |root|
      host = web1(root)
      Beryl::Encryption.write_new(Beryl::CLI::KeyStore.file_path(root, host))
      outdir = File.join(Dir.tempdir, "beryl-keys-out-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(outdir)
      begin
        Beryl::CLI::Keys.run(root, ["import", "initech"]).should eq(0)
        File.exists?(Beryl::CLI::KeyStore.vault_path(host)).should be_false
        Beryl::CLI::Keys.run(root, ["paper", "initech/web-1", "--out", outdir]).should eq(0)
        Dir.children(outdir).should be_empty
        Beryl::CLI::Keys.run(root, ["paper", "initech/web-1"]).should eq(64)
      ensure
        FileUtils.rm_rf(outdir)
      end
    end
  end
end

describe "Beryl::CLI::Unlock.read_key_option" do
  it "fichier : blancs et majuscules tolérés (clé recopiée du papier)" do
    path = File.join(Dir.tempdir, "beryl-keyfile-#{Random::Secure.hex(4)}")
    File.write(path, Beryl::ZfsKeys.groups(KEY_B.upcase) + "\n")
    File.chmod(path, 0o400)
    begin
      Beryl::CLI::Unlock.read_key_option(path).should eq(KEY_B)
    ensure
      File.delete(path)
    end
  end

  it "entrée standard (tube) ; fichier absent ou clé mal formée → InvalidKey" do
    Beryl::CLI::Unlock.read_key_option("-", IO::Memory.new(KEY_A + "\n")).should eq(KEY_A)
    expect_raises(Beryl::Encryption::InvalidKey, /introuvable/) { Beryl::CLI::Unlock.read_key_option("/nulle-part/cle") }
    expect_raises(Beryl::Encryption::InvalidKey, /taille/) { Beryl::CLI::Unlock.read_key_option("-", IO::Memory.new("abcd")) }
  end
end

describe "journal de session et clés ZFS" do
  it "ni `keys`, ni `unlock --key-file` ne sont journalisés" do
    Beryl::CLI::SessionLog.wanted?("keys", ["paper", "initech"], false, false).should be_false
    Beryl::CLI::SessionLog.wanted?("unlock", ["web-1", "--key-file", "-"], false, false).should be_false
    Beryl::CLI::SessionLog.wanted?("unlock", ["web-1", "--key-file=/x"], false, false).should be_false
    Beryl::CLI::SessionLog.wanted?("unlock", ["web-1", "--apply"], false, false).should be_true
  end
end
