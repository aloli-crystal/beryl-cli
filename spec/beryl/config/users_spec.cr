require "../../spec_helper"
require "../../../src/beryl/config/users"

describe Beryl::Config::Users do
  it "lit la forme NOUVELLE (utilisateur en clé)" do
    y = YAML.parse("- deploy:\n    groups: [www, wheel]\n    shell: oh-my-zsh\n")
    e = Beryl::Config::Users.list(y.as_a).first
    e.name.should eq("deploy")
    e.shell.should eq("oh-my-zsh")
    e.shell_recipe.should eq("oh-my-zsh")
    e.shell_path.should be_nil
    e.fields[YAML::Any.new("groups")].as_a.map(&.as_s).should eq(["www", "wheel"])
  end

  it "lit la forme LEGACY (champ name) et retire le nom des champs" do
    y = YAML.parse("- name: deploy\n  groups: [wheel]\n")
    e = Beryl::Config::Users.list(y.as_a).first
    e.name.should eq("deploy")
    e.fields.has_key?(YAML::Any.new("name")).should be_false
  end

  it "classe le shell : chemin (/…) vs recette" do
    e = Beryl::Config::Users.list(YAML.parse("- root:\n    shell: /bin/csh\n").as_a).first
    e.shell_path.should eq("/bin/csh")
    e.shell_recipe.should be_nil
  end

  it "tolère un utilisateur sans champs (`- deploy:`)" do
    e = Beryl::Config::Users.list(YAML.parse("- deploy:\n").as_a).first
    e.name.should eq("deploy")
    e.fields.empty?.should be_true
  end

  it "build → forme nouvelle relisible (round-trip)" do
    fields = {YAML::Any.new("groups") => YAML.parse("[wheel]")}
    e = Beryl::Config::Users.entry(Beryl::Config::Users.build("admin", fields)).not_nil!
    e.name.should eq("admin")
    e.fields[YAML::Any.new("groups")].as_a.map(&.as_s).should eq(["wheel"])
  end
end
