#!/bin/bash
# Driver shell mfsBSD-in-QEMU exécuté côté rescue Linux. UN SEUL ssh
# depuis le laptop vers le rescue pour lancer ce script ; plus aucun
# nested ssh côté Crystal Process.run → plus de hang macOS.
#
# Le script pilote intégralement la VM mfsBSD via `ssh_vm`/`scp_to_vm`
# (sshpass + keyboard-interactive côté mfsBSD-SE). Tout le POST-INSTALL
# se fait HORS CHROOT, en ciblant `/mnt/…` depuis mfsBSD : on contourne
# ainsi le bug Capsicum signal 12 qui tuait `pkg install` dans le chroot
# bsdinstall (voir ADR-013 et validation manuelle loulou 21 avril 2026).
#
# Chaque ligne en MAJUSCULES entourée de tirets (voir ci-dessous) est
# une variable substituée par beryl avant upload via scp.
#
# Étapes :
#   0. Lance QEMU en systemd-run --unit=qemu-vm (survit à la fermeture ssh)
#   1. Attend SSH mfsBSD
#   2. Pré-fetch MANIFEST + base.txz + kernel.txz dans la VM
#   3. scp installerconfig + lance bsdinstall (préambule seul : partition + extract)
#   4. Re-monte ZFS sur /mnt (bsdinstall termine par umount)
#   5. Post-install piloté : users, rc.conf, fstab, localtime, pkg -r /mnt, sudoers
#   6. Unmount ZFS + poweroff (QEMU exit via -no-reboot)
#
# Sortie 0 = OK, non-nul = étape nommée échouée.
set -eu

VM_HOST="__VM_HOST__"
VM_PORT="__VM_PORT__"
VM_PASSWORD="__VM_PASSWORD__"
INSTALLERCFG_PATH="__INSTALLERCFG_PATH__"
VM_BOOT_SEC="__VM_BOOT_SEC__"
QEMU_MAX_SEC="__QEMU_MAX_SEC__"
QEMU_PATTERN="__QEMU_PATTERN__"
QEMU_SERIAL="__QEMU_SERIAL__"
DISTSITE="__DISTSITE__"
FREEBSD_VERSION="__FREEBSD_VERSION__"
ABI="__ABI__"
HOSTNAME="__HOSTNAME__"
FQDN="__FQDN__"
TIMEZONE="__TIMEZONE__"

# Post-install config passé en clair (sans base64, on reste shell-natif).
# `USERS_SPEC` est un JSON-like compact : un user par ligne, champs
# séparés par `|` dans l'ordre name|uid|gid|primary_group|secondary_groups|shell|home|keys_b64
# C'est moche mais indemne à traduction Crystal-shell ; le format sera
# remplacé par du vrai YAML quand le loader sera prêt.
USERS_TSV='__USERS_TSV__'
PACKAGES='__PACKAGES__'
SUDOERS_CONTENT='__SUDOERS_CONTENT_B64__'
# Script shell base64 (vide = pas de pool data à créer). Contient
# une série de `zpool create -R /mnt -m <mp> <nom> <vdev> vtbdN vtbdM...`
# Les vtbd* sont mappés par beryl dans l'ordre des disques passés à QEMU
# (vtbd0 = mfsBSD ; vtbd1..vtbdB = pool boot ; vtbd(B+1)..vtbdN = pools data).
DATA_POOLS_SCRIPT='__DATA_POOLS_SCRIPT_B64__'
# Datasets système chiffrés du profil C+ (zroot/encrypted/{home,opt,usrlocaletc}
# + zroot/zlog clair). Créés AVANT le post-install (les homes/configs s'y écrivent).
SYSTEM_DATASETS_SCRIPT='__SYSTEM_DATASETS_SCRIPT_B64__'
# Clés SSH root (base64, union des clés des users) — posées dans /root/.ssh
# UNIQUEMENT en profil Option I (datasets système chiffrés), pour la porte de
# secours fail-safe : root clé-seule reste joignable avant tout `beryl unlock`
# (les authorized_keys opérateur de /home sont chiffrés au boot). Vide hors profil.
ROOT_KEYS_B64='__ROOT_KEYS_B64__'
# Type d'install : "distribution_sets" (bsdinstall + tarballs) ou
# "packages" (pkgbase via install-pkgbase.sh). Chemin du script pkgbase
# déposé sur le rescue (scp'é dans la VM par la branche pkgbase).
INSTALL_TYPE="__INSTALL_TYPE__"
INSTALL_PKGBASE_PATH="__INSTALL_PKGBASE_PATH__"

