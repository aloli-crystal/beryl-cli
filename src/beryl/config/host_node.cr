module Beryl::Config
  # Un host tel que déclaré sur le disque, AVANT merge avec ses
  # ancêtres. Contient juste le nom court et le contenu brut du
  # fichier YAML. Produit un `ResolvedHost` via `Merger.merge` quand
  # on l'interroge.
  class HostNode
    getter name : String                    # "rails01" (sans .aloli.net)
    getter raw : Hash(YAML::Any, YAML::Any) # contenu du <host>.yml
    getter source_path : String             # chemin absolu du YAML

    def initialize(@name, @raw, @source_path)
    end
  end
end
