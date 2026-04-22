require "../inventory"
require "../providers"

# Résolution d'un hôte cible à partir du nom passé en CLI.
#
# Règle Aloli 22 avril 2026 (Philippe) : « si pas dans l'inventaire,
# fait le taff quand même » + « il suffit de voir chez qui il est
# hébergé ». beryl accepte les formes suivantes :
#
# 1. Nom logique déjà dans l'inventaire (ex: `rails01.aloli.fr`).
#    Contexte complet (provider, groupes, freebsd_config…).
# 2. Identifiant côté hébergeur — auto-détection : beryl demande à
#    chaque provider configuré « c'est chez toi ? » (via
#    `Provider#owns?`). Le premier qui répond oui donne le Host
#    virtuel avec le bon provider. Permet
#    `beryl rescue ns3156789.ip-51-83-6.eu` directement, sans flag.
# 3. Flag `--provider` explicite pour court-circuiter l'auto-détection
#    (utile quand les credentials d'un provider manquent ou pour
#    accélérer le démarrage).
# 4. Heuristique `nsXXX.ip-A-B-C.tld` → fallback Host virtuel OVH
#    quand les credentials OVH ne sont pas configurés (on évite un
#    appel API qui raterait, mais on reste utile au cas où).
# 5. Nom inconnu sans hint ni détection → erreur explicite.
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

    # Auto-détection : « chez qui ce serveur est hébergé ? ». Pour
    # chaque provider avec credentials, on interroge son API. Premier
    # qui dit oui gagne. Le coût est ~1 appel API par provider
    # configuré (souvent un seul), négligeable comparé au reste du
    # flux (rescue boot, scan disques, etc.).
    Beryl::Providers.available.each do |provider|
      next unless provider.owns?(host_name)
      STDERR.puts "[beryl] Serveur détecté chez #{provider.display_name}"
      return build_virtual_host(host_name, provider.name)
    end

    # Fallback heuristique : si aucun provider n'a pu répondre (ex:
    # credentials OVH manquants mais Philippe a quand même un
    # service_name OVH sous la main), on reconnaît le format `nsXXX.
    # ip-A-B-C.tld` et on construit un Host virtuel OVH. L'appel API
    # en aval lèvera proprement si les credentials manquent.
    if looks_like_ovh_service_name?(host_name)
      return build_virtual_host(host_name, "ovh")
    end

    raise Beryl::Inventory::NotFound.new(
      "hôte inconnu : #{host_name}. " \
      "Aucun provider configuré n'héberge ce serveur. Vérifiez vos " \
      "credentials (OVH/Scaleway) ou passez --provider=NAME explicitement."
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