# ----------------------------------------------------------------------
# Helpers ssh (wrappers sshpass avec timeouts différenciés)
# ----------------------------------------------------------------------
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o PreferredAuthentications=keyboard-interactive \
          -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
          -o ConnectTimeout=5"

ssh_vm() {
  # shellcheck disable=SC2086
  timeout 20 sshpass -p "$VM_PASSWORD" ssh $SSH_OPTS -p "$VM_PORT" "root@$VM_HOST" "$@"
}

ssh_vm_long() {
  # shellcheck disable=SC2086
  timeout 1800 sshpass -p "$VM_PASSWORD" ssh $SSH_OPTS -p "$VM_PORT" "root@$VM_HOST" "$@"
}

scp_to_vm() {
  # shellcheck disable=SC2086
  timeout 60 sshpass -p "$VM_PASSWORD" scp $SSH_OPTS -P "$VM_PORT" "$1" "root@$VM_HOST:$2"
}

# ----------------------------------------------------------------------
# Étape 0 — lance QEMU via systemd-run (détaché de la session ssh)
# ----------------------------------------------------------------------
# On stoppe TOUJOURS l'unité qemu-vm existante avant de relancer :
# une VM survivante d'un run précédent peut tourner sur une ancienne
# image mfsBSD (version différente) et produire un mismatch subtil avec
# les tarballs qu'on s'apprête à extraire. Mieux vaut un boot frais à
# chaque run.

if systemctl is-active --quiet qemu-vm.service; then
  echo "[rescue-run-vm] unité qemu-vm.service active : arrêt pour repartir sur une VM fraîche"
  systemctl stop qemu-vm.service || true
  # Laisse le temps au process de vraiment sortir avant qu'on réutilise
  # le même port hôte (2223).
  for _ in 1 2 3 4 5; do
    systemctl is-active --quiet qemu-vm.service || break
    sleep 1
  done
  systemctl reset-failed qemu-vm.service 2>/dev/null || true
fi

: > "$QEMU_SERIAL"
systemd-run --unit=qemu-vm --description='beryl bootstrap QEMU' \
  /usr/bin/qemu-system-x86_64 -enable-kvm -machine q35 -cpu host \
  -smp __QEMU_CPUS__ -m __QEMU_RAM_MB__M \
  -drive if=pflash,format=raw,readonly=on,file=__OVMF_CODE_SOURCE__ \
  -drive if=pflash,format=raw,file=__OVMF_VARS_PATH__ \
  -drive file=__MFSBSD_PATH__,format=raw,if=virtio \
  __QEMU_TARGET_DISKS__ \
  -netdev user,id=net0,hostfwd=tcp::__VM_PORT__-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic -serial file:"$QEMU_SERIAL" -no-reboot
echo "[rescue-run-vm] QEMU lancé dans systemd unit qemu-vm.service"

# ----------------------------------------------------------------------
# Étape 1 — attend SSH mfsBSD
# ----------------------------------------------------------------------

echo "[rescue-run-vm] attente SSH mfsBSD (timeout ${VM_BOOT_SEC}s)..."
start=$(date +%s)
while true; do
  if ssh_vm 'uname -s' 2>/dev/null | grep -q '^FreeBSD$'; then
    echo "[rescue-run-vm] VM mfsBSD répond (après $(($(date +%s) - start))s)"
    break
  fi
  if [ $(($(date +%s) - start)) -ge "$VM_BOOT_SEC" ]; then
    echo "[rescue-run-vm] TIMEOUT boot mfsBSD" >&2
    exit 1
  fi
  sleep 5
done

# ----------------------------------------------------------------------
# BRANCHE pkgbase — install_type: packages
# ----------------------------------------------------------------------
# Le script install-pkgbase.sh est autonome (partition + ZFS +
# `pkg install FreeBSD-*` + config + bootloader + export). Il remplace
# entièrement les étapes bsdinstall/tarball ci-dessous. Validé in vivo
# (boot FreeBSD 15). La cible est /dev/vtbd1 dans la VM (1er disque
# passthrough). Réutilise tout le boot QEMU + helpers ssh_vm ci-dessus.
if [ "$INSTALL_TYPE" = "packages" ]; then
  echo "[rescue-run-vm] pkgbase : upload de install-pkgbase.sh dans la VM"
  scp_to_vm "$INSTALL_PKGBASE_PATH" "/tmp/install-pkgbase.sh"
  echo "[rescue-run-vm] pkgbase : exécution (partition + pkg base + bootloader, ~3-6 min)"
  ssh_vm_long "sh /tmp/install-pkgbase.sh"
  echo "[rescue-run-vm] pkgbase : install terminée, poweroff de la VM"
  ssh_vm "poweroff" >/dev/null 2>&1 || true
  exit 0
