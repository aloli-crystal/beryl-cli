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
end
