require "../../spec_helper"
require "file_utils"

describe Beryl::Config::Loader do
  describe ".defaults_path" do
    it "préfère `_defaults.yml` (pluriel), repli `_default.yml` (legacy)" do
      dir = File.join(Dir.tempdir, "beryl-defaults-spec")
      Dir.mkdir_p(dir)
      legacy = File.join(dir, "_default.yml")
      plural = File.join(dir, "_defaults.yml")
      begin
        # absent → on renvoie le chemin legacy par défaut
        Beryl::Config::Loader.defaults_path(dir).should eq(legacy)
        # legacy seul → legacy
        File.write(legacy, "os: freebsd\n")
        Beryl::Config::Loader.defaults_path(dir).should eq(legacy)
        # pluriel présent → PRÉFÉRÉ
        File.write(plural, "os: freebsd\n")
        Beryl::Config::Loader.defaults_path(dir).should eq(plural)
      ensure
        File.delete(legacy) if File.exists?(legacy)
        File.delete(plural) if File.exists?(plural)
        Dir.delete(dir) if Dir.exists?(dir)
      end
    end
  end

  describe ".load_domains" do
    it "ignore les sous-dossiers de service (sans point) — un domaine est un FQDN" do
      root = File.join(Dir.tempdir, "beryl-load-domains-spec")
      Dir.mkdir_p(File.join(root, "example.net"))
      Dir.mkdir_p(File.join(root, "recipes"))
      Dir.mkdir_p(File.join(root, "info"))
      begin
        # `recipes`/`info` (sans point) sont des dossiers de service, pas
        # des domaines ; seul `example.net` (FQDN) est retenu.
        Beryl::Config::Loader.load_domains(root).keys.should eq(["example.net"])
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
end
