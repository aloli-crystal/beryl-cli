require "../../../spec_helper"

describe Beryl::Apply::GithubSshKey do
  it "est enregistrée sous `github-ssh-key`" do
    Beryl::Apply::Primitive["github-ssh-key"]?.should_not be_nil
  end

  it "key_material extrait le 2ᵉ champ (base64), vide si invalide" do
    Beryl::Apply::GithubSshKey.key_material("ssh-ed25519 AAAAC3xyz deploy@host").should eq("AAAAC3xyz")
    Beryl::Apply::GithubSshKey.key_material("garbage").should eq("")
  end

  it "payload : JSON {title, key}" do
    p = Beryl::Apply::GithubSshKey.payload("mon-titre", "ssh-ed25519 AAAA cmt")
    parsed = JSON.parse(p)
    parsed["title"].as_s.should eq("mon-titre")
    parsed["key"].as_s.should eq("ssh-ed25519 AAAA cmt")
  end

  it "already_present? compare le matériel, ignore le commentaire" do
    list = %([{"key":"ssh-ed25519 AAAA foo"},{"key":"ssh-rsa BBBB bar"}])
    Beryl::Apply::GithubSshKey.already_present?(list, "ssh-ed25519 AAAA autre-commentaire").should be_true
    Beryl::Apply::GithubSshKey.already_present?(list, "ssh-ed25519 CCCC x").should be_false
    Beryl::Apply::GithubSshKey.already_present?("[]", "ssh-ed25519 AAAA x").should be_false
  end
end
