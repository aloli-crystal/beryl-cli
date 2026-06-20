#!/bin/sh
# Script d'installation FreeBSD 15 en mode pkgbase, généré par beryl.
#
# Exécuté à l'intérieur d'une image mfsBSD tournant en RAM.
# Les placeholders __XXX__ sont remplacés par beryl avant upload.
#
# ATTENTION : ce script est DESTRUCTIF. Il détruit tout ce qui est sur
# TOUS les disques de __BOOT_DISKS__ (pool système) et les disques des
# pools data (cf. __DATA_POOLS_SCRIPT_B64__).
#
# Multi-disque (Phase 2) :
#   - pool boot sur N disques selon __BOOT_RAID__ (stripe/mirror/raidz…) ;
#     chaque disque est partitionné (EFI + swap + ZFS) avec des labels
#     indexés (efi0/efi1…, swap0/swap1…, zfs0/zfs1…) ;
#   - le bootloader EFI est posé sur CHAQUE disque boot (le serveur
#     démarre même si le firmware choisit un autre disque, ou si le
#     premier disque tombe) ;
#   - les pools data sont créés après le base system via un snippet
#     généré par beryl (disques partitionnés + labellisés gpt, ashift natif).

set -eu

BOOT_DISKS="__BOOT_DISKS__"
BOOT_RAID="__BOOT_RAID__"
POOL="__POOL_NAME__"
HOSTNAME="__HOSTNAME__"
FQDN="__FQDN__"
ABI="__ABI__"
SWAP_GB="__SWAP_GB__"
BOOT_ASHIFT="__BOOT_ASHIFT__"
TIMEZONE="__TIMEZONE__"
USERS_TSV_B64="__USERS_TSV_B64__"
PACKAGES="__PACKAGES__"
SUDOERS_B64="__SUDOERS_B64__"
DATA_POOLS_SCRIPT_B64="__DATA_POOLS_SCRIPT_B64__"
SYSTEM_DATASETS_SCRIPT_B64="__SYSTEM_DATASETS_SCRIPT_B64__"
# Clés autorisées pour root (base64, une par ligne). Non vide UNIQUEMENT en
# Option I (/home chiffré) → root clé-seule = porte de secours fail-safe.
ROOT_KEYS_B64="__ROOT_KEYS_B64__"

echo "==> [beryl] Disques boot : ${BOOT_DISKS} (RAID ${BOOT_RAID})"

echo "==> [beryl] Partitionnement de chaque disque boot"
i=0
ZFS_LABELS=""
for DISK in ${BOOT_DISKS}; do
  echo "    - ${DISK} : destruction GPT + création boot/EFI/swap/ZFS (index ${i})"
  gpart destroy -F "${DISK}" 2>/dev/null || true
  dd if=/dev/zero of="${DISK}" bs=1M count=10 2>/dev/null || true
  gpart create -s gpt "${DISK}"

  # Labels indexés : uniques par disque (gpt labels DOIVENT être uniques).
  # PARTITION 1 = freebsd-boot (gptzfsboot/BIOS) : CRITIQUE. OVH amorce
  # les disques en CSM/legacy → sans cette amorce BIOS, le serveur ne
  # boote PAS, même avec l'EFI parfait (constaté qgra/qsbg : pkgbase
  # UEFI-only ne bootait pas, alors que le tarball — qui a freebsd-boot
  # en p1, d'où zroot en p4 — bootait). On fait comme bsdinstall.
  gpart add -t freebsd-boot -s 512k             -l "boot${i}" "${DISK}"
  gpart add -t efi          -s 200M       -a 1M -l "efi${i}"  "${DISK}"
  newfs_msdos -F 32 -c 1 "/dev/gpt/efi${i}"
  gpart add -t freebsd-swap -s "${SWAP_GB}G" -a 1M -l "swap${i}" "${DISK}"
  gpart add -t freebsd-zfs               -a 1M -l "zfs${i}"  "${DISK}"

  ZFS_LABELS="${ZFS_LABELS} /dev/gpt/zfs${i}"
  i=$((i + 1))
done
NB_BOOT_DISKS=${i}

