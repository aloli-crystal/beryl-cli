require "../spec_helper"
require "file_utils"
require "../../src/beryl/zfs_keys"
require "../../src/beryl/zfs_keys/paper"

private KEY_A = "a" * 64
private KEY_B = "0123456789abcdef" * 4

# Identité age JETABLE (jamais la clé maîtresse du poste) : vrai chiffrement
# du coffre, sans trousseau. nil si `age-keygen` est absent.
private def throwaway_identity : {String, String}?
  return unless Process.find_executable("age-keygen")
  buf = IO::Memory.new
  return unless Process.run("age-keygen", output: buf, error: Process::Redirect::Close).success?
  text = buf.to_s
  identity = text.lines.find(&.starts_with?("AGE-SECRET-KEY-1")).try(&.strip)
  recipient = text.lines.find(&.starts_with?("# public key:")).try(&.split(' ', 4).last.strip)
  identity && recipient ? {identity, recipient} : nil
end

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "beryl-zfs-keys-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def write_key_file(path : String, hex : String) : Nil
  File.write(path, hex + "\n")
  File.chmod(path, 0o400)
end

private def sample_sheet(docs_url : String? = "https://beryl.example.net/") : Beryl::ZfsKeys::Paper::Sheet
  Beryl::ZfsKeys::Paper::Sheet.new(
    account: "initech", fqdn: "web-1.initech.example", host_ref: "initech/web-1.initech.example",
    var: "WEB_1",
    units: [
      Beryl::ZfsKeys::Paper::Unit.new("zdata", true, ["/data"]),
      Beryl::ZfsKeys::Paper::Unit.new("zroot/encrypted", false, ["/home", "/opt", "/usr/local/etc"]),
    ],
    hex: KEY_B, edited_at: Time.local(2026, 10, 29, 14, 5), docs_url: docs_url,
  )
end

