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
