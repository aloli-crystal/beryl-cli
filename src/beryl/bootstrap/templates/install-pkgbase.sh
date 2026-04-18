#!/bin/sh
# Script d'installation FreeBSD 15 en mode pkgbase, généré par beryl.
#
# Exécuté à l'intérieur d'une image mfsBSD tournant en RAM.
# Les placeholders __XXX__ sont remplacés par beryl avant upload.
#
# ATTENTION : ce script est DESTRUCTIF. Il détruit tout ce qui est sur le disque
# désigné par __TARGET_DISK__.

set -eu

DISK="__TARGET_DISK__"
POOL="__POOL_NAME__"
HOSTNAME="__HOSTNAME__"
ABI="__ABI__"
SWAP_GB="__SWAP_GB__"
TIMEZONE="__TIMEZONE__"
AUTHORIZED_KEYS_B64="__AUTHORIZED_KEYS_B64__"

echo "==> [beryl] Destruction des tables de partition existantes sur ${DISK}"
gpart destroy -F "${DISK}" 2>/dev/null || true
dd if=/dev/zero of="${DISK}" bs=1M count=10 2>/dev/null || true

echo "==> [beryl] Création du schéma GPT"
gpart create -s gpt "${DISK}"

echo "==> [beryl] Partition EFI (200 Mo)"
gpart add -t efi -s 200M -a 1M -l efi "${DISK}"
newfs_msdos -F 32 -c 1 "/dev/gpt/efi"

echo "==> [beryl] Partition swap (${SWAP_GB} Go)"
gpart add -t freebsd-swap -s "${SWAP_GB}G" -a 1M -l swap "${DISK}"

echo "==> [beryl] Partition ZFS (reste du disque)"
gpart add -t freebsd-zfs -a 1M -l zfs "${DISK}"

echo "==> [beryl] Création du pool ZFS ${POOL}"
zpool create -f \
  -O canmount=off -O mountpoint=none \
  -O compression=lz4 -O atime=off \
  -R /mnt \
  "${POOL}" /dev/gpt/zfs

echo "==> [beryl] Datasets ZFS"
zfs create -o mountpoint=none "${POOL}/ROOT"
zfs create -o mountpoint=/ "${POOL}/ROOT/default"
zfs create -o mountpoint=/home "${POOL}/home"
zfs create -o mountpoint=/var/log "${POOL}/varlog"
zfs create -o mountpoint=/tmp -o setuid=off -o exec=off "${POOL}/tmp"
chmod 1777 /mnt/tmp

zpool set bootfs="${POOL}/ROOT/default" "${POOL}"

echo "==> [beryl] Monte EFI"
mkdir -p /mnt/boot/efi
mount -t msdosfs /dev/gpt/efi /mnt/boot/efi

echo "==> [beryl] Bootstrap pkg dans /mnt"
mkdir -p /mnt/usr/local/etc/pkg/repos
cat > /mnt/usr/local/etc/pkg/repos/FreeBSD-base.conf <<'REPO'
FreeBSD-base: {
  url: "pkg+https://pkg.freebsd.org/${ABI}/base_release_0",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
REPO

fetch -o /tmp/FreeBSD-pkg-bootstrap.pkg \
  "https://pkg.freebsd.org/${ABI}/base_release_0/FreeBSD-pkg-bootstrap-15.0.pkg"

pkg -c /mnt add -f /tmp/FreeBSD-pkg-bootstrap.pkg

echo "==> [beryl] Installation des paquets FreeBSD-base (pkgbase)"
env ABI="${ABI}" pkg -c /mnt install -y \
  FreeBSD-runtime \
  FreeBSD-kernel-generic \
  FreeBSD-rc \
  FreeBSD-libexec \
  FreeBSD-libcompat \
  FreeBSD-openssh-server \
  FreeBSD-openssh \
  FreeBSD-dma \
  FreeBSD-bootloader \
  FreeBSD-zfs \
  FreeBSD-fetch \
  FreeBSD-pkg

echo "==> [beryl] Configuration /boot/loader.conf"
cat > /mnt/boot/loader.conf <<'LOADER'
zfs_load="YES"
opensolaris_load="YES"
LOADER

echo "==> [beryl] Configuration /etc/fstab"
cat > /mnt/etc/fstab <<'FSTAB'
/dev/gpt/efi   /boot/efi  msdosfs  rw,late   2  2
/dev/gpt/swap  none       swap     sw        0  0
FSTAB

echo "==> [beryl] Configuration /etc/rc.conf"
cat > /mnt/etc/rc.conf <<RC
hostname="${HOSTNAME}"
ifconfig_DEFAULT="DHCP"
ipv6_activate_all_interfaces="YES"
ifconfig_DEFAULT_ipv6="inet6 accept_rtadv"
sshd_enable="YES"
zfs_enable="YES"
syslogd_enable="YES"
growfs_enable="YES"
clear_tmp_enable="YES"
dumpdev="AUTO"
RC

echo "==> [beryl] Fuseau horaire ${TIMEZONE}"
cp "/usr/share/zoneinfo/${TIMEZONE}" /mnt/etc/localtime

echo "==> [beryl] Clés SSH autorisées pour root"
mkdir -p /mnt/root/.ssh
chmod 700 /mnt/root/.ssh
printf '%s' "${AUTHORIZED_KEYS_B64}" | b64decode -r > /mnt/root/.ssh/authorized_keys
chmod 600 /mnt/root/.ssh/authorized_keys

echo "==> [beryl] Durcissement SSH initial (beryl apply renforcera)"
mkdir -p /mnt/etc/ssh/sshd_config.d
cat > /mnt/etc/ssh/sshd_config.d/10-beryl-bootstrap.conf <<'SSHD'
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
SSHD

echo "==> [beryl] Installation du bootloader EFI"
mkdir -p /mnt/boot/efi/EFI/FreeBSD /mnt/boot/efi/EFI/BOOT
cp /mnt/boot/loader.efi /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI
cp /mnt/boot/loader.efi /mnt/boot/efi/EFI/FreeBSD/loader.efi

echo "==> [beryl] Verrouillage du dataset racine"
zfs set canmount=noauto "${POOL}/ROOT/default"

echo "==> [beryl] Démontage et export du pool"
umount /mnt/boot/efi
zfs umount -a 2>/dev/null || true
zpool export "${POOL}"

echo "==> [beryl] Installation terminée. Redémarrage requis."