# Construction du vdev du pool boot selon le mode RAID. `stripe` = pas de
# mot-clé (concaténation implicite des labels). Les autres modes
# (mirror/raidz/raidz2/raidz3) préfixent le mot-clé ZFS. RAID 10
# (mirror_stripe) est refusé en amont par beryl pour le pool boot.
case "${BOOT_RAID}" in
  stripe) BOOT_VDEV="${ZFS_LABELS}" ;;
  *)      BOOT_VDEV="${BOOT_RAID} ${ZFS_LABELS}" ;;
esac

echo "==> [beryl] Création du pool ZFS ${POOL} (vdev :${BOOT_VDEV})"
# shellcheck disable=SC2086
zpool create -f \
  -o ashift="${BOOT_ASHIFT}" \
  -O canmount=off -O mountpoint=none \
  -O compression=lz4 -O atime=off \
  -R /mnt \
  "${POOL}" ${BOOT_VDEV}

echo "==> [beryl] Datasets ZFS"
zfs create -o mountpoint=none "${POOL}/ROOT"
zfs create -o mountpoint=/ "${POOL}/ROOT/default"
zfs create -o mountpoint=/tmp -o setuid=off -o exec=off "${POOL}/tmp"
chmod 1777 /mnt/tmp

# Profil C+ : si beryl fournit le script datasets système, il REMPLACE le
# /home + /var/log clairs par l'encryptionroot chiffré (zroot/encrypted/{home,
# opt,usrlocaletc}) + zroot/zlog clair. Créés ICI (montés) → le base system et
# le post-install (users/packages) écrivent DEDANS. L'`zpool export` final
# (l.~370) largue la clé → datasets verrouillés au reboot. Sinon (pas de profil) :
# /home + /var/log clairs comme avant.
SYSTEM_DATASETS_SCRIPT=$(printf '%s' "${SYSTEM_DATASETS_SCRIPT_B64}" | b64decode -r)
if [ -n "${SYSTEM_DATASETS_SCRIPT}" ]; then
  echo "==> [beryl] Datasets système chiffrés (profil C+)"
  eval "${SYSTEM_DATASETS_SCRIPT}"
else
  zfs create -o mountpoint=/home "${POOL}/home"
  zfs create -o mountpoint=/var/log "${POOL}/varlog"
fi

zpool set bootfs="${POOL}/ROOT/default" "${POOL}"

echo "==> [beryl] Monte l'EFI du premier disque (efi0) pour l'install"
mkdir -p /mnt/boot/efi
mount -t msdosfs /dev/gpt/efi0 /mnt/boot/efi

echo "==> [beryl] Repo FreeBSD-base côté hôte d'install (mfsBSD)"
# On installe le base system dans /mnt via `pkg --rootdir` (no-chroot,
# conforme ADR-013) : pkg s'exécute sur l'hôte d'install (qui a un ABI
# valide et les clés pkgbase), et dépose les paquets dans /mnt. On NE
# PEUT PAS faire `pkg -c /mnt` (chroot) car /mnt est vide → pkg n'y
# trouve aucun ABI_FILE (« Unable to determine the ABI ») — validé sur
# le banc QEMU. Le repo conf et les fingerprints vivent donc côté hôte.
mkdir -p /usr/local/etc/pkg/repos
cat > /usr/local/etc/pkg/repos/FreeBSD-base.conf <<'REPO'
FreeBSD-base: {
  url: "pkg+https://pkg.freebsd.org/${ABI}/base_release_0",
  mirror_type: "srv",
  signature_type: "fingerprints",
  # Clés du BASE (cf. /etc/pkg/FreeBSD.conf de 15.0-RELEASE), PAS
  # /usr/share/keys/pkg (= clés des PORTS). `${VERSION_MAJOR}` → 15.
  fingerprints: "/usr/share/keys/pkgbase-${VERSION_MAJOR}",
  enabled: yes
}
REPO

echo "==> [beryl] Copie des clés pkgbase dans la cible"
# `pkg --rootdir /mnt` résout le chemin `fingerprints` RELATIVEMENT à
# /mnt → il cherche /mnt/usr/share/keys/pkgbase-<maj>/trusted. On copie
# donc les clés de l'hôte d'install dans la cible (validé sur le banc :
# sans ça, « Error opening the trusted directory »).
VMAJ=$(uname -r | cut -d. -f1)
mkdir -p /mnt/usr/share/keys
cp -R "/usr/share/keys/pkgbase-${VMAJ}" /mnt/usr/share/keys/

