# installerconfig bsdinstall — généré par beryl pour __HOSTNAME__
#
# ATTENTION : pas de shebang `#!/bin/sh` en tête de fichier. bsdinstall
# utilise la PREMIÈRE ligne commençant par `#!` comme séparateur entre
# préambule et post-install chroot. Si on en met un au tout début, tout
# le préambule (ZFSBOOT_*, DISTRIBUTIONS…) est ignoré, ZFSBOOT_POOL_NAME
# reste vide et bsdinstall boucle sur « Pool name cannot be empty ».
#
# Format `bsdinstall script` :
# https://man.freebsd.org/cgi/man.cgi?query=bsdinstall
#
# Première partie : variables d'environnement et DISTRIBUTIONS lues
# par bsdinstall. Le `#!/bin/sh` plus bas est le séparateur ; la phase
# post-install chroot tourne dans la racine du FreeBSD fraîchement posé.
#
# Placeholders __XXX__ remplacés par beryl avant scp dans la VM.

# Wipe des labels ZFS et GPT résiduels sur le disque cible. Sans ça, si
# /dev/vtbd1 a déjà été utilisé (ancienne install), `zpool import` dans
# bsdinstall voit un pool `zroot` existant, tente un dialogue de
# renommage qui renvoie vide en non-interactif → boucle silencieuse sur
# « Pool name cannot be empty » (observé sur loulou le 21 avril 2026).
for part in vtbd1 vtbd1p1 vtbd1p2 vtbd1p3 vtbd1p4; do
  zpool labelclear -f /dev/$part 2>/dev/null || true
done
gpart destroy -F vtbd1 2>/dev/null || true
dd if=/dev/zero of=/dev/vtbd1 bs=1M count=10 conv=notrunc 2>/dev/null || true

# ZFS auto-partitioning via bsdinstall/auto. Du point de vue de la VM
# QEMU, le disque réel passthrough apparaît comme vtbd1 (virtio-blk #1,
# le cdrom étant #0). Le résultat pose un pool nommé zroot avec une ESP
# labellée gpt/efiboot0 et un swap labellé gpt/swap0.
export ZFSBOOT_DISKS="vtbd1"
export ZFSBOOT_VDEV_TYPE="stripe"
export ZFSBOOT_SWAP_SIZE="__SWAP_GB__g"
export ZFSBOOT_POOL_NAME="__POOL_NAME__"
export nonInteractive="YES"

# Distributions pkgbase : base + kernel suffisent. Le reste arrive via
# `pkg install` plus bas dans la phase post-install.
DISTRIBUTIONS="kernel.txz base.txz"

#!/bin/sh
# Phase post-install : tourne *dans* le système FreeBSD fraîchement
# installé (chroot géré par bsdinstall). Volontairement minimaliste :
# seules les tâches qui ne dépendent que de FreeBSD base (hostname, user
# admin, ssh). Les packages (sudo, zsh, chruby…) et le user deploy sont
# installés après reboot par `beryl apply`, car `pkg install` lancé ici
# se heurte au sandbox Capsicum du chroot bsdinstall (signal 12 sur le
# process de vérification de signature pkg — erreur observée sur loulou
# le 21 avril 2026).
#
# `|| true` sur les commandes non critiques pour ne jamais empêcher le
# `poweroff` final.

set -u

HOSTNAME="__HOSTNAME__"
TIMEZONE="__TIMEZONE__"
AUTHORIZED_KEYS_B64="__AUTHORIZED_KEYS_B64__"

echo "==> [beryl] hostname $HOSTNAME"
hostname "$HOSTNAME" || true

echo "==> [beryl] /etc/rc.conf (ifconfig_DEFAULT survit au changement VM → bare metal)"
cat > /etc/rc.conf <<RC
hostname="$HOSTNAME"
ifconfig_DEFAULT="DHCP"
ifconfig_DEFAULT_ipv6="inet6 accept_rtadv"
sshd_enable="YES"
moused_nondefault_enable="NO"
dumpdev="AUTO"
zfs_enable="YES"
RC

echo "==> [beryl] /etc/fstab (labels GPT, portables entre VM et bare metal)"
cat > /etc/fstab <<FSTAB
/dev/gpt/efiboot0   /boot/efi  msdosfs  rw,late   2  2
/dev/gpt/swap0      none       swap     sw        0  0
FSTAB

echo "==> [beryl] fuseau horaire $TIMEZONE"
cp "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime || true

echo "==> [beryl] création du user admin (wheel, csh — base FreeBSD uniquement)"
pw useradd admin -g staff -G wheel -s /bin/csh -m -d /home/admin || true

echo "==> [beryl] injection de la clé SSH pour admin et root"
printf '%s' "$AUTHORIZED_KEYS_B64" | b64decode -r > /tmp/keys
mkdir -p /home/admin/.ssh
cp /tmp/keys /home/admin/.ssh/authorized_keys
chown -R admin /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys
mkdir -p /root/.ssh
cp /tmp/keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
rm -f /tmp/keys

echo "==> [beryl] poweroff : QEMU va quitter grâce à -no-reboot, le rescue reprend la main"
sync
poweroff
