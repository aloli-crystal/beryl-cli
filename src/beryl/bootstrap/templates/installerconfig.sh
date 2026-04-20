#!/bin/sh
# installerconfig bsdinstall — généré par beryl pour __HOSTNAME__
#
# Format `bsdinstall script` :
# https://man.freebsd.org/cgi/man.cgi?query=bsdinstall
#
# Première partie : variables d'environnement et DISTRIBUTIONS lues
# par bsdinstall avant le pivot dans le système installé. Le second
# `#!/bin/sh` plus bas déclenche la phase post-install chroot (le script
# tourne dans la racine du FreeBSD fraîchement posé).
#
# Placeholders __XXX__ remplacés par beryl avant intégration à l'ISO.

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
# installé (chroot géré par bsdinstall). Le réseau est déjà configuré
# par l'installeur, donc `pkg install` fonctionne.

set -eu

HOSTNAME="__HOSTNAME__"
TIMEZONE="__TIMEZONE__"
AUTHORIZED_KEYS_B64="__AUTHORIZED_KEYS_B64__"
ABI="__ABI__"

echo "==> [beryl] hostname $HOSTNAME"
hostname "$HOSTNAME"

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
cp "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

echo "==> [beryl] installation sudo + zsh + chruby + ruby-install"
env ABI="$ABI" ASSUME_ALWAYS_YES=yes pkg install -y sudo zsh chruby ruby-install

echo "==> [beryl] création des utilisateurs admin (wheel, csh) et deploy (www, zsh)"
pw useradd admin -g staff -G wheel -s /bin/csh -m -d /home/admin
pw groupadd www -g 80 2>/dev/null || true
pw useradd deploy -g www -s /usr/local/bin/zsh -m -d /home/deploy

echo "==> [beryl] injection de la clé SSH pour admin, deploy et root"
printf '%s' "$AUTHORIZED_KEYS_B64" | b64decode -r > /tmp/keys
for user in admin deploy; do
  mkdir -p "/home/$user/.ssh"
  cp /tmp/keys "/home/$user/.ssh/authorized_keys"
  chown -R "$user" "/home/$user/.ssh"
  chmod 700 "/home/$user/.ssh"
  chmod 600 "/home/$user/.ssh/authorized_keys"
done
# root aussi (filet de diagnostic ; sshd garde PermitRootLogin no par
# défaut sur FreeBSD 15 donc pas d'accès direct).
mkdir -p /root/.ssh
cp /tmp/keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
rm -f /tmp/keys

echo "==> [beryl] sudoers : wheel NOPASSWD"
mkdir -p /usr/local/etc/sudoers.d
cat > /usr/local/etc/sudoers.d/wheel-nopasswd <<SUDO
%wheel ALL=(ALL) NOPASSWD:ALL
SUDO
chmod 440 /usr/local/etc/sudoers.d/wheel-nopasswd

echo "==> [beryl] /home/deploy/.zshenv (chruby auto + locales fr)"
cat > /home/deploy/.zshenv <<'ZSHENV'
source /usr/local/share/chruby/chruby.sh
source /usr/local/share/chruby/auto.sh
[ -f ~/.ruby-version ] && chruby "$(cat ~/.ruby-version)"
export LANG=fr_FR.UTF-8
export LC_ALL=fr_FR.UTF-8
umask 0002
ZSHENV
chown deploy:www /home/deploy/.zshenv

echo "==> [beryl] poweroff : QEMU va quitter grâce à -no-reboot, le rescue reprend la main"
poweroff
