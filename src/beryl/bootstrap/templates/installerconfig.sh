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

# NOTE : volontairement PAS de wipe automatique du disque ici. Si le
# disque porte déjà une install BSD, le pré-check côté rescue (avant
# même le lancement QEMU) aura refusé de démarrer le bootstrap et
# affiché un message demandant à l'opérateur de réinstaller un rescue
# neuf. Wiper silencieusement serait un piège à perte de données en
# batch. Voir le garde-fou dans Beryl::Bootstrap::QemuInRescue#check_target_disk_is_empty.

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

echo "==> [beryl] création du user admin (groupe primaire www, secondaire wheel, shell csh)"
pw useradd -n admin -d /home/admin -g www -G wheel -m -s /bin/csh
id admin
test -d /home/admin || { echo "ERREUR : /home/admin n'existe pas après useradd -m" >&2; exit 1; }

echo "==> [beryl] injection de la clé SSH pour admin uniquement"
# Volontairement PAS de clé root + PAS de PermitRootLogin : FreeBSD
# applique le défaut 'no' et c'est ce qu'on veut. admin (wheel) passera
# par sudo (installé en phase ultérieure).
printf '%s' "$AUTHORIZED_KEYS_B64" | b64decode -r > /tmp/keys
mkdir -p /home/admin/.ssh
cp /tmp/keys /home/admin/.ssh/authorized_keys
chown -R admin:www /home/admin/.ssh
chmod 700 /home/admin/.ssh
chmod 600 /home/admin/.ssh/authorized_keys
rm -f /tmp/keys

echo "==> [beryl] poweroff : QEMU va quitter grâce à -no-reboot, le rescue reprend la main"
sync
poweroff