fi

# ----------------------------------------------------------------------
# Étape 2 — s'assure que MANIFEST + base.txz + kernel.txz sont présents
# ----------------------------------------------------------------------
# mfsBSD SE embarquait historiquement ces dists (versions 14.x sur
# vx.sk). Les releases GitHub actuelles (15.0+) ne les embarquent plus
# — l'ISO est allégé (~336 MB vs ~432 MB). On télécharge à la demande
# si manquant, depuis le mirror FreeBSD officiel. Le `test -s <file>`
# évite tout re-download quand les dists sont déjà là.
#
# mfsBSD SE et la version FreeBSD cible sont synchronisés (même X.Y),
# donc pas de mismatch pkg dans le post-install.

echo "[rescue-run-vm] s'assure que MANIFEST + base.txz + kernel.txz sont disponibles dans la VM"
ssh_vm_long "mkdir -p /usr/freebsd-dist && cd /usr/freebsd-dist && \
  (test -s MANIFEST   || fetch -q -o MANIFEST   $DISTSITE/MANIFEST) && \
  (test -s base.txz   || fetch -q -o base.txz   $DISTSITE/base.txz) && \
  (test -s kernel.txz || fetch -q -o kernel.txz $DISTSITE/kernel.txz) && \
  ls -la MANIFEST base.txz kernel.txz"

# ----------------------------------------------------------------------
# Étape 3 — scp installerconfig + bsdinstall (préambule seul)
# ----------------------------------------------------------------------

echo "[rescue-run-vm] upload installerconfig vers /tmp/installerconfig"
scp_to_vm "$INSTALLERCFG_PATH" "/tmp/installerconfig"

echo "[rescue-run-vm] lance bsdinstall script (partition + extract, ~3 min)"
ssh_vm_long "BSDINSTALL_DISTSITE=$DISTSITE bsdinstall script /tmp/installerconfig"

# ----------------------------------------------------------------------
# Étape 4 — re-monte ZFS sur /mnt
# ----------------------------------------------------------------------
# bsdinstall termine par `umount`. Pour écrire dans le rootfs on remonte.

echo "[rescue-run-vm] remonte ZFS zroot sur /mnt"
ssh_vm "zpool import -f -N -R /mnt zroot && zfs mount zroot/ROOT/default && zfs mount -a"

# ----------------------------------------------------------------------
# Étape 4b — datasets système chiffrés (profil C+), AVANT le post-install
# ----------------------------------------------------------------------
# Crée zroot/encrypted (+ enfants /home,/opt,/usr/local/etc) chiffrés + zroot/zlog
# clair, MONTÉS sur /mnt/<mp>. Les users/packages de l'Étape 5 écrivent donc DANS
# ces datasets (et non dans zroot/ROOT/default qui serait masqué au montage). La
# clé est larguée par l'`zpool export -a` de l'Étape 6 → datasets verrouillés au
# reboot (l'opérateur fera `beryl unlock`).
if [ -n "$SYSTEM_DATASETS_SCRIPT" ]; then
  echo "[rescue-run-vm] datasets système chiffrés (profil C+)"
  ssh_vm_long "$(echo "$SYSTEM_DATASETS_SCRIPT" | base64 -d)"
fi

# ----------------------------------------------------------------------
# Étape 5 — post-install HORS CHROOT, ciblant /mnt
# ----------------------------------------------------------------------

echo "[rescue-run-vm] rc.conf + fstab + timezone"
ssh_vm "cat > /mnt/etc/rc.conf <<RC
hostname=\"$HOSTNAME\"
ifconfig_DEFAULT=\"DHCP\"
ifconfig_DEFAULT_ipv6=\"inet6 accept_rtadv\"
sshd_enable=\"YES\"
moused_nondefault_enable=\"NO\"
dumpdev=\"AUTO\"
zfs_enable=\"YES\"
RC
cat > /mnt/etc/fstab <<FSTAB
/dev/gpt/efiboot0   /boot/efi  msdosfs  rw,late   2  2
/dev/gpt/swap0      none       swap     sw        0  0
FSTAB
cp /mnt/usr/share/zoneinfo/$TIMEZONE /mnt/etc/localtime"