echo "==> [beryl] Installation de la base via les SETS pkgbase (méthode bsdinstall)"
# Sélection des paquets À L'IDENTIQUE de l'installeur officiel bsdinstall
# (usr.sbin/bsdinstall/scripts/pkgbase.in, select_packages) — PAS une liste
# à la main, qui donnait une base INCOMPLÈTE (gpart/devd manquants → pas de
# réseau ni de labels). bsdinstall installe des MÉTA-PAQUETS « sets »
# FreeBSD-set-* et laisse pkg résoudre les dépendances = base complète.
# Toujours : set-minimal + le kernel (FreeBSD-kernel-generic) + pkg ; +
# set-base (= « complete base system »). On OMET kernel-dbg/lib32 (symboles
# debug, compat 32-bit) : inutiles sur un serveur, et bsdinstall ne les
# coche par défaut que pour l'usage général ; réinstallables via pkg ensuite
# (le repo base est activé ci-dessous).
env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir /mnt update -f -r FreeBSD-base
if pkg --rootdir /mnt rquery -U -r FreeBSD-base '%n' 2>/dev/null | grep -qx 'FreeBSD-set-base'; then
  echo "    sets : FreeBSD-set-minimal FreeBSD-set-base FreeBSD-kernel-generic pkg"
  env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir /mnt install -U -y -r FreeBSD-base \
    FreeBSD-set-minimal FreeBSD-set-base FreeBSD-kernel-generic pkg
else
  # Repo sans méta-paquets set-* (média custom / version antérieure) :
  # repli sur TOUTE la base filtrée (hors -dbg/-lib32/-tests).
  echo "    pas de sets FreeBSD-set-* → repli sur toute la base filtrée"
  BASE_PKGS=$(pkg --rootdir /mnt rquery -U -r FreeBSD-base '%n' 2>/dev/null | grep -vE '(-dbg|-lib32|-tests)$' | tr '\n' ' ')
  # shellcheck disable=SC2086
  env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir /mnt install -U -y -r FreeBSD-base ${BASE_PKGS}
fi

echo "==> [beryl] Activation du repo FreeBSD-base sur le système installé"
# Pour que le serveur puisse mettre à jour sa base via `pkg upgrade` (=
# l'intérêt de pkgbase). bsdinstall fait de même. pkg développe ${ABI}.
mkdir -p /mnt/usr/local/etc/pkg/repos
cp /usr/local/etc/pkg/repos/FreeBSD-base.conf /mnt/usr/local/etc/pkg/repos/

echo "==> [beryl] Configuration /boot/loader.conf"
cat > /mnt/boot/loader.conf <<'LOADER'
zfs_load="YES"
LOADER

echo "==> [beryl] Configuration /etc/fstab (swaps uniquement, PAS /boot/efi)"
# On NE met PAS /boot/efi dans la fstab. CAUSE RACINE du non-boot pkgbase
# (vue via IPMI sur qsbg) : la fsck_msdosfs de /boot/efi au boot (pass 2)
# échoue (« Can't open /dev/gpt/efi0 → UNEXPECTED INCONSISTENCY →
# Automatic file system check failed → ABORTING BOOT ») et tombe en
# single-user → pas de réseau/sshd. Or l'EFI n'a PAS besoin d'être montée
# au runtime (seulement à l'install/màj). bsdinstall ne la met pas non
# plus. NB : les labels /dev/gpt/* ne sont pas tous prêts tôt au rc → le
# swap peut warner « No such file » (non fatal, à durcir séparément).
{
  j=0
  while [ "${j}" -lt "${NB_BOOT_DISKS}" ]; do
    echo "/dev/gpt/swap${j}  none       swap     sw        0  0"
    j=$((j + 1))
  done
} > /mnt/etc/fstab

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

