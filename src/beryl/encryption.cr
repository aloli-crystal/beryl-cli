require "random/secure"
require "file_utils"

module Beryl
  # Gestion des clés de chiffrement ZFS (datasets data) côté opérateur.
  #
  # Modèle « SSH unlock manuel » :
  #
  #   - La clé (32 bytes / 256 bits) est générée *côté opérateur* au
  #     moment du bootstrap. Jamais sur le serveur.
  #   - Stockée dans `~/.beryl/<société>/<domaine>/<host>.key`,
  #     chmod 0400 (lecture par owner uniquement). Dossier parent
  #     chmod 0700.
  #   - Format sur disque : 64 caractères hexadécimaux + newline.
  #     Lisible avec `cat`, copiable visuellement, audit possible.
  #   - Format ZFS correspondant : `keyformat=hex -O keylocation=prompt`.
  #     ZFS attend exactement 64 chars hex sur stdin (le `\n` final
  #     n'est PAS consommé).
  #   - Sauvegardée naturellement par Time Machine + (v1) iCloud
  #     Keychain via `project_beryl_secrets_vault.md`.
  #
  # Voir `zpool-encryption-architecture.adoc` pour l'architecture
  # complète (pourquoi `keyformat=hex`, pourquoi pas `raw`, pourquoi
  # SSH unlock plutôt que keyfile sur le serveur, etc.).
  module Encryption
    # Taille en bytes de la clé symétrique. ZFS native encryption
    # accepte AES-256-{GCM,CCM} dont la clé fait 256 bits.
    KEY_SIZE_BYTES = 32

    # Permissions du fichier de clé. 0400 = lecture seule par owner,
    # rien pour group ni other. Toute clé qui n'aurait pas ce mode
    # exact est rejetée par `read` (sécurité par défaut).
    KEY_FILE_MODE = 0o400

    # Permissions du dossier parent (`~/.beryl/<société>/<domaine>/`).
    # 0700 : seul owner peut entrer. Si le dossier existe déjà avec
    # un autre mode, on ne le modifie pas (pas notre rôle d'écraser
    # les permissions d'un dossier existant), mais on log un warning.
    DIR_MODE = 0o700

    # Erreur générique pour les opérations de chiffrement.
    class Error < Exception
    end

    # Levée si on tente d'écrire une clé qui existe déjà — protection
    # anti-écrasement. Une clé écrasée = données du pool définitivement
    # perdues (le pool ne se déchiffrera plus). L'opérateur doit
    # explicitement supprimer ou renommer l'ancienne clé.
    class KeyAlreadyExists < Error
    end

    # Levée si la clé sur disque est mal formée (taille, encodage, mode
    # de fichier) — refus explicite plutôt que produire un comportement
    # subtil non détectable.
    class InvalidKey < Error
    end

    # Génère une clé ZFS aléatoire en 64 chars hex. Source d'entropie :
    # `Random::Secure` (puise dans `/dev/urandom` sur les Unix). Pas
    # de seed reproductible — chaque appel donne une clé différente.
    def self.generate_hex : String
      Random::Secure.random_bytes(KEY_SIZE_BYTES).hexstring
    end

    # Chemin canonique du fichier de clé pour un host donné.
    #
    #   ~/.beryl/<société>/<domaine>/<host>.key
    #
    # Le `<host>` est le short_name (ex: `quantas`), pas le FQDN.
    # Cohérent avec le reste de l'arborescence beryl où les YAML host
    # vivent à `~/.beryl/<société>/<domaine>/<host>.yml`.
    def self.key_path(config_root : String, account : String, domain : String, host_short : String) : String
      File.join(config_root, account, domain, "#{host_short}.key")
    end

    # Vrai si une clé existe déjà à cet emplacement (permet d'éviter
    # un `Errno::ENOENT` au moment d'`Open` quand on veut juste savoir).
    def self.exists?(path : String) : Bool
      File.exists?(path)
    end

    # Génère et écrit une nouvelle clé. Refuse si le fichier existe
    # déjà — une clé écrasée = pool définitivement illisible. Si
    # vraiment besoin de regénérer, l'opérateur supprime le `.key`
    # à la main puis relance (mais alors les datasets chiffrés
    # actuellement avec l'ancienne clé deviennent inaccessibles).
    #
    # Crée le dossier parent en 0700 si absent. Pose le fichier en
    # 0400. Retourne la clé hex générée.
    def self.write_new(path : String) : String
      if File.exists?(path)
        raise KeyAlreadyExists.new(
          "une clé existe déjà à #{path}. " \
          "Refus d'écraser : les datasets chiffrés avec l'ancienne clé deviendraient illisibles. " \
          "Si vous voulez vraiment regénérer (host neuf, pas encore en prod), " \
          "supprimez le fichier manuellement et relancez."
        )
      end
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir, mode: DIR_MODE) unless Dir.exists?(dir)
      hex = generate_hex
      File.open(path, "w", perm: KEY_FILE_MODE) do |f|
        f.print(hex)
        f.print('\n')
      end
      # Force le mode même si le fichier existait via un umask
      # surprenant — File.open avec perm peut être altéré.
      File.chmod(path, KEY_FILE_MODE)
      hex
    end

    # Lit une clé depuis le disque. Vérifications :
    #
    #   - Le fichier existe.
    #   - Mode = 0400 strict. Si autre, erreur explicite (la clé est
    #     potentiellement compromise par un autre processus, on ne
    #     la touche plus).
    #   - 64 chars hex après strip du newline final.
    #
    # Retourne la chaîne hex (sans newline). C'est le format attendu
    # par `zfs load-key` quand `keyformat=hex`.
    def self.read(path : String) : String
      raise InvalidKey.new("clé absente : #{path}") unless File.exists?(path)
      stat = File.info(path)
      mode = stat.permissions.value & 0o777
      if mode != KEY_FILE_MODE
        raise InvalidKey.new(
          "clé #{path} : permissions 0#{mode.to_s(8)} (attendu : 0400). " \
          "La clé peut avoir été lue par un autre processus. " \
          "Régénérez si possible, ou corrigez avec `chmod 0400 #{path}` après audit."
        )
      end
      content = File.read(path).strip
      unless content.size == KEY_SIZE_BYTES * 2
        raise InvalidKey.new(
          "clé #{path} : taille #{content.size} (attendu : #{KEY_SIZE_BYTES * 2} chars hex)"
        )
      end
      unless content.each_char.all? { |c| c.ascii_letter? && c.downcase.in?('a'..'f') || c.ascii_number? }
        raise InvalidKey.new("clé #{path} : caractères non hexadécimaux")
      end
      content
    end
  end
end
