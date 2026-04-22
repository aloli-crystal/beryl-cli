require "../inventory"

# Résolution d'un hôte cible à partir du nom passé en CLI.
#
# Règle Aloli 22 avril 2026 (Philippe) : « si pas dans l'inventaire,
# fait le taff quand même ». beryl accepte les formes suivantes :
#
# 1. Nom logique déjà dans l'inventaire (ex: `rails01.aloli.fr`).
#    Contexte complet (provider, groupes, freebsd_config…).
# 2. Identifiant côté hébergeur + flag --provider explicite
#    (ex: `beryl rescue --provider=scaleway 11111111-...`).
#    Host virtuel construit à la volée.
# 3. service_name OVH reconnu par heuristique
#    (`nsXXX.ip-A-B-C.tld`) → Host virtuel `provider: ovh` sans
#    avoir besoin du flag. Évite de taper `--provider=ovh` au
#    quotidien.
# 4. Nom inconnu sans flag → erreur explicite suggérant `--provider`.
#
# Les sous-commandes qui pilotent un hôte distant (rescue, bootstrap,
# scan, wipe, boot-hd) passent toutes par `HostResolver.resolve`.
module Beryl::CLI::HostResolver
  # Résout un hôte à partir de son nom de CLI.
  #
  # * `inventory_path` : chemin courant d'inventaire (chargé
  #   silencieusement, pas d'erreur si absent).
  # * `host_name` : nom logique ou identifiant hébergeur.
  # * `provider_hint` : si fourni (ex: "ovh", "scaleway"), on
  #   construit un Host virtuel avec ce provider quand le nom n'est
  #   pas dans l'inventaire, peu importe la forme du nom.
  def self.resolve(
    inventory_path : String,
    host_name : String,
    provider_hint : String? = nil,
  ) : Beryl::Host
    inv = load_inventory_safe(inventory_path)
    if inv
      if existing = inv.find?(host_name)
        return existing
      end
    end

    # Flag explicite : on respecte le provider demandé, quel que soit
    # le format du nom. Chaque provider a ses conventions de champ
    # (ovh.service_name, scaleway.server_id) — on remplit celui qui
    # correspond pour que les sous-commandes downstream le trouvent.
    if provider_hint
      return build_virtual_host(host_name, provider_hint)
    end

    # Heuristique : un nom en `nsXXX.ip-A-B-C.tld` est un service_name
    # OVH, c'est reconnu sans flag.
    if looks_like_ovh_service_name?(host_name)
      return build_virtual_host(host_name, "ovh")
    end

    raise Beryl::Inventory::NotFound.new(
      "hôte inconnu : #{host_name}. " \
      "Passez --provider=ovh|scaleway pour un nouveau serveur, ou " \
      "vérifiez que l'entrée existe dans l'inventaire."
    )
  end

  # Construit un Host virtuel pour un provider donné. Remplit le
  # bloc provider_config avec la clé attendue par chaque hébergeur
  # (service_name côté OVH, server_id côté Scaleway).
  def self.build_virtual_host(host_name : String, provider : String) : Beryl::Host
    config = {} of String => YAML::Any
    case provider
    when "ovh"
      config["service_name"] = YAML::Any.new(host_name)
    when "scaleway"
      config["server_id"] = YAML::Any.new(host_name)
    else
      # Pour un provider inconnu à ce niveau (plugin tiers par
      # exemple), on met le nom dans un champ générique que le
      # provider pourra interpréter à sa façon.
      config["id"] = YAML::Any.new(host_name)
    end
    Beryl::Host.new(
      name: host_name,
      provider: provider,
      provider_config: config,
    )
  end

  # Heuristique pour reconnaître un service_name OVH « nu ». Format
  # `nsXXXXXXX.ip-A-B-C.tld` (tld = eu/com/net typiquement).
  def self.looks_like_ovh_service_name?(name : String) : Bool
    !!(name =~ /^ns\d+\.ip-\d+-\d+-\d+\.[a-z]{2,}$/i)
  end

  # Charge l'inventaire en silencieux : retourne nil si le fichier
  # n'existe pas ou si le parsing échoue (ce qui permet de continuer
  # avec un Host virtuel).
  private def self.load_inventory_safe(path : String) : Beryl::Inventory?
    Beryl::Inventory.load(path)
  rescue File::NotFoundError
    nil
  end
end