echo "==> [beryl] Installation des paquets (${PACKAGES:-aucun})"
if [ -n "${PACKAGES}" ]; then
  # Le repo pkg par défaut (FreeBSD-ports) signe par fingerprints dans
  # /usr/share/keys/pkg ; avec --rootdir, pkg les cherche sous /mnt.
  # ATTENTION : la base pkgbase crée parfois le DOSSIER
  # /mnt/usr/share/keys/pkg mais VIDE (sans trusted/) → « No trusted
  # certificates ». On peuple donc TOUJOURS depuis l'hôte d'install (pas
  # de skip-si-présent — le bug de la 1re passe in vivo).
  mkdir -p /mnt/usr/share/keys/pkg
  cp -Rf /usr/share/keys/pkg/. /mnt/usr/share/keys/pkg/ 2>/dev/null || true
  echo "    DIAG clés ports (hôte) : $(ls /usr/share/keys/pkg/trusted/ 2>/dev/null | tr '\n' ' ')"
  echo "    DIAG clés ports (/mnt) : $(ls /mnt/usr/share/keys/pkg/trusted/ 2>/dev/null | tr '\n' ' ')"
  # Sans `pkg update`, le repo ports « cannot be opened. pkg update
  # required » (catalogue absent dans /mnt/var/db/pkg). On le récupère
  # explicitement (|| true : un repo annexe type ports-kmods peut
  # échouer sans bloquer l'install des paquets demandés).
  # IGNORE_OSVERSION : /mnt pkgbase n'expose pas toujours l'OSVERSION →
  # évite le refus « guessing the OSVERSION ». Hors chroot (--rootdir)
  # → pas de bug Capsicum signal 12.
  # shellcheck disable=SC2086
  env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir /mnt update -f || true
  # shellcheck disable=SC2086
  env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir /mnt install -y ${PACKAGES}
fi

echo "==> [beryl] Création des utilisateurs (zéro accès root : admin + sudo)"
# USERS_TSV format : name|primary_group|secondary_groups|shell|key1,key2
# (un user par ligne ; groupes séparés par des virgules). Les shells
# (ex. /usr/local/bin/zsh) existent maintenant que les paquets sont posés.
USERS_TSV=$(printf '%s' "${USERS_TSV_B64}" | b64decode -r)
printf '%s\n' "${USERS_TSV}" | while IFS='|' read -r UNAME PGROUP SGROUPS USHELL UKEYS; do
  [ -z "${UNAME}" ] && continue
  echo "    - ${UNAME} (g=${PGROUP}, G=${SGROUPS}, shell=${USHELL})"
  pw -R /mnt groupshow "${PGROUP}" 2>/dev/null || pw -R /mnt groupadd "${PGROUP}"
  if [ -n "${SGROUPS}" ]; then
    echo "${SGROUPS}" | tr ',' '\n' | while read -r SG; do
      [ -z "${SG}" ] && continue
      pw -R /mnt groupshow "${SG}" 2>/dev/null || pw -R /mnt groupadd "${SG}"
    done
  fi
  GFLAG=""
  [ -n "${SGROUPS}" ] && GFLAG="-G ${SGROUPS}"
  # shellcheck disable=SC2086
  pw -R /mnt useradd -n "${UNAME}" -d "/home/${UNAME}" -g "${PGROUP}" ${GFLAG} -m -s "${USHELL}"
  mkdir -p "/mnt/home/${UNAME}/.ssh"
  if [ -n "${UKEYS}" ]; then
    echo "${UKEYS}" | tr ',' '\n' | while read -r K; do
      [ -z "${K}" ] && continue
      echo "${K}" >> "/mnt/home/${UNAME}/.ssh/authorized_keys"
    done
  fi
  # Clé d'identité du user (ed25519, commentaire user@fqdn), générée si absente.
  [ -f "/mnt/home/${UNAME}/.ssh/id_ed25519" ] || \
    ssh-keygen -t ed25519 -C "${UNAME}@${FQDN}" -f "/mnt/home/${UNAME}/.ssh/id_ed25519" -N "" -q
  UID_NEW=$(pw -R /mnt usershow "${UNAME}" | cut -d: -f3)
  GID_PG=$(pw -R /mnt groupshow "${PGROUP}" | cut -d: -f3)
  chown -R "${UID_NEW}:${GID_PG}" "/mnt/home/${UNAME}/.ssh"
  chmod 700 "/mnt/home/${UNAME}/.ssh"
  [ -f "/mnt/home/${UNAME}/.ssh/authorized_keys" ] && chmod 600 "/mnt/home/${UNAME}/.ssh/authorized_keys"
  chmod 600 "/mnt/home/${UNAME}/.ssh/id_ed25519"
