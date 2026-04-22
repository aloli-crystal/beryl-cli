module Beryl::Config
  # Un groupe d'usage dans un domaine. Existe quand il y a un fichier
  # `<domaine>/<groupe>.yml` ET/OU un dossier `<domaine>/<groupe>/`.
  #
  # Le fichier porte les propriétés du groupe (`packages`, `sudoers`
  # spécifiques), le dossier contient les hosts du groupe. L'un ou
  # l'autre peut être vide/absent : un groupe peut exister sans
  # propriétés (juste un dossier), et un `.yml` de groupe sans dossier
  # est possible (groupe défini mais pas encore instancié).
  class Group
    getter name : String                    # "web"
    getter raw : Hash(YAML::Any, YAML::Any) # <groupe>.yml (vide si absent)
    getter hosts : Hash(String, HostNode)   # "rails01" => HostNode
    getter source_path : String?            # <groupe>.yml path (nil si absent)

    def initialize(@name, @raw, @hosts, @source_path)
    end
  end
end