echo "[rescue-run-vm] users"
# USERS_TSV format: name|primary_group|secondary_groups|shell|key1,key2,key3
# (un user par ligne, groups séparés par des virgules)
echo "$USERS_TSV" | while IFS='|' read -r UNAME PGROUP SGROUPS USHELL UKEYS; do
  [ -z "$UNAME" ] && continue
  echo "[rescue-run-vm]   user $UNAME (g=$PGROUP, G=$SGROUPS, shell=$USHELL)"
  # Groupe primaire : créer si absent
  ssh_vm "pw -R /mnt groupshow $PGROUP 2>/dev/null || pw -R /mnt groupadd $PGROUP"
  # Groupes secondaires : même
  if [ -n "$SGROUPS" ]; then
    echo "$SGROUPS" | tr ',' '\n' | while read -r SG; do
      [ -z "$SG" ] && continue
      ssh_vm "pw -R /mnt groupshow $SG 2>/dev/null || pw -R /mnt groupadd $SG"
    done
  fi
  # User
  GFLAG=""; [ -n "$SGROUPS" ] && GFLAG="-G $SGROUPS"
  ssh_vm "pw -R /mnt useradd -n $UNAME -d /home/$UNAME -g $PGROUP $GFLAG -m -s $USHELL"
  # /mnt/home peut être un dataset ZFS dédié OU un répertoire du dataset
  # racine. Dans les deux cas on crée le dossier .ssh du user.
  ssh_vm "mkdir -p /mnt/home/$UNAME/.ssh"
  # Clés SSH de connexion (authorized_keys). Bug potentiel : ssh dans un
  # pipe while consomme le stdin du pipe → on isole avec `< /dev/null`.
  if [ -n "$UKEYS" ]; then
    echo "$UKEYS" | tr ',' '\n' | while read -r K; do
      [ -z "$K" ] && continue
      ssh_vm "echo '$K' >> /mnt/home/$UNAME/.ssh/authorized_keys" < /dev/null
    done
  fi
  # Clé d'identité du user (ed25519, commentaire user@fqdn), si absente.
  ssh_vm "[ -f /mnt/home/$UNAME/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -C $UNAME@$FQDN -f /mnt/home/$UNAME/.ssh/id_ed25519 -N '' -q" < /dev/null
  UID_NEW=$(ssh_vm "pw -R /mnt usershow $UNAME" | cut -d: -f3)
  GID_PG=$(ssh_vm "pw -R /mnt groupshow $PGROUP" | cut -d: -f3)
  ssh_vm "chown -R $UID_NEW:$GID_PG /mnt/home/$UNAME/.ssh; chmod 700 /mnt/home/$UNAME/.ssh; chmod 600 /mnt/home/$UNAME/.ssh/id_ed25519; [ -f /mnt/home/$UNAME/.ssh/authorized_keys ] && chmod 600 /mnt/home/$UNAME/.ssh/authorized_keys"
done

# ----------------------------------------------------------------------
# Étape 5bis — DIAGNOSTIC post-users : log explicite de l'état des
# homes et authorized_keys pour traquer le bug « admin sans clé SSH »
# observé sur cookie le 24 avril 2026.
# ----------------------------------------------------------------------
echo "[rescue-run-vm] DIAG : état /mnt/home après création users"
ssh_vm "
  echo '--- mount | /mnt/home ---'
  mount | grep /mnt || true
  echo '--- ls /mnt/home ---'
  ls -la /mnt/home/ 2>&1 || true
  echo '--- dataset ZFS pour /mnt/home ---'
  zfs list -H -o name,mountpoint 2>/dev/null | grep -E '(home|^NAME)' || true
  echo '--- par user ---'
  for U in \$(awk -F: '\$3 >= 1000 {print \$1}' /mnt/etc/passwd); do
    echo \"=== \$U ===\"
    ls -la /mnt/home/\$U/.ssh/ 2>&1 || echo '(pas de .ssh/)'
    if [ -f /mnt/home/\$U/.ssh/authorized_keys ]; then
      echo 'authorized_keys:'
      sed 's/^/  /' /mnt/home/\$U/.ssh/authorized_keys
    fi
  done
"

if [ -n "$PACKAGES" ]; then
  echo "[rescue-run-vm] pkg -r /mnt install (hors chroot → pas de Capsicum)"
  # mfsBSD SE et /mnt partagent la même version FreeBSD (14.2), donc
  # plus d'IGNORE_OSVERSION : pkg est parfaitement cohérent.
  ssh_vm_long "env ABI=$ABI pkg -r /mnt install -y $PACKAGES"
fi

if [ -n "$SUDOERS_CONTENT" ]; then
  echo "[rescue-run-vm] sudoers.d/beryl"
  ssh_vm "mkdir -p /mnt/usr/local/etc/sudoers.d && \
    echo '$SUDOERS_CONTENT' | base64 -d > /mnt/usr/local/etc/sudoers.d/beryl && \
    chmod 440 /mnt/usr/local/etc/sudoers.d/beryl"
