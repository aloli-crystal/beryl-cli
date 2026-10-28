require "../../spec_helper"

private def params(h : Hash(String, String)) : Hash(String, YAML::Any)
  h.transform_values { |v| YAML::Any.new(v) }
end

describe "Beryl::Apply::Executor.skip_by_secret" do
  context = Beryl::Apply::Context.new(vars: {"hostname" => "quimeo-twin"})

  it "joue une étape if_secret quand la variante du serveur existe" do
    ENV["QUIMEO_TWIN__BERYL_SPEC_PW"] = "x"
    Beryl::Apply::Executor.skip_by_secret(params({"if_secret" => "BERYL_SPEC_PW"}), context).should be_nil
  ensure
    ENV.delete("QUIMEO_TWIN__BERYL_SPEC_PW")
  end

  it "saute une étape if_secret quand la variable est absente" do
    Beryl::Apply::Executor.skip_by_secret(params({"if_secret" => "BERYL_SPEC_ABSENT"}), context)
      .should eq("variable BERYL_SPEC_ABSENT absente du coffre (if_secret)")
  end

  it "joue une étape unless_secret quand la variable est absente" do
    Beryl::Apply::Executor.skip_by_secret(params({"unless_secret" => "BERYL_SPEC_ABSENT"}), context).should be_nil
  end

  it "saute une étape unless_secret quand la valeur commune existe" do
    ENV["BERYL_SPEC_PW"] = "x"
    Beryl::Apply::Executor.skip_by_secret(params({"unless_secret" => "BERYL_SPEC_PW"}), context)
      .should eq("variable BERYL_SPEC_PW présente dans le coffre (unless_secret)")
  ensure
    ENV.delete("BERYL_SPEC_PW")
  end

  it "joue toute étape sans condition" do
    Beryl::Apply::Executor.skip_by_secret(params({"path" => "/etc/x"}), context).should be_nil
  end
end

describe "Beryl::Apply.secret (variante vide du serveur)" do
  context = Beryl::Apply::Context.new(vars: {"hostname" => "quimeo-twin"})

  it "écarte la valeur commune quand la variante du serveur est déclarée vide" do
    ENV["BERYL_SPEC_PASS"] = "commun"
    ENV["QUIMEO_TWIN__BERYL_SPEC_PASS"] = ""
    Beryl::Apply.secret("BERYL_SPEC_PASS", context).should be_nil
    Beryl::Apply::Executor.skip_by_secret({"unless_secret" => YAML::Any.new("BERYL_SPEC_PASS")}, context).should be_nil
  ensure
    ENV.delete("BERYL_SPEC_PASS")
    ENV.delete("QUIMEO_TWIN__BERYL_SPEC_PASS")
  end

  it "prend la valeur commune sans variante du serveur" do
    ENV["BERYL_SPEC_PASS"] = "commun"
    Beryl::Apply.secret("BERYL_SPEC_PASS", context).should eq("commun")
  ensure
    ENV.delete("BERYL_SPEC_PASS")
  end
end