describe Beryl::ZfsKeys do
  it "variable du coffre : nom court en majuscules, tirets → soulignés (convention des secrets par serveur)" do
    Beryl::ZfsKeys.vault_var("web-1").should eq("WEB_1")
    Beryl::ZfsKeys.vault_var("db.main").should eq("DB_MAIN")
  end

  it "empreinte : 16 caractères du SHA-256 par groupes de 4, stable, ne contient pas la clé" do
    fp = Beryl::ZfsKeys.fingerprint(KEY_B)
    fp.should match(/\A[0-9a-f]{4}( [0-9a-f]{4}){3}\z/)
    fp.should eq(Beryl::ZfsKeys.fingerprint(KEY_B))
    fp.should_not eq(Beryl::ZfsKeys.fingerprint(KEY_A))
    KEY_B.should_not contain(fp.delete(' '))
  end

  describe ".reconcile" do
    it "coffre d'abord, fichier en repli, nil sans aucun exemplaire" do
      Beryl::ZfsKeys.reconcile(KEY_A, nil, "WEB_1", "/x.key").not_nil!.origin.should eq("coffre")
      Beryl::ZfsKeys.reconcile(nil, KEY_A, "WEB_1", "/x.key").not_nil!.origin.should eq("fichier")
      Beryl::ZfsKeys.reconcile(KEY_A, KEY_A, "WEB_1", "/x.key").not_nil!.origin.should eq("coffre")
      Beryl::ZfsKeys.reconcile(nil, nil, "WEB_1", "/x.key").should be_nil
    end

    it "deux exemplaires différents → erreur, jamais de choix silencieux" do
      expect_raises(Beryl::ZfsKeys::Conflict, /divergente.*WEB_1.*\/x\.key/) do
        Beryl::ZfsKeys.reconcile(KEY_A, KEY_B, "WEB_1", "/x.key")
      end
    end
  end

  describe ".resolve" do
    it "lit le coffre chargé (section [tang]) et le fichier 0400 ; divergence → Conflict" do
      with_tmpdir do |dir|
        path = File.join(dir, "web-1.key")
        env = Beryl::Config::EnvFile.new(File.join(dir, ".env.yml"), Beryl::Config::EnvFile::Data.new)
        Beryl::ZfsKeys.resolve(env, "initech", "WEB_1", path).should be_nil
        write_key_file(path, KEY_A)
        Beryl::ZfsKeys.resolve(env, "initech", "WEB_1", path).not_nil!.origin.should eq("fichier")
        env.set_account("initech", {"tang" => {"WEB_1" => KEY_A.upcase}})
        found = Beryl::ZfsKeys.resolve(env, "initech", "WEB_1", path).not_nil!
        {found.origin, found.hex}.should eq({"coffre", KEY_A})
        env.set_account("initech", {"tang" => {"WEB_1" => KEY_B}})
        expect_raises(Beryl::ZfsKeys::Conflict) { Beryl::ZfsKeys.resolve(env, "initech", "WEB_1", path) }
      end
    end

    it "valeur mal formée dans le coffre → InvalidKey" do
      env = Beryl::Config::EnvFile.new("/nulle-part/.env.yml", Beryl::Config::EnvFile::Data.new)
      env.set_account("initech", {"tang" => {"WEB_1" => "trop-court"}})
      expect_raises(Beryl::Encryption::InvalidKey, /coffre \[tang\] WEB_1/) do
        Beryl::ZfsKeys.resolve(env, "initech", "WEB_1", "/nulle-part/web-1.key")
      end
    end
  end

  describe ".insert" do
    it "ajoute dans une section [tang] existante sans toucher au reste" do
      plain = "# commentaire\n[ovh]\nOVH_APPLICATION_KEY = \"x\"\n\n[tang]\nDB = \"#{KEY_A}\"\n"
      updated, result = Beryl::ZfsKeys.insert(plain, "WEB_1", KEY_B)
      result.added?.should be_true
      updated.should start_with("# commentaire\n[ovh]\n")
      parsed = Beryl::Config::EnvFile.parse_vault_toml(updated)
      parsed["tang"].should eq({"DB" => KEY_A, "WEB_1" => KEY_B})
      parsed["ovh"]["OVH_APPLICATION_KEY"].should eq("x")
    end

    it "crée la section [tang] si absente" do
      updated, _ = Beryl::ZfsKeys.insert("[ovh]\nK = \"v\"", "WEB_1", KEY_B)
      Beryl::Config::EnvFile.parse_vault_toml(updated)["tang"].should eq({"WEB_1" => KEY_B})
    end

    it "même valeur → inchangé ; valeur différente → Conflict (jamais d'écrasement)" do
      plain = "[tang]\nWEB_1 = \"#{KEY_A}\"\n"
      updated, result = Beryl::ZfsKeys.insert(plain, "WEB_1", KEY_A)
      {updated, result.unchanged?}.should eq({plain, true})
      expect_raises(Beryl::ZfsKeys::Conflict, /AUTRE clé/) { Beryl::ZfsKeys.insert(plain, "WEB_1", KEY_B) }
    end
  end

  describe Beryl::ZfsKeys::Vault do
    it "range une clé dans un vrai coffre age (identité jetable), 0600, relisible ; refuse d'écraser" do
      pair = throwaway_identity
      next pending!("age-keygen absent") unless pair
      identity, recipient = pair
      with_tmpdir do |dir|
        path = File.join(dir, ".env.toml.age")
        File.write(path, Secrets::Vault.encrypt("[ovh]\nOVH_APPLICATION_KEY = \"x\"\n", recipient))
        vault = Beryl::ZfsKeys::Vault.new(path,
          ->(ct : String) { Secrets::Vault.decrypt(ct, identity) },
          ->(pt : String) { Secrets::Vault.encrypt(pt, recipient) })
        vault.read_key("WEB_1").should be_nil
        vault.store("WEB_1", KEY_A).added?.should be_true
        (File.info(path).permissions.value & 0o777).should eq(0o600)
        vault.read_key("WEB_1").should eq(KEY_A)
        plain = Secrets::Vault.decrypt(File.read(path), identity)
        Beryl::Config::EnvFile.parse_vault_toml(plain)["ovh"]["OVH_APPLICATION_KEY"].should eq("x")
        vault.store("WEB_1", KEY_A).unchanged?.should be_true
        expect_raises(Beryl::ZfsKeys::Conflict) { vault.store("WEB_1", KEY_B) }
        vault.read_key("WEB_1").should eq(KEY_A)
        Dir.children(dir).should eq([".env.toml.age"])
      end
    end
  end

  it "la section [tang] n'est jamais injectée dans ENV (sync, processus fils)" do
    env = Beryl::Config::EnvFile.new("/nulle-part/.env.yml", Beryl::Config::EnvFile::Data.new)
    env.set_account("initech", {"ovh" => {"BERYL_SPEC_OVH" => "v"}, "tang" => {"BERYL_SPEC_WEB_1" => KEY_A}})
    begin
      env.apply_all_to_env("initech", overwrite: true).should eq(1)
      ENV["BERYL_SPEC_OVH"]?.should eq("v")
      ENV["BERYL_SPEC_WEB_1"]?.should be_nil
      env.apply_to_env("initech", "tang", overwrite: true).should eq(0)
      ENV["BERYL_SPEC_WEB_1"]?.should be_nil
    ensure
      ENV.delete("BERYL_SPEC_OVH")
      ENV.delete("BERYL_SPEC_WEB_1")
    end
  end
