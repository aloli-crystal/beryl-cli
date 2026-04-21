#!/bin/bash
# Prototype manuel du bootstrap "no chroot" — pilotage mfsBSD depuis le rescue
# pour poser FreeBSD sur /dev/sda sans jamais entrer dans le chroot bsdinstall
# (contourne le bug Capsicum observé sur loulou le 21 avril 2026).
#
# À dérouler section par section après un `beryl rescue` + `beryl wipe`.
# Ce script est la référence de validation MANUELLE avant de refondre le
# driver shell `rescue-run-vm.sh` autour du même flux.
#
# Pré-requis : hôte en rescue Linux OVH, /dev/sda wipé.
#
# Structure :
#   SECTION A — démarre mfsBSD dans QEMU UEFI
#   SECTION B — test SSH VM
#   SECTION C — bsdinstall PRÉAMBULE-SEUL (pas de post-install chroot)
#   SECTION D — post-install piloté depuis mfsBSD, ciblant /mnt explicitement
#   SECTION E — poweroff + reboot bare metal
#
# Chaque section est idempotente et testable isolément.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# SECTION A — démarre mfsBSD dans QEMU UEFI
# ─────────────────────────────────────────────────────────────────────────
# Ordre critique : apt install AVANT cp OVMF (sinon OVMF_VARS_4M.fd n'existe
# pas). `setsid + </dev/null` détache QEMU du tty ssh, sinon Process.run
# côté client bloque.

section_a_start_qemu() {
  mkdir -p /root/manual && cd /root/manual

  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    qemu-system-x86 ovmf sshpass curl 2>&1 | tail -1

  test -s mfsbsd-se.img || \
    curl -fLo mfsbsd-se.img https://mfsbsd.vx.sk/files/images/14/amd64/mfsbsd-se-14.2-RELEASE-amd64.img

  cp -f /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd

  pkill -9 -f qemu-system 2>/dev/null || true; sleep 2
  : > serial.log

  setsid timeout 7200 qemu-system-x86_64 -enable-kvm -machine q35 -cpu host \
    -smp 4 -m 4096M \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=vars.fd \
    -drive file=mfsbsd-se.img,format=raw,if=virtio \
    -drive file=/dev/sda,format=raw,if=virtio,cache=none \
    -netdev user,id=net0,hostfwd=tcp::2223-:22 \
    -device virtio-net-pci,netdev=net0 \
    -nographic -serial file:serial.log -no-reboot \
    </dev/null >/dev/null 2>&1 &
  disown
  echo "QEMU lancé, PID $!"
}

# ─────────────────────────────────────────────────────────────────────────
# SECTION B — test SSH VM
# ─────────────────────────────────────────────────────────────────────────
# Retourne "FreeBSD" quand mfsBSD est prêt. Laisse ~60 s après section A.

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=keyboard-interactive \
  -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
  -o ConnectTimeout=5"

ssh_vm() {
  # shellcheck disable=SC2086
  timeout 10 sshpass -p mfsroot ssh $SSH_OPTS -p 2223 root@127.0.0.1 "$@"
}

ssh_vm_long() {
  # shellcheck disable=SC2086
  timeout 900 sshpass -p mfsroot ssh $SSH_OPTS -p 2223 root@127.0.0.1 "$@"
}

scp_to_vm() {
  # shellcheck disable=SC2086
  timeout 60 sshpass -p mfsroot scp $SSH_OPTS -P 2223 "$1" "root@127.0.0.1:$2"
}

section_b_test_vm() {
  ssh_vm 'uname -a'
}

# ─────────────────────────────────────────────────────────────────────────
# SECTION C — bsdinstall préambule-seul
# ─────────────────────────────────────────────────────────────────────────
# installerconfig minimaliste : juste ce qu'il faut pour que bsdinstall
# partitionne, crée le ZFS, extract base.txz + kernel.txz dans /mnt.
# PAS de second #!/bin/sh → pas de post-install chroot → pas de Capsicum.

