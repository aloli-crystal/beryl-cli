module Beryl::Config
  # Société payeuse : unité de regroupement racine de beryl (ADR-014).
  #
  # Une société :
  #
  #   - détient *un* compte par fournisseur (OVH, Scaleway, Gandi…),
  #     dont les credentials vivent dans `.env.yml[<account>][<provider>]` ;
  #   - héberge *N* domaines (zones DNS) sous son dossier
  #     `~/.config/beryl/<account>/` ;
  #   - partage ses credentials entre tous ses domaines (example.net +
  #     example.com → mêmes clés OVH acme).
  #
  # L'identifiant de la société est son nom court (ex: `acme`), qui
  # correspond au nom du dossier dans `~/.config/beryl/`. Pas d'identifiant
  # numérique, pas de slug : ce qu'on tape dans la commande est ce
  # qu'on voit dans le filesystem.
  #
  # Les métadonnées optionnelles (contact, notes, facturation…) vivent
  # dans `~/.config/beryl/<account>/_account.yml`, stockées dans `metadata`.
  class Account
    getter name : String                         # "acme"
    getter path : String                         # "/Users/philippe/.config/beryl/acme"
    getter metadata : Hash(YAML::Any, YAML::Any) # contenu de _account.yml (peut être vide)
    getter domains : Hash(String, Domain)        # "example.net" => Domain

    def initialize(@name, @path, @metadata, @domains)
    end

    # Nom d'affichage : champ `name:` du `_account.yml` si défini,
    # sinon le nom court en majuscules. Utilisé dans les logs.
    def display_name : String
      if raw = @metadata[YAML::Any.new("name")]?.try(&.as_s?)
        return raw unless raw.empty?
      end
      @name
    end

    # Liste des noms de domaines triés.
    def domain_names : Array(String)
      @domains.keys.sort
    end

    # Récupère un domaine par son nom, nil si absent.
    def domain?(name : String) : Domain?
      @domains[name]?
    end
  end
end
