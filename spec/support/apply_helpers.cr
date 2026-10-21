# Helpers partagés par les specs de primitives apply.
require "yaml"
require "../../src/beryl/apply"

# Construit un hash de params de step depuis un fragment YAML.
def apply_params(yaml : String) : Hash(String, YAML::Any)
  h = {} of String => YAML::Any
  parsed = YAML.parse(yaml)
  if hh = parsed.as_h?
    hh.each { |k, v| h[k.as_s] = v }
  end
  h
end

# Instance enregistrée d'une primitive par son nom.
def prim(name : String) : Beryl::Apply::Primitive
  Beryl::Apply::Primitive[name]?.not_nil!
end

# Contexte d'exécution (clés protégées optionnelles).
def ctx(protected_keys : Array(String) = [] of String) : Beryl::Apply::Context
  Beryl::Apply::Context.new(protected_keys: protected_keys)
end

# Contexte d'un hôte Linux (systemd).
def linux_ctx : Beryl::Apply::Context
  Beryl::Apply::Context.new(os: Beryl::Apply::LINUX)
end