section_c_bsdinstall_preamble() {
  # Pré-fetch MANIFEST + txz côté VM (évite le dialog Mirror Selection)
  ssh_vm_long "mkdir -p /usr/freebsd-dist && \
    fetch -q -o /usr/freebsd-dist/MANIFEST http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/15.0-RELEASE/MANIFEST && \
    fetch -q -o /usr/freebsd-dist/base.txz http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/15.0-RELEASE/base.txz && \
    fetch -q -o /usr/freebsd-dist/kernel.txz http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/15.0-RELEASE/kernel.txz"

  cat > /root/manual/installerconfig <<'CFG'
export ZFSBOOT_DISKS="vtbd1"
export ZFSBOOT_VDEV_TYPE="stripe"
export ZFSBOOT_SWAP_SIZE="4g"
export ZFSBOOT_POOL_NAME="zroot"
export nonInteractive="YES"
DISTRIBUTIONS="kernel.txz base.txz"
CFG

  scp_to_vm /root/manual/installerconfig /tmp/installerconfig
  ssh_vm_long "BSDINSTALL_DISTSITE=http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/15.0-RELEASE bsdinstall script /tmp/installerconfig"
  # Après bsdinstall : /mnt contient le rootfs FreeBSD extrait,
  # les datasets ZFS sont montés sur /mnt/*, mais pas de post-install
  # (pas de user, pas de rc.conf customisé).
}

# ─────────────────────────────────────────────────────────────────────────
# SECTION D — post-install piloté depuis mfsBSD (hors chroot)
# ─────────────────────────────────────────────────────────────────────────
# Chaque commande cible /mnt explicitement. `pkg -r /mnt` installe sans
# chroot ⇒ pas de Capsicum. `pw -V /mnt/etc` idem pour useradd.
#
# TEMPLATE : remplir selon le YAML utilisateur (users, packages, sudoers).
# Ici ci-dessous, on montre un exemple conforme aux conventions Aloli —
# à NE PAS embarquer comme défaut dans beryl (cf. feedback_no_silent_defaults).

section_d_post_install() {
  local HOSTNAME="${1:-loulou.aloli.net}"
  local TZ="${2:-Europe/Paris}"
  local USER_PUB_KEY="${3:?usage: section_d_post_install HOSTNAME TZ SSH_PUB_KEY}"

  # hostname, rc.conf, fstab, timezone
  ssh_vm "cat > /mnt/etc/rc.conf <<RC
hostname=\"$HOSTNAME\"
ifconfig_DEFAULT=\"DHCP\"
sshd_enable=\"YES\"
zfs_enable=\"YES\"
RC"

  ssh_vm "cat > /mnt/etc/fstab <<FSTAB
/dev/gpt/efiboot0   /boot/efi  msdosfs  rw,late   2  2
/dev/gpt/swap0      none       swap     sw        0  0
FSTAB"

  ssh_vm "cp /mnt/usr/share/zoneinfo/$TZ /mnt/etc/localtime"

  # User admin (exemple — devrait venir du YAML)
  ssh_vm "pw -V /mnt/etc useradd -n admin -d /home/admin -g www -G wheel -m -s /bin/csh"
  ssh_vm "mkdir -p /mnt/home/admin/.ssh && \
    echo '$USER_PUB_KEY' > /mnt/home/admin/.ssh/authorized_keys && \
    chown -R 1001:80 /mnt/home/admin/.ssh && \
    chmod 700 /mnt/home/admin/.ssh && \
    chmod 600 /mnt/home/admin/.ssh/authorized_keys"

  # Packages via pkg -r (NO chroot, donc NO Capsicum)
  ssh_vm_long "env ABI=FreeBSD:15:amd64 pkg -r /mnt install -y sudo zsh chruby ruby-install"

  # Sudoers
  ssh_vm "mkdir -p /mnt/usr/local/etc/sudoers.d && \
    echo '%wheel ALL=(ALL) NOPASSWD:ALL' > /mnt/usr/local/etc/sudoers.d/wheel && \
    chmod 440 /mnt/usr/local/etc/sudoers.d/wheel"
}

# ─────────────────────────────────────────────────────────────────────────
# SECTION E — poweroff VM + reboot bare metal
# ─────────────────────────────────────────────────────────────────────────

section_e_poweroff() {
  ssh_vm "sync; poweroff" || true
  # Attend que QEMU sorte
  while pgrep -f 'qemu-system-x86_64.*mfsbsd-se.img' >/dev/null; do sleep 5; done
  echo "QEMU terminé, disque /dev/sda prêt."
  echo "Ensuite : beryl boot-hd loulou.aloli.net depuis le laptop."
}

# ─────────────────────────────────────────────────────────────────────────
# Usage interactif : décommentez la section à jouer, sourcez ce fichier.
# ─────────────────────────────────────────────────────────────────────────

# section_a_start_qemu
# sleep 60
# section_b_test_vm
# section_c_bsdinstall_preamble
# section_d_post_install loulou.aloli.net Europe/Paris "ssh-ed25519 AAAA… philippe@aloli"
# section_e_poweroff

echo "Ce script est prévu pour être SOURCÉ section par section, pas exécuté d'un coup."
echo "Voir les commentaires au bas du fichier."
