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

require "./providers/ovh"
require "./providers/scaleway"
require "./providers/registrations"
