module Beryl::Config
  # Un domaine (ex: `aloli.net`). Existe dès qu'il y a un
  # `<domaine>.yml` à la racine de `~/.config/beryl/`. Le dossier
  # `~/.config/beryl/<domaine>/` est créé à la demande (pas vide).
  #
  # Le fichier porte l'identité du domaine :
  #   - `ovh.ssh_key_name` / `scaleway.ssh_key_ids`  — clé provider
  #     injectée au rescue
  #   - `ssh_keys`                                   — clé(s) SSH du
  #     domaine, TOUJOURS injectées dans chaque user (obligatoire)
  #
  # Le dossier contient les hosts directs et les groupes.
  class Domain
    getter name : String                         # "aloli.net"
    getter raw : Hash(YAML::Any, YAML::Any)      # <domaine>.yml
    getter direct_hosts : Hash(String, HostNode) # hosts au niveau racine
    getter groups : Hash(String, Group)          # "web" => Group
    getter source_path : String                  # chemin de <domaine>.yml

    def initialize(@name, @raw, @direct_hosts, @groups, @source_path)
    end

    # Retourne tous les hosts du domaine (directs + sous groupes),
    # sans distinction. Pratique pour lister/chercher.
    def all_hosts : Hash(String, HostNode)
      result = @direct_hosts.dup
      @groups.each_value do |group|
        group.hosts.each do |name, node|
          result[name] = node
        end
      end
      result
    end

    # Clés SSH obligatoires du domaine (au sens « injectées dans
    # chaque user »). Lues depuis le champ racine `ssh_keys:` du
    # fichier domaine. Tableau vide si absent (mais le bootstrap
    # refusera alors car un user sans clé est une erreur).
    def ssh_keys : Array(String)
      value = @raw[YAML::Any.new("ssh_keys")]?
      return [] of String unless value
      (value.as_a? || [] of YAML::Any).compact_map(&.as_s?)
    end
  end
end