fi

# ----------------------------------------------------------------------
# Étape 5c — SSH : porte de secours root fail-safe (profil Option I)
# ----------------------------------------------------------------------
# Profil Option I (datasets système chiffrés) : root CLÉ-SEULE TOUJOURS ouvert.
# Les authorized_keys opérateur vivent dans /home (chiffré → illisible avant
# unlock) ; si root était coupé, IMPOSSIBLE de SSH pour lancer `beryl unlock`
# → brick sans IPMI. /root est CLAIR (zroot/ROOT/default) → on y pose les clés.
# `beryl unlock` se connecte alors en root. Sinon (pas de profil) : root COUPÉ
# (durcissement historique). Cf. zpool-encryption-architecture.adoc § « Accès SSH ».
if [ -n "$SYSTEM_DATASETS_SCRIPT" ]; then
  echo "[rescue-run-vm] SSH : root CLÉ-SEULE (porte de secours fail-safe, /home chiffré)"
  # Garde anti-brick : en Option I, root est la SEULE porte avant unlock. Sans
  # clé root, le serveur serait inaccessible au reboot → on échoue l'install.
  if [ -z "$ROOT_KEYS_B64" ]; then
    echo "ERREUR [rescue-run-vm] : profil Option I mais AUCUNE clé root → abandon (serveur sinon verrouillé)." >&2
    exit 1
  fi
  PERMIT_ROOT="prohibit-password"
  ssh_vm "mkdir -p /mnt/root/.ssh && \
    printf '%s' '$ROOT_KEYS_B64' | base64 -d > /mnt/root/.ssh/authorized_keys && \
    chmod 700 /mnt/root/.ssh && chmod 600 /mnt/root/.ssh/authorized_keys"
else
  echo "[rescue-run-vm] SSH : ROOT COUPÉ d'emblée (accès uniquement par user + sudo)"
  PERMIT_ROOT="no"
fi
ssh_vm "mkdir -p /mnt/etc/ssh/sshd_config.d
cat > /mnt/etc/ssh/sshd_config.d/10-beryl-bootstrap.conf <<SSHD
PermitRootLogin $PERMIT_ROOT
PasswordAuthentication no
ChallengeResponseAuthentication no
SSHD"
# FreeBSD n'inclut PAS sshd_config.d/*.conf par défaut → on pose l'Include EN
# TÊTE pour que le drop-in ci-dessus (et ceux de `beryl apply`) priment.
ssh_vm "grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /mnt/etc/ssh/sshd_config 2>/dev/null || { \
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > /mnt/etc/ssh/sshd_config.new; \
  cat /mnt/etc/ssh/sshd_config >> /mnt/etc/ssh/sshd_config.new 2>/dev/null; \
  mv /mnt/etc/ssh/sshd_config.new /mnt/etc/ssh/sshd_config; }"

# ----------------------------------------------------------------------
# Étape 5b — création des pools ZFS data (mappés vtbd* dans la VM,
# retrouvés automatiquement par ZFS au reboot via zpool.cache).
# ----------------------------------------------------------------------
# Le script ci-dessous est généré par beryl à partir des pools
# `freebsd.zfs.<nom>` où `boot: true` est absent. Chaque `zpool create`
# utilise `-R /mnt` (altroot) et `-m <mountpoint>` pour que la config
# soit correcte au reboot bare-metal (ZFS écrit /mnt/boot/zfs/zpool.cache).

if [ -n "$DATA_POOLS_SCRIPT" ]; then
  echo "[rescue-run-vm] création des pools ZFS data"
  ssh_vm_long "$(echo "$DATA_POOLS_SCRIPT" | base64 -d)"
fi

# ----------------------------------------------------------------------
# Étape 6 — unmount ZFS + poweroff
# ----------------------------------------------------------------------

echo "[rescue-run-vm] unmount ZFS + poweroff VM"
ssh_vm "cd / && zfs unmount -a 2>/dev/null ; zpool export -a 2>/dev/null ; sync ; poweroff" || true

echo "[rescue-run-vm] attente fin QEMU (timeout ${QEMU_MAX_SEC}s)"
start=$(date +%s)
while systemctl is-active --quiet qemu-vm.service; do
  if [ $(($(date +%s) - start)) -ge "$QEMU_MAX_SEC" ]; then
    echo "[rescue-run-vm] TIMEOUT QEMU, kill service" >&2
    systemctl stop qemu-vm.service 2>/dev/null || true
    exit 2
  fi
  sleep 5
done

echo "[rescue-run-vm] QEMU terminé proprement, install FreeBSD écrite sur le disque."
exit 0
