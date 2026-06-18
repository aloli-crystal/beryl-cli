module Beryl
  # Interface abstraite pour un hébergeur (provider). Chaque provider
  # encapsule :
  #
  # - la détection de ses credentials (variables d'env, fichiers…)
  # - le listing des clés SSH enregistrées côté panel
  # - les opérations de nommage (DNS, reverse, rename serveur) pour
  #   le flux `beryl scan --dns`
  # - (futur) création, rescue, boot disk…
  #
  # Règle Aloli : un utilisateur futur qui veut intégrer un nouvel
  # hébergeur (Hetzner, Digital Ocean, AWS…) n'a pas à modifier beryl.
  # Il crée son propre shard qui sous-classe `Beryl::Provider`, puis
  # s'enregistre via `Beryl::Providers.register(instance)`. Les
  # sous-commandes qui consomment des providers (à commencer par
  # `beryl init`) parcourent le registre automatiquement.
  #
  # Les providers fournis par beryl (`Ovh`, `Scaleway`) sont enregistrés
  # dans `src/beryl/providers/registrations.cr`. Un tiers fait la
  # même chose dans son shard : require "beryl/providers" ;
  # Beryl::Providers.register(MonProvider.new).
  abstract class Provider
    # Identifiant court et stable du provider (ex: "ovh", "scaleway").
    # Utilisé comme clé dans le registre, comme valeur de
    # `provider:` dans le YAML d'un host, et comme nom dans les logs.
    abstract def name : String

    # Nom humain pour affichage (ex: "OVHcloud", "Scaleway Elastic Metal").
    abstract def display_name : String

    # Capabilities que ce provider expose (ADR-014). Valeurs connues :
    #
    #   :dns            — gestion d'une zone DNS (records, reverse, refresh)
    #   :compute        — hébergement de serveurs (rescue, boot_from_disk…)
    #   :object_storage — stockage objet compatible S3 (futur)
    #   :cdn            — CDN (futur)
    #   :cert           — certificats SSL (futur)
    #
    # Un provider peut en avoir plusieurs (OVH = [:dns, :compute]).
    # Beryl vérifie la capability avant d'appeler une méthode
    # correspondante — si un `dns_provider: hetzner` est déclaré
    # alors qu'Hetzner n'a pas `:dns`, une erreur explicite est
    # levée à la résolution.
    #
    # Par défaut vide : chaque sous-classe doit la définir.
    def capabilities : Array(Symbol)
      [] of Symbol
    end

    # Raccourci : `provider.capable_of?(:dns)`.
    def capable_of?(capability : Symbol) : Bool
      capabilities.includes?(capability)
    end

    # Vrai si le provider est implémenté dans le build courant de
    # beryl. Utile pour `beryl init` : si l'utilisateur demande un
    # DNS provider qu'on ne sait pas pilote, beryl l'avertit clairement
    # plutôt que d'échouer silencieusement plus tard.
    #
    # Par défaut : `true` — une classe `Provider` qui existe dans ce
    # build est implémentée. Un provider « stub » (placeholder pour
    # un futur shard) peut retourner `false`.
    def implemented? : Bool
      true
    end

    # Vrai si les credentials nécessaires sont disponibles (variables
    # d'env, fichiers de config, agent local…). Ne lève jamais : un
    # provider « indisponible » est simplement sauté par `beryl init`.
    abstract def available? : Bool

    # Liste les clés SSH enregistrées côté panel de l'hébergeur, avec
    # leur contenu public. `beryl init` utilise le contenu pour matcher
    # avec les `~/.ssh/*.pub` locaux — si une clé distante correspond
    # à un fichier local (type + base64 identiques, le commentaire peut
    # différer), on auto-détecte le mapping sans prompt.
    #
    # Lève si les credentials sont présents mais l'API refuse.
    abstract def list_ssh_keys : Array(SshKeyInfo)

    # Rend le champ YAML à écrire dans le groupe zone pour que
    # `beryl rescue`/`bootstrap` sache quelle clé utiliser. Typiquement :
    #   OVH      → { "ssh_key_name" => "<label>" }
    #   Scaleway → { "ssh_key_ids"  => ["<uuid>"] }
    # Le shape dépend du provider ; le bloc est injecté tel quel sous
    # `<provider>:` dans le YAML. Utilisé par `beryl init` pour
    # générer un `groups/<zone>.yml` exploitable.
    abstract def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))

    # Variables d'environnement nécessaires pour que `available?` soit
    # vrai et que les appels API marchent. Listées dans l'ordre où
    # `beryl init` les demandera si le provider n'est pas configuré.
    # Utilisé pour la configuration interactive + aide.
    abstract def credentials_env_vars : Array(EnvVarSpec)

    # URL d'aide côté panel hébergeur où l'utilisateur génère les
    # credentials (token d'API, secret key, etc.). Affichée avant le
    # prompt interactif pour que l'opérateur ouvre sa page dans un
    # autre onglet.
    abstract def credentials_help_url : String

    # Détails d'aide supplémentaires à afficher pendant `beryl init`.
    # Typiquement la liste exhaustive des permissions/routes que beryl
    # va appeler, pour que l'opérateur puisse les cocher dans le
    # formulaire du panel. Retourne nil si pas de détails particuliers.
    def credentials_help_details : String?
      nil
    end

    # Hook appelé par `beryl init` après que les variables de base
    # (app key, secret, etc.) sont présentes dans `env`. Permet au
    # provider de compléter les credentials via un flux spécifique
    # (ex: OVH — générer une consumer key via `POST /auth/credential`
    # avec la liste des access rules exactes).
    #
    # Le hook doit :
    #   - retourner `env` éventuellement enrichi de nouvelles paires
    #     clé/valeur (ex: OVH_CONSUMER_KEY)
    #   - être IDEMPOTENT : si la credential dérivée est déjà là et
    #     valide, et que `force_regen` est false, ne rien faire.
    #   - respecter `interactive` : en non-interactif, ne pas prompter
    #     et lever explicitement si une saisie était indispensable.
    #
    # Par défaut : no-op (Scaleway n'a pas d'auto-gen, il se contente
    # de `credentials_help_details` pour indiquer quoi cocher à la main).
    def bootstrap_credentials_if_needed(
      env : Hash(String, String),
      force_regen : Bool = false,
      interactive : Bool = true,
    ) : Hash(String, String)
      env
    end

    # Vrai si ce provider héberge le serveur identifié par `host_name`.
    # Conservé pour compat (ex: diagnostics). La résolution d'hôte
    # n'en a plus besoin : elle passe par suffix-match et recherche
    # dans les fichiers (voir `Beryl::Config::Root#resolve`). Cette
    # méthode peut être utilisée par les sous-commandes qui veulent
    # confirmer qu'un serveur existe bien chez le provider.
    def owns?(host_name : String) : Bool
      false
    end
  end

  # Spécification d'une variable d'environnement attendue par un
  # provider. Utilisé par la configuration interactive de `beryl init`
  # pour prompter, sauvegarder dans ~/.config/beryl/.env, et afficher de
  # l'aide.
  struct EnvVarSpec
    getter name : String        # "OVH_APPLICATION_KEY"
    getter description : String # "Clé applicative (panel OVH → Mes APIs)"
    getter optional : Bool
    getter default : String?
    getter secret : Bool # masque l'écho à l'écran (tokens)

    def initialize(
      @name : String,
      @description : String,
      @optional : Bool = false,
      @default : String? = nil,
      @secret : Bool = false,
    )
    end
  end

  # Métadonnées d'une clé SSH chez un provider.
  #
  # `id` : identifiant stable chez le provider (label OVH, UUID
  # Scaleway…), réutilisé dans `Provider#ssh_key_yaml_fragment`.
  # `name` : nom lisible pour l'humain (souvent égal à `id` chez OVH,
  # distinct chez Scaleway où `id` est un UUID).
  # `public_key` : contenu complet `ssh-ed25519 AAAA... commentaire`,
  # tel que renvoyé par l'API du provider. Permet à `beryl init` de
  # matcher avec les `.pub` locaux.
  struct SshKeyInfo
    getter id : String
    getter name : String
    getter public_key : String

    def initialize(@id, @name, @public_key)
    end

    # Extrait le couple « type algo + base64 » d'une clé publique.
    # Ignore le commentaire final (qui peut différer entre la version
    # OVH et le fichier local sans que ce soit la « même » clé au
    # sens cryptographique).
    #
    # Exemple : `"ssh-ed25519 AAAA... philippe@aloli.fr"` → `"ssh-ed25519 AAAA..."`.
    def crypto_fingerprint : String
      tokens = public_key.strip.split(/\s+/, limit: 3)
      tokens.size >= 2 ? "#{tokens[0]} #{tokens[1]}" : public_key.strip
    end
  end

  # Inventaire disques DÉCLARÉ par l'API matériel d'un provider (ex. OVH
  # `specifications/hardware`). Sert à croiser avec les disques réellement
  # vus par l'OS (`lsblk`) pour repérer un disque défaillant non énuméré.
  # `flash` = SSD + NVMe, `spinning` = HDD ; `total` = somme de TOUS les
  # disques déclarés (peut dépasser flash+spinning si un type est inconnu).
  record DiskInventory, flash : Int32, spinning : Int32, total : Int32

  # Caractéristiques matérielles DÉCLARÉES par l'API du provider (ex. OVH
  # `specifications/hardware`). Sert à `beryl info` (inventaire hors-ligne,
  # écrit dans le host.yml par `beryl scan`). `disks` = lignes lisibles
  # (ex. "2 x 960 GB SSD"). `raid` = contrôleur RAID matériel, nil si aucun.
  record HardwareSpec,
    cpu : String,
    cores : Int32,
    threads : Int32,
    ram_gb : Int32,
    disks : Array(String),
    raid : String? = nil

  # Registre des providers enregistrés. Simple wrapper autour d'un
  # hash ; le module est utilisable de n'importe où via l'API `.register`
  # / `.all` / `.find`. Les providers beryl natifs sont enregistrés au
  # chargement de `providers/registrations.cr` ; les tiers font pareil
  # depuis leur propre shard.
  module Providers
    @@registered = {} of String => Beryl::Provider

    # Enregistre un provider. Le nom est l'identifiant (provider.name).
    # Re-register écrase silencieusement (utile pour les tests qui
    # remplacent un provider par un stub).
    def self.register(provider : Beryl::Provider) : Nil
      @@registered[provider.name] = provider
    end

    # Liste tous les providers connus (tous, pas seulement ceux dont
    # les credentials sont disponibles). Triés par `name` pour avoir
    # un affichage stable.
    def self.all : Array(Beryl::Provider)
      @@registered.values.sort_by(&.name)
    end

    # Sous-ensemble : ceux dont `available?` est vrai. Utilisé par
    # `beryl init` pour ne proposer que les hébergeurs actuellement
    # configurés dans l'environnement.
    def self.available : Array(Beryl::Provider)
      all.select(&.available?)
    end

    # Récupère un provider par nom ou nil si inconnu.
    def self.find(name : String) : Beryl::Provider?
      @@registered[name]?
    end

    # Efface le registre (utilisé par les tests qui veulent partir
    # d'un état propre).
    def self.clear : Nil
      @@registered.clear
    end
  end
end

require "./providers/capabilities"
require "./providers/ovh"
require "./providers/scaleway"
require "./providers/dedibox"
require "./providers/gandi"
require "./providers/registrations"
