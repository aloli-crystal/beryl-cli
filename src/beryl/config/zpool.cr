module Beryl::Config
  # Traduction entre les niveaux RAID numériques (convention
  # utilisateur, parlante) et les modes ZFS (convention bsdinstall
  # `ZFSBOOT_VDEV_TYPE`). Philippe 22 avril 2026 : « Je préfère une
  # valeur de raid plutôt que la valeur FreeBSD qui n'est pas parlante ».
  #
  # Mapping :
  #
  #   raid  zfs       min  tolérance         capacité      usage
  #   ────  ─────     ───  ────────────      ──────────    ─────────────────
  #   0     stripe    1    0                 Σ(disques)    perf max, backup
  #   1     mirror    2    N-1               1 disque      2 disques, critique
  #   5     raidz     3    1                 Σ-1           3-5 disques
  #   6     raidz2    4    2                 Σ-2           6-8 disques
  #   7     raidz3    5    3                 Σ-3           8+ disques
  #   10    mirror×N  4    1 par paire       Σ/2           non supporté encore
  #
  # Le cas 10 n'est pas câblé côté bootstrap (bsdinstall
  # `ZFSBOOT_VDEV_TYPE` ne gère qu'un seul vdev type). À implémenter
  # via un flux ZFS manuel (zpool create mirror…mirror…) quand le
  # besoin se présente.
  module Zpool
    extend self

    # Table de référence : valeur RAID (Int32) → mode ZFS (String).
    RAID_TO_ZFS = {
       0 => "stripe",
       1 => "mirror",
       5 => "raidz",
       6 => "raidz2",
       7 => "raidz3",
      10 => "mirror_stripe", # traité à part côté bootstrap
    }

    # Nombre minimum de disques par mode. Validation au moment du
    # bootstrap (Beryl::Config::Zpool.validate!).
    MIN_DISKS = {
       0 => 1,
       1 => 2,
       5 => 3,
       6 => 4,
       7 => 5,
      10 => 4,
    }

    # Vrai si `raid` est un niveau supporté.
    def known?(raid : Int) : Bool
      RAID_TO_ZFS.has_key?(raid)
    end

    # Retourne le mode ZFS correspondant, ou lève si le niveau est
    # inconnu.
    def zfs_mode(raid : Int) : String
      RAID_TO_ZFS[raid]? || raise UnknownRaidLevel.new(
        "niveau RAID #{raid} non supporté. Valeurs acceptées : " \
        "#{RAID_TO_ZFS.keys.sort.join(", ")}"
      )
    end

    # Valide la compatibilité entre le niveau RAID et le nombre de
    # disques déclarés. Lève avec message explicite sinon.
    def validate!(raid : Int, disks_count : Int) : Nil
      min = MIN_DISKS[raid]? || raise UnknownRaidLevel.new(
        "niveau RAID #{raid} non supporté"
      )
      if disks_count < min
        raise InvalidDiskCount.new(
          "RAID #{raid} nécessite au minimum #{min} disque(s), vous en avez " \
          "déclaré #{disks_count}."
        )
      end
      # Contraintes spécifiques.
      if raid == 10 && disks_count.odd?
        raise InvalidDiskCount.new(
          "RAID 10 (stripe de mirrors) nécessite un nombre PAIR de disques, " \
          "vous en avez #{disks_count}."
        )
      end
    end

    class UnknownRaidLevel < Exception
    end

    class InvalidDiskCount < Exception
    end
  end

  # Configuration de chiffrement d'un pool/dataset ZFS.
  #
  # Deux modes supportés :
  #
  # * *ssh_unlock* (Option C) — la clé vit sur le poste opérateur
  #   (`~/.config/beryl/<société>/<domaine>/<host>.key`, chmod 0400). Au
  #   reboot, l'opérateur lance `beryl unlock <host>` ; la clé voyage
  #   via stdin SSH, jamais loggable. Pas de prérequis Tang. Code
  #   livré le 25 avril 2026.
  #
  # * *tang* (Option D) — la clé est dérivée à chaque boot via le
  #   protocole Tang (échange McCallum-Relyea). Le serveur doit
  #   pouvoir joindre au moins `threshold` Tangs au moment du boot.
  #   Le shard `crystal-clevis-zfs` v0.2 (livré 27 avril 2026)
  #   implémente le client Tang + le binding ZFS native. Multi-Tang
  #   threshold N-of-M supporté via SSS.
  #
  # Voir `zpool-encryption-architecture.adoc` § « Le modèle SSH unlock »
  # et `boot-and-mount-plan.adoc` § « Mode tang » pour les flows
  # complets.
  struct EncryptionConfig
    enum Mode
      SshUnlock # Option C — clé sur poste opérateur
      Tang      # Option D — auto-unlock via Tang au boot
    end

    getter mode : Mode
    # URLs des serveurs Tang. Vide en mode ssh_unlock. En mode tang :
    # 1 URL = single-Tang (SPOF), N URLs + threshold = multi-Tang SSS.
    getter tang_urls : Array(String)
    # Threshold K dans Shamir Secret Sharing : combien de Tangs sur
    # `tang_urls.size` doivent répondre pour reconstituer la clé.
    # 1 par défaut (single-Tang). Doit être ≤ tang_urls.size.
    getter threshold : Int32
    # Compression ZFS du dataset chiffré. Appliquée AVANT le
    # chiffrement par ZFS native, donc gain réel sur les données
    # compressibles (logs, BDD, JSON, code). « lz4 » par défaut
    # (compromis perf/ratio), « zstd-3 » pour ratio max, « off »
    # pour les binaires/médias déjà compressés.
    getter compression : String

    def initialize(
      @mode : Mode,
      @tang_urls : Array(String) = [] of String,
      @threshold : Int32 = 1,
      @compression : String = "lz4",
    )
    end

    # Construit une `EncryptionConfig` à partir de la valeur YAML
    # `encryption:` d'un pool/dataset. Retourne nil si pas de
    # chiffrement déclaré (`encryption: false` ou absence).
    #
    # Quatre formes acceptées :
    #
    #   encryption: false                    → nil (pas chiffré)
    #   encryption: true                     → mode ssh_unlock (Option C, défaut)
    #   encryption:
    #     mode: ssh_unlock                   → idem, forme étendue
    #     compression: lz4
    #
    #   encryption:
    #     mode: tang
    #     tang:
    #       urls: [http://tang.local:8888]
    #       threshold: 1
    #     compression: zstd-3
    #
    # `pool_name` n'est utilisé que pour les messages d'erreur.
    # Cette factory NE LÈVE PAS sur les incohérences d'usage
    # (URL manquante, threshold > N…) — c'est la responsabilité
    # de `validate!` appelé par `Pool#validate!`. Elle ne lève QUE
    # sur les modes inconnus, où la lecture YAML elle-même n'a pas
    # de sens.
    def self.from_yaml(any : YAML::Any?, pool_name : String) : EncryptionConfig?
      return nil unless any

      # Forme legacy : booléen.
      if (b = any.as_bool?)
        return b ? new(mode: Mode::SshUnlock) : nil
      end

      # Forme étendue : hash.
      h = any.as_h?
      return nil unless h

      mode_str = h[YAML::Any.new("mode")]?.try(&.as_s?) || "ssh_unlock"
      mode = case mode_str
             when "ssh_unlock" then Mode::SshUnlock
             when "tang"       then Mode::Tang
             else
               raise InvalidEncryptionConfig.new(
                 "pool #{pool_name} : encryption.mode=#{mode_str.inspect} inconnu (attendu : ssh_unlock, tang)"
               )
             end

      tang_urls = [] of String
      threshold = 1
      if (tang_h = h[YAML::Any.new("tang")]?.try(&.as_h?))
        if (urls_a = tang_h[YAML::Any.new("urls")]?.try(&.as_a?))
          tang_urls = urls_a.compact_map(&.as_s?)
        end
        threshold = tang_h[YAML::Any.new("threshold")]?.try(&.as_i?) || 1
      end

      compression = h[YAML::Any.new("compression")]?.try(&.as_s?) || "lz4"

      new(
        mode: mode,
        tang_urls: tang_urls,
        threshold: threshold,
        compression: compression,
      )
    end

    def ssh_unlock? : Bool
      @mode == Mode::SshUnlock
    end

    def tang? : Bool
      @mode == Mode::Tang
    end

    # Validation cohérence interne. Levée à la résolution YAML pour
    # rejeter une config absurde (mode tang sans URL, threshold > N…).
    def validate! : Nil
      case @mode
      when Mode::SshUnlock
        unless @tang_urls.empty?
          raise InvalidEncryptionConfig.new(
            "encryption.mode=ssh_unlock incompatible avec tang_urls=#{@tang_urls}"
          )
        end
      when Mode::Tang
        if @tang_urls.empty?
          raise InvalidEncryptionConfig.new(
            "encryption.mode=tang exige au moins une URL Tang (encryption.tang.urls)"
          )
        end
        if @threshold < 1 || @threshold > @tang_urls.size
          raise InvalidEncryptionConfig.new(
            "encryption.tang.threshold=#{@threshold} hors plage [1, #{@tang_urls.size}]"
          )
        end
      end
      unless {"lz4", "zstd-3", "off"}.includes?(@compression)
        raise InvalidEncryptionConfig.new(
          "encryption.compression=#{@compression} invalide (attendu : lz4, zstd-3, off)"
        )
      end
    end
  end

  class InvalidEncryptionConfig < Exception
  end

  # Représente un pool ZFS tel que déclaré dans `freebsd.zfs.<nom>`.
  # Le nom du pool = la clé YAML (pas de champ `name:` redondant).
  # Un seul pool porte `boot: true` : c'est celui qu'installera
  # bsdinstall. Les autres sont créés après l'install via
  # `zpool create <nom> <raid> <disks>`.
  #
  # `encryption` : si non-nil, le pool/dataset est chiffré avec ZFS
  # native encryption. Voir `EncryptionConfig` pour le détail.
  # Réservé aux pools data : un pool boot chiffré demanderait IPMI/KVM.
  # Un dataset système dérivé d'un `profile:` sur le pool boot (architecture
  # « C+ », cf. zpool-encryption-architecture.adoc § Amendement 20 juin). Créé
  # par beryl APRÈS bsdinstall. Les datasets chiffrés partagent l'`encryptionroot`
  # du pool (`Pool#encryption_root`) → une seule clé, un seul `beryl unlock`.
  record SystemDataset,
    name : String,       # nom ZFS complet, ex. "zroot/encrypted/home", "zroot/zlog"
    mountpoint : String, # ex. "/home", "/var/log"
    encrypted : Bool,    # hérite de l'encryptionroot si true
    compression : String # "lz4" | "zstd-3"

  # Représente un pool ZFS tel que déclaré dans `freebsd.zfs.<nom>`.
  # Le nom du pool = la clé YAML (pas de champ `name:` redondant).
  # Un seul pool porte `boot: true` : c'est celui qu'installera
  # bsdinstall. Les autres sont créés après l'install via
  # `zpool create <nom> <raid> <disks>`.
  #
  # `encryption` : si non-nil, le pool/dataset est chiffré avec ZFS
  # native encryption. Voir `EncryptionConfig` pour le détail.
  # Réservé aux pools data, OU — sur le pool boot avec `profile:` — au mode
  # de chiffrement des datasets sensibles du profil (le `/` reste clair).
  struct Pool
    getter name : String                  # clé YAML = nom ZFS
    getter boot : Bool                    # true = pool système
    getter raid : Int32                   # 0|1|5|6|7|10
    getter disks : Array(String)          # /dev/sdX
    getter mountpoint : String?           # /data, /backup…
    getter encryption : EncryptionConfig? # nil = clair
    getter profile : String?              # "standard" sur le pool boot (C+) ; nil sinon

    def initialize(@name, @boot, @raid, @disks, @mountpoint = nil, @encryption = nil, @profile = nil)
    end

    # Sucre syntaxique pour les call sites qui veulent juste un Bool
    # (sélection des pools chiffrés, etc.).
    def encrypted? : Bool
      !@encryption.nil?
    end

    def zfs_mode : String
      Zpool.zfs_mode(@raid)
    end

    # Encryptionroot partagé des datasets chiffrés du profil (`<pool>/encrypted`,
    # non monté). `beryl unlock` y charge LA clé → tous les datasets enfants
    # s'ouvrent. nil si pas de profil chiffrant.
    def encryption_root : String?
      return nil unless @profile == "standard"
      "#{@name}/encrypted"
    end

    # Datasets dérivés du `profile:` (créés par beryl après bsdinstall). Le `/`
    # (`<pool>/ROOT/default`) est posé par bsdinstall, pas listé ici. Layout
    # MINIMAL acté (usr/var/tmp restent dans `/`) : 3 chiffrés + `/var/log` clair.
    # Vide si pas de profil.
    def system_datasets : Array(SystemDataset)
      return [] of SystemDataset unless @profile == "standard"
      er = encryption_root.not_nil!
      [
        SystemDataset.new("#{er}/home", "/home", true, "lz4"),
        SystemDataset.new("#{er}/opt", "/opt", true, "lz4"),
        SystemDataset.new("#{er}/usrlocaletc", "/usr/local/etc", true, "zstd-3"),
        SystemDataset.new("#{@name}/zlog", "/var/log", false, "zstd-3"),
      ]
    end

    def validate! : Nil
      Zpool.validate!(@raid, @disks.size)
      # Chiffrer le pool boot LUI-MÊME (le `/`) reste interdit (demande IPMI/KVM).
      # MAIS avec `profile:`, `encryption` désigne le mode des DATASETS sensibles
      # (`/home`…), pas le `/` — autorisé (architecture C+).
      if @boot && encrypted? && @profile.nil?
        raise BootPoolEncryptionUnsupported.new(
          "pool #{@name} : `encryption` sur un pool `boot: true` SANS `profile:` " \
          "chiffrerait le `/` (demande IPMI/KVM, hors scope). Pour chiffrer les " \
          "datasets sensibles (/home…) en gardant `/` clair, utilisez `profile: standard`. " \
          "Voir zpool-encryption-architecture.adoc § Amendement 20 juin."
        )
      end
      @encryption.try(&.validate!)
    end
  end

  class BootPoolEncryptionUnsupported < Exception
  end
end
