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
BOOT_MODE=$(yq -r '.boot_mode' "$CONFIG")
# Seed cloud-init optionnel (généré par `beryl bake-seed`). Attaché en 2ᵉ cdrom.
SEED_ISO_RAW=$(yq -r '.seed_iso // ""' "$CONFIG")
SEED_ISO=""
if [ -n "$SEED_ISO_RAW" ] && [ "$SEED_ISO_RAW" != "null" ]; then
  SEED_ISO=$(expand_home "$SEED_ISO_RAW")
fi

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

# Localise le firmware UEFI (edk2) fourni par Homebrew/QEMU.
# QEMU récent exige le chargement via `-drive if=pflash` (pas `-bios`) pour
# le format split code + vars. Les "vars" persistent les paramètres NVRAM
# de chaque VM : on en fait une copie propre par VM au premier lancement.
firmware_args=""
if [ "$FIRMWARE" = "uefi" ]; then
  CODE=""
  VARS_TEMPLATE=""
  for prefix in "/opt/homebrew/share/qemu" "/usr/local/share/qemu"; do
    case "$ARCH" in
      x86_64|x86-64|amd64)
        [ -f "$prefix/edk2-x86_64-code.fd" ] && CODE="$prefix/edk2-x86_64-code.fd"
        [ -f "$prefix/edk2-i386-vars.fd" ] && VARS_TEMPLATE="$prefix/edk2-i386-vars.fd"
        ;;
      aarch64|arm64)
        [ -f "$prefix/edk2-aarch64-code.fd" ] && CODE="$prefix/edk2-aarch64-code.fd"
        [ -f "$prefix/edk2-arm-vars.fd" ] && VARS_TEMPLATE="$prefix/edk2-arm-vars.fd"
        ;;
    esac
    [ -n "$CODE" ] && break
  done
  [ -n "$CODE" ] && [ -n "$VARS_TEMPLATE" ] || {
    echo "erreur : firmware UEFI edk2 introuvable pour $ARCH" >&2
    exit 1
  }

  VARS="$(dirname "$DISK_IMAGE")/${NAME}-vars.fd"
  if [ ! -f "$VARS" ]; then
    mkdir -p "$(dirname "$VARS")"
    cp "$VARS_TEMPLATE" "$VARS"
    echo "==> copie du template NVRAM UEFI : $VARS"
  fi

  firmware_args="-drive if=pflash,format=raw,unit=0,readonly=on,file=$CODE \
                 -drive if=pflash,format=raw,unit=1,file=$VARS"
fi

# Display flag
case "$DISPLAY" in
  gui)    display_args="-display cocoa" ;;
  none)   display_args="-display none" ;;
  serial) display_args="-display none -serial stdio -monitor none" ;;
  *)      display_args="-display cocoa" ;;
esac

# Boot mode — gère le piège classique où un reboot reboucle sur le cdrom.
#   cdrom-once : cdrom au 1ᵉʳ boot de la session QEMU puis disque pour tous
#                les reboots suivants (recommandé pour installer un OS).
#   cdrom      : toujours booter le cdrom (live/rescue).
#   disk       : toujours booter le disque (OS déjà installé).
case "$BOOT_MODE" in
  cdrom-once|"") boot_args="-boot once=d,order=c,menu=off" ;;
  cdrom)         boot_args="-boot order=d,menu=off" ;;
  disk)          boot_args="-boot order=c,menu=off" ;;
  *)             echo "erreur : boot_mode inconnu : $BOOT_MODE" >&2; exit 1 ;;
esac

echo "==> démarrage de la VM $NAME ($ARCH, ${RAM} Mo, ${CPUS} vCPU)"
echo "==> SSH : ssh -p $SSH_PORT root@localhost"
echo "==> arrêt : fermer la fenêtre QEMU ou Ctrl+A X (si serial)"
echo

seed_args=""
if [ -n "$SEED_ISO" ]; then
  if [ ! -f "$SEED_ISO" ]; then
    echo "erreur : seed_iso introuvable : $SEED_ISO" >&2
    echo "         (générez-le avec : beryl bake-seed --output \"$SEED_ISO\")" >&2
    exit 1
  fi
  seed_args="-drive file=$SEED_ISO,media=cdrom,readonly=on,if=virtio"
  echo "==> seed cloud-init attaché : $SEED_ISO"
fi

exec "$QEMU_BIN" \
  -name "$NAME" \
  -m "$RAM" \
  -smp "$CPUS" \
  $firmware_args \
  -drive "file=$DISK_IMAGE,format=$DISK_FORMAT,if=virtio" \
  -cdrom "$ISO" \
  $seed_args \
  $boot_args \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
  -device "virtio-net-pci,netdev=net0" \
  $display_args
