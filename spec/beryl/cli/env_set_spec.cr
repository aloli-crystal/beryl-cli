require "../../spec_helper"
require "../../../src/beryl/cli/env"

PEM = "-----BEGIN PRIVATE KEY-----\nMIIJQwIBADANBgkqhkiG9w0BAQEFAASC\nCS0wggkpAgEAAoICAQC7\n-----END PRIVATE KEY-----\n"

VAULT = <<-TOML
  # Coffre quimeo — notes de Philippe : ne pas retirer.
  [mail]
  SMTP_RELAY_USER = "relais@example.net"

  [ovh]
  OVH_APPLICATION_KEY = "abc"
  TOML

private def read(plaintext : String, section : String, var : String) : String?
  Beryl::Config::EnvFile.parse_vault_toml(plaintext)[section]?.try(&.[var]?)
end

describe "beryl env set (insertion ciblée)" do
  it "section absente : ajoutée à la fin ; clé PEM relue À L'IDENTIQUE (retour final compris)" do
    res = Beryl::CLI::Env.insert_var(VAULT, "builder", "POUDRIERE_SIGNING_KEY", PEM).not_nil!
    read(res, "builder", "POUDRIERE_SIGNING_KEY").should eq(PEM)
    read(res, "mail", "SMTP_RELAY_USER").should eq("relais@example.net")
    res.should contain("# Coffre quimeo — notes de Philippe : ne pas retirer.")
  end

  it "section présente : clé ajoutée sous son en-tête, le reste intact" do
    res = Beryl::CLI::Env.insert_var(VAULT, "mail", "SMTP_RELAY_TO", "ops@example.net").not_nil!
    read(res, "mail", "SMTP_RELAY_TO").should eq("ops@example.net")
    read(res, "ovh", "OVH_APPLICATION_KEY").should eq("abc")
  end

  it "clé déjà présente → refusée (nil), jamais d'écrasement silencieux" do
    Beryl::CLI::Env.insert_var(VAULT, "mail", "SMTP_RELAY_USER", "autre@example.net").should be_nil
  end

  it "guillemets et antislashs d'une valeur d'une ligne : relue à l'identique" do
    v = %q(pa"ss\wo\"rd)
    res = Beryl::CLI::Env.insert_var(VAULT, "mail", "SMTP_RELAY_PASSWORD", v).not_nil!
    read(res, "mail", "SMTP_RELAY_PASSWORD").should eq(v)
  end

  it "SECTION.VAR : noms simples seulement" do
    Beryl::CLI::Env.split_var("builder.POUDRIERE_SIGNING_KEY").should eq({"builder", "POUDRIERE_SIGNING_KEY"})
    Beryl::CLI::Env.split_var("POUDRIERE_SIGNING_KEY").should be_nil
    Beryl::CLI::Env.split_var("a.b.c").should be_nil
  end
end

describe "beryl env set --replace / unset (retrait ciblé)" do
  it "retire une variable simple, garde commentaires et voisines" do
    res = Beryl::CLI::Env.remove_var(VAULT, "mail", "SMTP_RELAY_USER").not_nil!
    res.should contain("notes de Philippe")
    read(res, "mail", "SMTP_RELAY_USER").should be_nil
    read(res, "ovh", "OVH_APPLICATION_KEY").should eq("abc")
  end

  it "retire une chaîne multi-ligne ''' en entier" do
    with_pem = Beryl::CLI::Env.insert_var(VAULT, "builder", "KEY", PEM).not_nil!
    res = Beryl::CLI::Env.remove_var(with_pem, "builder", "KEY").not_nil!
    res.should_not contain("PRIVATE KEY")
    Beryl::Config::EnvFile.parse_vault_toml(res)["builder"]?.try(&.empty?).should be_true
    read(res, "mail", "SMTP_RELAY_USER").should eq("relais@example.net")
  end

  it "ne touche pas une variable de même nom dans une autre section" do
    v = VAULT + "\n[autre]\nSMTP_RELAY_USER = \"x@example.net\"\n"
    res = Beryl::CLI::Env.remove_var(v, "autre", "SMTP_RELAY_USER").not_nil!
    read(res, "mail", "SMTP_RELAY_USER").should eq("relais@example.net")
    read(res, "autre", "SMTP_RELAY_USER").should be_nil
  end

  it "remplacement = retrait puis insertion" do
    res = Beryl::CLI::Env.insert_var(Beryl::CLI::Env.remove_var(VAULT, "mail", "SMTP_RELAY_USER").not_nil!,
      "mail", "SMTP_RELAY_USER", "monit@example.org").not_nil!
    read(res, "mail", "SMTP_RELAY_USER").should eq("monit@example.org")
    Beryl::CLI::Env.same_except?(Beryl::Config::EnvFile.parse_vault_toml(VAULT),
      Beryl::Config::EnvFile.parse_vault_toml(res), "mail", "SMTP_RELAY_USER").should be_true
  end

  it "variable absente : nil" do
    Beryl::CLI::Env.remove_var(VAULT, "mail", "ABSENTE").should be_nil
  end

  it "same_except? détecte une autre variable modifiée" do
    a = Beryl::Config::EnvFile.parse_vault_toml(VAULT)
    b = Beryl::Config::EnvFile.parse_vault_toml(VAULT.sub("abc", "xyz"))
    Beryl::CLI::Env.same_except?(a, b, "mail", "SMTP_RELAY_USER").should be_false
  end

  it "list : noms seulement, jamais les valeurs" do
    with_pem = Beryl::CLI::Env.insert_var(VAULT, "builder", "KEY", PEM).not_nil!
    out = Beryl::CLI::Env.list_text(Beryl::Config::EnvFile.parse_vault_toml(with_pem))
    out.should eq("[builder]\n  KEY (4 lignes)\n\n[mail]\n  SMTP_RELAY_USER\n\n[ovh]\n  OVH_APPLICATION_KEY\n")
    out.should_not contain("relais@example.net")
  end
end

describe "beryl env : société [SECTION [VAR]]" do
  it "accepte société, section, section+VAR (espace ou point)" do
    Beryl::CLI::Env.target(["aloli"]).should eq({"aloli", nil, nil})
    Beryl::CLI::Env.target(["aloli", "mail"]).should eq({"aloli", "mail", nil})
    Beryl::CLI::Env.target(["aloli", "mail", "SMTP_RELAY_USER"]).should eq({"aloli", "mail", "SMTP_RELAY_USER"})
    Beryl::CLI::Env.target(["aloli", "mail.SMTP_RELAY_USER"]).should eq({"aloli", "mail", "SMTP_RELAY_USER"})
    Beryl::CLI::Env.target(["aloli.mail"]).should eq({"aloli", "mail", nil})
    Beryl::CLI::Env.target(["aloli.mail.SMTP_RELAY_USER"]).should eq({"aloli", "mail", "SMTP_RELAY_USER"})
    Beryl::CLI::Env.target(["aloli.mail", "X"]).should be_nil
    Beryl::CLI::Env.target(["aloli..X"]).should be_nil
  end

  it "refuse les formes invalides" do
    Beryl::CLI::Env.target([] of String).should be_nil
    Beryl::CLI::Env.target(["aloli", "a.b.c"]).should be_nil
    Beryl::CLI::Env.target(["aloli", "mail", "X", "Y"]).should be_nil
    Beryl::CLI::Env.target(["aloli", "mail", "X-Y"]).should be_nil
  end

  it "show filtré : section triée, valeurs en TOML" do
    Beryl::CLI::Env.show_text("mail", {"Z" => "z", "A" => "a\"b"})
      .should eq("[mail]\nA = \"a\\\"b\"\nZ = \"z\"\n")
  end
end