end

describe Beryl::ZfsKeys::Paper do
  it "commande en une ligne : sh -c (csh), imports des pools data, load-key de chaque unité, montage" do
    Beryl::ZfsKeys::Paper.unlock_one_liner(sample_sheet).should eq(
      "sh -c 'K=#{KEY_B}; zpool import -N zdata; " \
      "for d in zdata zroot/encrypted; do printf %s $K | zfs load-key $d; done; zfs mount -a'"
    )
  end

  it "QR code SVG : carré, marge, un seul chemin" do
    svg = Beryl::ZfsKeys::Paper.qr_svg("https://beryl.example.net/")
    svg.should contain(%(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ))
    svg.scan(/<path /).size.should eq(1)
    svg.should contain("M4,4h1v1h-1z") # coin du motif de position, après la marge de 4 modules
  end

  it "feuille AsciiDoc : identité, empreinte, clé par groupes de 4, procédure sans beryl, commande beryl" do
    doc = Beryl::ZfsKeys::Paper.adoc(sample_sheet, with_docs_qr: true)
    doc.should contain("= Clé de chiffrement ZFS — web-1.initech.example")
    doc.should contain("| Société | initech")
    doc.should contain("`zdata` (/data) + `zroot/encrypted` (/home, /opt, /usr/local/etc)")
    doc.should contain("| Édité le | 29/10/2026 à 14:05")
    doc.should contain(Beryl::ZfsKeys.fingerprint(KEY_B))
    doc.should contain("0123 4567 89ab cdef 0123 4567 89ab cdef\n0123 4567 89ab cdef 0123 4567 89ab cdef")
    doc.should contain("zpool import -N zdata\nzfs load-key zdata\nzfs load-key zroot/encrypted\nzfs mount -a\n")
    doc.should contain("beryl unlock initech/web-1.initech.example --apply")
    doc.should contain("beryl unlock initech/web-1.initech.example --key-file <fichier> --apply")
    doc.should contain("image::qr-unlock.svg[")
    doc.should contain("https://beryl.example.net/")
    doc.should contain("image::qr-docs.svg[")
  end

  it "lien beryl non configuré : signalé, aucun QR de lien" do
    doc = Beryl::ZfsKeys::Paper.adoc(sample_sheet(nil))
    doc.should contain("keys_paper.docs_url")
    doc.should_not contain("qr-docs.svg")
  end

  it "PDF réel (asciicrystal-pdf) : 0600, intermédiaires supprimés, refus d'écraser" do
    next pending!("asciicrystal-pdf absent du PATH") unless Process.find_executable(Beryl::ZfsKeys::Paper::DEFAULT_CONVERTER)
    with_tmpdir do |dir|
      pdf = File.join(dir, "web-1.pdf")
      Beryl::ZfsKeys::Paper.write_pdf(sample_sheet, pdf)
      File.read(pdf)[0, 5].should eq("%PDF-")
      (File.info(pdf).permissions.value & 0o777).should eq(0o600)
      Dir.children(dir).should eq(["web-1.pdf"])
      expect_raises(Beryl::ZfsKeys::Paper::Error, /existe déjà/) { Beryl::ZfsKeys::Paper.write_pdf(sample_sheet, pdf) }
    end
  end

  it "convertisseur introuvable : erreur claire, rien ne reste" do
    with_tmpdir do |dir|
      pdf = File.join(dir, "web-1.pdf")
      expect_raises(Beryl::ZfsKeys::Paper::Error, /introuvable/) do
        Beryl::ZfsKeys::Paper.write_pdf(sample_sheet, pdf, "/nulle-part/asciicrystal-pdf")
      end
      Dir.children(dir).should be_empty
    end
  end
end