done

echo "==> [beryl] Garde anti-lock-out : au moins un user avec clé SSH"
# CRITIQUE : root SSH est coupé (PermitRootLogin no). Si AUCUN user n'a
# de authorized_keys non vide, le serveur serait inaccessible au reboot.
# On préfère ÉCHOUER l'install (récupérable depuis le rescue) plutôt que
# de livrer un serveur verrouillé. (Bug « admin sans clé SSH » constaté
# terrain — d'où cette vérif explicite.)
NB_KEYED=0
for AK in /mnt/home/*/.ssh/authorized_keys; do
  [ -s "${AK}" ] && NB_KEYED=$((NB_KEYED + 1))
done
if [ "${NB_KEYED}" -eq 0 ]; then
  echo "ERREUR [beryl] : aucun utilisateur n'a de clé SSH et root est coupé → abandon (serveur sinon verrouillé)." >&2
  exit 1
fi
echo "    ${NB_KEYED} utilisateur(s) avec clé SSH — OK"

echo "==> [beryl] sudoers.d/beryl"
if [ -n "${SUDOERS_B64}" ]; then
  mkdir -p /mnt/usr/local/etc/sudoers.d
  printf '%s' "${SUDOERS_B64}" | b64decode -r > /mnt/usr/local/etc/sudoers.d/beryl
  chmod 440 /mnt/usr/local/etc/sudoers.d/beryl
fi

# Option I (/home chiffré) : root clé-seule TOUJOURS ouvert = porte de secours
# fail-safe. Les authorized_keys de l'opérateur sont dans /home (chiffré, donc
# illisible avant unlock) → si root était coupé, IMPOSSIBLE de SSH pour lancer
# `beryl unlock` → brick sans IPMI. /root est CLAIR (zroot/ROOT/default) → on y
# pose les clés, lisibles avant tout unlock. beryl unlock se connecte en root.
# Voir zpool-encryption-architecture.adoc § « Accès SSH au boot ».
# Sinon (pas de profil) : root COUPÉ (durcissement historique, accès user+sudo).
if [ -n "${SYSTEM_DATASETS_SCRIPT}" ]; then
  echo "==> [beryl] SSH : root CLÉ-SEULE (porte de secours fail-safe, /home chiffré)"
  PERMIT_ROOT="prohibit-password"
  mkdir -p /mnt/root/.ssh
  printf '%s' "${ROOT_KEYS_B64}" | b64decode -r > /mnt/root/.ssh/authorized_keys
  chmod 700 /mnt/root/.ssh
  chmod 600 /mnt/root/.ssh/authorized_keys
else
  echo "==> [beryl] SSH : ROOT COUPÉ d'emblée (accès uniquement par user + sudo)"
  PERMIT_ROOT="no"
fi
mkdir -p /mnt/etc/ssh/sshd_config.d
cat > /mnt/etc/ssh/sshd_config.d/10-beryl-bootstrap.conf <<SSHD
PermitRootLogin ${PERMIT_ROOT}
PasswordAuthentication no
ChallengeResponseAuthentication no
SSHD

# FreeBSD ne met PAS d'Include sshd_config.d/*.conf par défaut → sans lui,
# le drop-in ci-dessus (et ceux de `beryl apply`) seraient écrits mais
# jamais lus. On le pose EN TÊTE pour que les drop-ins priment.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /mnt/etc/ssh/sshd_config 2>/dev/null; then
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > /mnt/etc/ssh/sshd_config.new
  cat /mnt/etc/ssh/sshd_config >> /mnt/etc/ssh/sshd_config.new 2>/dev/null || true
  mv /mnt/etc/ssh/sshd_config.new /mnt/etc/ssh/sshd_config
fi

echo "==> [beryl] Installation du bootloader EFI sur CHAQUE disque boot"
# Nom du fallback EFI selon l'architecture (BOOTX64 sur amd64,
# BOOTAA64 sur arm64) — sinon le firmware UEFI ne trouve pas le
# loader. Validé sur le banc QEMU aarch64.
case "$(uname -m)" in
  amd64) EFI_FALLBACK="BOOTX64.EFI" ;;
  arm64 | aarch64) EFI_FALLBACK="BOOTAA64.EFI" ;;
  *) EFI_FALLBACK="BOOTX64.EFI" ;;
esac
# efi0 est déjà monté sur /mnt/boot/efi. Pour les autres disques, on
# monte temporairement leur partition EFI et on y copie le même loader,
# de sorte que le serveur boote quel que soit le disque choisi par le
# firmware (et survive à la perte du premier disque dans un mirror).
k=0
while [ "${k}" -lt "${NB_BOOT_DISKS}" ]; do
  if [ "${k}" -eq 0 ]; then
    EFI_MNT="/mnt/boot/efi"
  else
    EFI_MNT="/tmp/efi${k}"
    mkdir -p "${EFI_MNT}"
    mount -t msdosfs "/dev/gpt/efi${k}" "${EFI_MNT}"
  fi
  mkdir -p "${EFI_MNT}/EFI/FreeBSD" "${EFI_MNT}/EFI/BOOT"
  cp /mnt/boot/loader.efi "${EFI_MNT}/EFI/BOOT/${EFI_FALLBACK}"
  cp /mnt/boot/loader.efi "${EFI_MNT}/EFI/FreeBSD/loader.efi"
  [ "${k}" -ne 0 ] && umount "${EFI_MNT}"
  k=$((k + 1))
done

echo "==> [beryl] Amorce BIOS/legacy (gptzfsboot) sur CHAQUE disque boot"
# pmbr (MBR de protection) + gptzfsboot (amorce ZFS BIOS) dans la
# partition freebsd-boot (index 1). INDISPENSABLE : OVH amorce les
# disques en CSM/legacy → sans ça, pas de boot même avec l'EFI parfait
# (constaté in vivo). Fichiers depuis la cible (/mnt/boot, posés par
# FreeBSD-bootloader) → version alignée sur le FreeBSD installé.
# shellcheck disable=SC2086
for DISK in ${BOOT_DISKS}; do
  gpart bootcode -b /mnt/boot/pmbr -p /mnt/boot/gptzfsboot -i 1 "${DISK}"
  echo "    - ${DISK} : gptzfsboot écrit (freebsd-boot p1)"
done

echo "==> [beryl] Verrouillage du dataset racine"
zfs set canmount=noauto "${POOL}/ROOT/default"

# Parité hostid : les pools data sont créés par CETTE VM mfsBSD (son
# hostid). Sans /etc/hostid identique côté cible, le FreeBSD installé a un
# hostid différent → « pool was last accessed by another system » → pas
# d'auto-import au boot (constaté qgra). On copie donc le hostid de la VM
# dans la cible pour que les deux concordent.
cp /etc/hostid /mnt/etc/hostid 2>/dev/null || true

# Pools data : créés MAINTENANT (depuis mfsBSD) sur partitions freebsd-zfs
# LABELLISÉES (gpt/<pool><i>, cf. data_pools_script) — noms stables et
# cohérents comme le pool boot, plutôt que des disques entiers. -R /mnt
# pour que leur cache atterrisse dans /mnt/boot/zfs/zpool.cache et qu'ils
# soient ré-importés au boot (zfs_enable=YES). Vide si aucun pool data.
DATA_POOLS_SCRIPT=$(printf '%s' "${DATA_POOLS_SCRIPT_B64}" | b64decode -r)
if [ -n "${DATA_POOLS_SCRIPT}" ]; then
  echo "==> [beryl] Création des pools data"
  # shellcheck disable=SC1090
  eval "${DATA_POOLS_SCRIPT}"
fi

echo "==> [beryl] Démontage et export du pool boot"
umount /mnt/boot/efi 2>/dev/null || true
zfs umount -a 2>/dev/null || true
# On n'exporte QUE le pool boot. Les pools data NON chiffrés restent
# importés avec leur cachefile pointant vers /mnt/boot/zfs/zpool.cache :
# au reboot, zfs_enable=YES les ré-importe depuis ce cache. Les exporter
# ici les retirerait du cache → import manuel requis (bug constaté
# terrain quantas, cf. data_pools_script). Les pools data CHIFFRÉS ont
# déjà été exportés par le snippet (clé non chargée → import via beryl unlock).
zpool export "${POOL}"

echo "==> [beryl] Installation terminée. Redémarrage requis."
