# installerconfig bsdinstall — généré par beryl pour __HOSTNAME__
#
# VOLONTAIREMENT MINIMALISTE : préambule seul, pas de post-install chroot.
#
# Tout le post-install (users, packages, sshd, sudoers…) est piloté par
# `rescue-run-vm.sh` depuis mfsBSD EN DEHORS du chroot bsdinstall, via
# des commandes qui ciblent explicitement /mnt/. Cette stratégie contourne
# le bug Capsicum observé sur loulou le 21 avril 2026 (pkg depuis dans
# le chroot bsdinstall tue son enfant de vérification signature avec
# signal 12 = SIGSYS). Voir ADR-013.
#
# ATTENTION : pas de shebang `#!/bin/sh` en tête de fichier. bsdinstall
# utilise la PREMIÈRE ligne commençant par `#!` comme séparateur entre
# préambule et post-install chroot. Un shebang en tête fait ignorer tout
# le préambule (ZFSBOOT_* etc.) → boucle silencieuse sur « Pool name
# cannot be empty ».

# ZFS auto-partitioning. Du point de vue de la VM QEMU, le disque réel
# passthrough apparaît comme vtbd1 (virtio-blk #1, mfsBSD étant #0).
# Les labels GPT (gpt/efiboot0, gpt/swap0, gpt/zfs0) sont déterministes
# et portables entre VM et bare metal.
export ZFSBOOT_DISKS="__ZFSBOOT_DISKS__"
export ZFSBOOT_VDEV_TYPE="__ZFSBOOT_VDEV_TYPE__"
export ZFSBOOT_SWAP_SIZE="__SWAP_GB__g"
export ZFSBOOT_POOL_NAME="__POOL_NAME__"
export nonInteractive="YES"

# Distributions tarballs classiques. Le pkgbase (FreeBSD 15 « Tech
# Preview ») sera un choix opt-in dans une itération future.
DISTRIBUTIONS="kernel.txz base.txz"
