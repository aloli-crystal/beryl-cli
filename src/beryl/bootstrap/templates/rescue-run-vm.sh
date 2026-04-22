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

if systemctl is-active --quiet qemu-vm.service; then
  echo "[rescue-run-vm] QEMU déjà actif (systemd service qemu-vm), réutilise"
else
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
fi

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
# Étape 2 — pré-fetch MANIFEST + base.txz + kernel.txz dans la VM
# ----------------------------------------------------------------------
# Évite le dialog « Mirror Selection » de bsdinstall et garantit les
# bons checksums.

echo "[rescue-run-vm] pré-fetch MANIFEST + txz dans la VM"
ssh_vm_long "mkdir -p /usr/freebsd-dist && cd /usr/freebsd-dist && \
  test -s MANIFEST   || fetch -q -o MANIFEST   $DISTSITE/MANIFEST && \
  test -s base.txz   || fetch -q -o base.txz   $DISTSITE/base.txz && \
  test -s kernel.txz || fetch -q -o kernel.txz $DISTSITE/kernel.txz && \
  ls -la"

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
  # Clés SSH
  if [ -n "$UKEYS" ]; then
    ssh_vm "mkdir -p /mnt/home/$UNAME/.ssh"
    echo "$UKEYS" | tr ',' '\n' | while read -r K; do
      [ -z "$K" ] && continue
      ssh_vm "echo '$K' >> /mnt/home/$UNAME/.ssh/authorized_keys"
    done
    UID_NEW=$(ssh_vm "pw -R /mnt usershow $UNAME" | cut -d: -f3)
    GID_PG=$(ssh_vm "pw -R /mnt groupshow $PGROUP" | cut -d: -f3)
    ssh_vm "chown -R $UID_NEW:$GID_PG /mnt/home/$UNAME/.ssh && \
            chmod 700 /mnt/home/$UNAME/.ssh && \
            chmod 600 /mnt/home/$UNAME/.ssh/authorized_keys"
  fi
done

if [ -n "$PACKAGES" ]; then
  echo "[rescue-run-vm] pkg -r /mnt install (hors chroot → pas de Capsicum)"
  ssh_vm_long "env ABI=$ABI IGNORE_OSVERSION=yes pkg -r /mnt install -y $PACKAGES"
fi

if [ -n "$SUDOERS_CONTENT" ]; then
  echo "[rescue-run-vm] sudoers.d/beryl"
  ssh_vm "mkdir -p /mnt/usr/local/etc/sudoers.d && \
    echo '$SUDOERS_CONTENT' | base64 -d > /mnt/usr/local/etc/sudoers.d/beryl && \
    chmod 440 /mnt/usr/local/etc/sudoers.d/beryl"
fi

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
