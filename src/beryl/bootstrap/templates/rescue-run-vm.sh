#!/bin/bash
# Script de pilotage mfsBSD-in-QEMU, généré par beryl et déposé côté rescue.
#
# Appelé par UN SEUL exec ssh depuis beryl (laptop). Évite que Crystal
# Process.run (macOS) ait à gérer du nested ssh, qui déclenche des hangs
# silencieux sur Apple's ssh.
#
# Placeholders __XXX__ substitués par beryl avant upload. Le script fait :
#
# 0. Lance QEMU en arrière-plan (setsid, détaché du shell ssh).
# 1. Poll jusqu'à ce que mfsBSD SE réponde en ssh (timeout __VM_BOOT_SEC__).
# 2. SCP le fichier installerconfig vers la VM (/tmp/installerconfig).
# 3. Lance bsdinstall script en nohup dans la VM (log /tmp/bsdinstall.log).
# 4. Poll jusqu'à ce que QEMU sorte (poweroff de la VM au bout du script
#    installerconfig, QEMU termine via -no-reboot).
#
# Sortie 0 = OK, 1 = timeout boot mfsBSD, 2 = timeout attente QEMU.
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

# --- Étape 0 : lance QEMU (mfsBSD en UEFI, disque passthrough) ----------
# Si déjà lancé par un run précédent resté en vie, on réutilise.
if pgrep -f "$QEMU_PATTERN" >/dev/null; then
  echo "[rescue-run-vm] QEMU déjà actif, réutilise"
else
  : > "$QEMU_SERIAL"
  setsid timeout "$QEMU_MAX_SEC" __QEMU_COMMAND__ </dev/null >/dev/null 2>&1 &
  disown
  echo "[rescue-run-vm] QEMU lancé (PID $!)"
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o PreferredAuthentications=keyboard-interactive \
          -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
          -o ConnectTimeout=5"

# `ssh_vm` court : 10 s max. Pour les commandes distantes rapides
# (uname, test, launch bsdinstall en nohup &). NE PAS utiliser pour un
# fetch/download qui peut durer minutes.
ssh_vm() {
  # shellcheck disable=SC2086
  timeout 10 sshpass -p "$VM_PASSWORD" ssh $SSH_OPTS -p "$VM_PORT" "root@$VM_HOST" "$@"
}

# `ssh_vm_long` : pour les opérations longues (fetch txz ~200 Mo,
# install chroot). 15 min max, large de marge.
ssh_vm_long() {
  # shellcheck disable=SC2086
  timeout 900 sshpass -p "$VM_PASSWORD" ssh $SSH_OPTS -p "$VM_PORT" "root@$VM_HOST" "$@"
}

scp_to_vm() {
  # shellcheck disable=SC2086
  timeout 60 sshpass -p "$VM_PASSWORD" scp $SSH_OPTS -P "$VM_PORT" "$1" "root@$VM_HOST:$2"
}

echo "[rescue-run-vm] attente SSH mfsBSD (timeout ${VM_BOOT_SEC}s)..."
start=$(date +%s)
while true; do
  if ssh_vm 'uname -s' 2>/dev/null | grep -q '^FreeBSD$'; then
    echo "[rescue-run-vm] VM répond (après $(($(date +%s) - start))s)"
    break
  fi
  if [ $(($(date +%s) - start)) -ge "$VM_BOOT_SEC" ]; then
    echo "[rescue-run-vm] TIMEOUT boot mfsBSD" >&2
    exit 1
  fi
  sleep 5
done

echo "[rescue-run-vm] upload installerconfig ($INSTALLERCFG_PATH → VM /tmp/installerconfig)"
scp_to_vm "$INSTALLERCFG_PATH" "/tmp/installerconfig"

echo "[rescue-run-vm] pré-fetch MANIFEST + distributions dans la VM (~200 Mo, évite dialog Mirror Selection)"
ssh_vm_long "mkdir -p /usr/freebsd-dist && \
  fetch -q -o /usr/freebsd-dist/MANIFEST $DISTSITE/MANIFEST && \
  fetch -q -o /usr/freebsd-dist/base.txz $DISTSITE/base.txz && \
  fetch -q -o /usr/freebsd-dist/kernel.txz $DISTSITE/kernel.txz && \
  ls -la /usr/freebsd-dist/"

echo "[rescue-run-vm] lance bsdinstall dans la VM (log /tmp/bsdinstall.log)"
ssh_vm "BSDINSTALL_DISTSITE=$DISTSITE nohup bsdinstall script /tmp/installerconfig >/tmp/bsdinstall.log 2>&1 & disown ; sleep 1 ; echo started"

echo "[rescue-run-vm] attente poweroff de la VM (timeout ${QEMU_MAX_SEC}s)"
start=$(date +%s)
while pgrep -f "$QEMU_PATTERN" >/dev/null; do
  if [ $(($(date +%s) - start)) -ge "$QEMU_MAX_SEC" ]; then
    echo "[rescue-run-vm] TIMEOUT QEMU" >&2
    exit 2
  fi
  sleep 10
done

echo "[rescue-run-vm] QEMU terminé proprement, install FreeBSD écrite sur le disque"
exit 0
