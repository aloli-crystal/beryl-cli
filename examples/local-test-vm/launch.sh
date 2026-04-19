#!/bin/sh
# launch.sh — lance une VM QEMU à partir d'un fichier YAML.
#
# Usage : ./launch.sh <config.yml>
#
# Dépendances : qemu-system-<arch>, yq (installables via `brew install qemu yq`).
# Conçu pour macOS (Apple Silicon ou Intel). Portable à Linux moyennant l'install
# de QEMU (apt, pacman, etc.).

set -eu

CONFIG="${1:?usage: $0 <config.yml>}"

command -v yq >/dev/null 2>&1 || {
  echo "erreur : yq manquant — installez-le avec 'brew install yq'" >&2
  exit 1
}

# Résout les ~ dans les chemins (yq ne le fait pas).
expand_home() {
  case "$1" in
    "~"*) printf '%s' "${HOME}${1#\~}" ;;
    *)    printf '%s' "$1" ;;
  esac
}

NAME=$(yq -r '.name' "$CONFIG")
ARCH=$(yq -r '.arch' "$CONFIG")
RAM=$(yq -r '.resources.ram_mb' "$CONFIG")
CPUS=$(yq -r '.resources.cpus' "$CONFIG")
DISK_GB=$(yq -r '.resources.disk_gb' "$CONFIG")
ISO=$(expand_home "$(yq -r '.iso' "$CONFIG")")
FIRMWARE=$(yq -r '.firmware' "$CONFIG")
DISK_IMAGE=$(expand_home "$(yq -r '.disk.image' "$CONFIG")")
DISK_FORMAT=$(yq -r '.disk.format' "$CONFIG")
SSH_PORT=$(yq -r '.network.ssh_port_forward' "$CONFIG")
DISPLAY=$(yq -r '.display' "$CONFIG")
BOOT=$(yq -r '.boot_order' "$CONFIG")

QEMU_BIN="qemu-system-${ARCH}"
command -v "$QEMU_BIN" >/dev/null 2>&1 || {
  echo "erreur : $QEMU_BIN manquant — installez-le avec 'brew install qemu'" >&2
  exit 1
}

[ -f "$ISO" ] || { echo "erreur : ISO introuvable : $ISO" >&2; exit 1; }

# Crée le disque qcow2 à la demande.
if [ ! -f "$DISK_IMAGE" ]; then
  mkdir -p "$(dirname "$DISK_IMAGE")"
  echo "==> création du disque virtuel $DISK_IMAGE (${DISK_GB} Go, $DISK_FORMAT)"
  qemu-img create -f "$DISK_FORMAT" "$DISK_IMAGE" "${DISK_GB}G"
fi

# Localise le firmware UEFI fourni par QEMU sur macOS/Homebrew.
firmware_args=""
if [ "$FIRMWARE" = "uefi" ]; then
  # brew installe les firmwares dans share/qemu.
  OVMF=""
  for candidate in \
    "/opt/homebrew/share/qemu/edk2-x86_64-code.fd" \
    "/usr/local/share/qemu/edk2-x86_64-code.fd" \
    "/opt/homebrew/share/qemu/OVMF.fd" \
    "/usr/local/share/qemu/OVMF.fd"; do
    [ -f "$candidate" ] && OVMF="$candidate" && break
  done
  [ -n "$OVMF" ] || { echo "erreur : firmware UEFI introuvable (OVMF/edk2)" >&2; exit 1; }
  firmware_args="-bios $OVMF"
fi

# Display flag
case "$DISPLAY" in
  gui)    display_args="-display cocoa" ;;
  none)   display_args="-display none" ;;
  serial) display_args="-display none -serial stdio -monitor none" ;;
  *)      display_args="-display cocoa" ;;
esac

echo "==> démarrage de la VM $NAME ($ARCH, ${RAM} Mo, ${CPUS} vCPU)"
echo "==> SSH : ssh -p $SSH_PORT root@localhost"
echo "==> arrêt : fermer la fenêtre QEMU ou Ctrl+A X (si serial)"
echo

exec "$QEMU_BIN" \
  -name "$NAME" \
  -m "$RAM" \
  -smp "$CPUS" \
  $firmware_args \
  -drive "file=$DISK_IMAGE,format=$DISK_FORMAT,if=virtio" \
  -cdrom "$ISO" \
  -boot "order=$BOOT" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
  -device "virtio-net-pci,netdev=net0" \
  $display_args
