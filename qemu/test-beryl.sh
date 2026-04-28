#!/usr/bin/env bash
# Test d'intégration beryl ↔ crystal-clevis-zfs sur le banc QEMU.
#
# Pré-requis : le banc QEMU `prod-crystal/qemu/` est démarré et
# provisionné. Concrètement :
#
#     cd ~/prod-crystal/qemu
#     ./00-fetch-image.sh
#     ./01-prepare-disks.sh
#     ./10-run-tang.sh
#     ./11-run-client.sh
#     ./20-provision-tang.sh
#     ./21-provision-client.sh
#     ./22-promote-root-on-client.sh
#
# Ce script :
#   1. Vérifie que les VMs et Tangs répondent.
#   2. Crée un environnement beryl éphémère dans /tmp/beryl-test-qemu-XXXX/.
#   3. Génère une clé locale et crée un pool ZFS chiffré sur la VM client.
#   4. Lance les 5 tests :
#      T1 — beryl unlock mode ssh_unlock
#      T2 — beryl tang-enroll single-Tang + unlock mode tang
#      T3 — beryl tang-enroll SSS (3 Tangs threshold 2) + unlock
#      T4 — robustesse 1 panne sur 3 (kill Tang #2, unlock OK)
#      T5 — Tang #2 ressuscité (cleanup pour ré-exécutions)
#   5. Détruit le pool de test sur la VM (sauf si --keep).
#   6. Affiche un bilan OK/FAIL.
#
# Idempotent : on peut relancer en boucle. Chaque exécution crée son
# propre dossier temporaire ; le pool VM est nettoyé en début et fin.
#
# Usage :
#   ./test-beryl.sh           # exécute, nettoie à la fin
#   ./test-beryl.sh --keep    # garde le dossier temp + le pool VM (debug)
#   ./test-beryl.sh --no-cleanup-vm  # nettoie le dossier temp mais pas la VM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

# Localisation : le banc QEMU et la clé SSH du banc.
BENCH_DIR="${HOME}/prod-crystal/qemu"
BENCH_SSH_KEY="${BENCH_DIR}/ssh/id_ed25519"
BENCH_PUB_KEY="${BENCH_DIR}/ssh/id_ed25519.pub"
BERYL_REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Nom du pool ZFS de test sur la VM. Volontairement distinct du
# `testpool` que le banc shard utilise pour son propre test 30, pour
# éviter les interférences si quelqu'un lance les deux en parallèle.
POOL_NAME="bdata"
POOL_MOUNTPOINT="/save"
MD_UNIT="10"
POOL_FILE="/var/zpool-${POOL_NAME}.img"
POOL_SIZE="1G"

# URLs Tang vues depuis la VM client (10.0.2.2 = passerelle QEMU NAT).
TANG_URL_1="http://10.0.2.2:8888"
TANG_URL_2="http://10.0.2.2:8889"
TANG_URL_3="http://10.0.2.2:8890"

# Args de ligne de commande.
KEEP_TEMP=false
CLEANUP_VM=true
for arg in "$@"; do
  case "$arg" in
    --keep)         KEEP_TEMP=true; CLEANUP_VM=false ;;
    --no-cleanup-vm) CLEANUP_VM=false ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed -n '/^# /s/^# \?//p'
      exit 0 ;;
    *) ko "argument inconnu : $arg"; exit 1 ;;
  esac
done

# Dossier temporaire par exécution.
BERYL_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/beryl-test-qemu-XXXXXX")"
log "environnement temporaire : ${BERYL_TEST_ROOT}"

# Cleanup de fin : appelé via trap.
on_exit() {
  local rc=$?
  if [ "$KEEP_TEMP" = true ]; then
    log "--keep : conservation de ${BERYL_TEST_ROOT}"
  else
    rm -rf "${BERYL_TEST_ROOT}"
  fi
  if [ "$CLEANUP_VM" = true ]; then
    log "cleanup VM : destruction du pool ${POOL_NAME} et purge rc.conf"
    cleanup_vm || warn "cleanup VM partiel — vérifiez à la main"
  fi
  if [ "$rc" -eq 0 ]; then
    ok "test-beryl.sh : tous les tests sont passés"
  else
    ko "test-beryl.sh : échec (code $rc)"
  fi
  return $rc
}
trap on_exit EXIT

cleanup_vm() {
  ssh_client "zpool export ${POOL_NAME} 2>/dev/null || true"
  ssh_client "zpool destroy -f ${POOL_NAME} 2>/dev/null || true"
  ssh_client "mdconfig -d -u ${MD_UNIT} 2>/dev/null || true"
  ssh_client "rm -f ${POOL_FILE} /var/db/crystal-clevis-zfs/${POOL_NAME}.jwe"
  # Purge des entrées rc.conf qu'on a posées. `sysrc -x` retire
  # une variable. On ne touche pas aux datasets enrôlés par d'autres
  # tests (testpool/zsys, testpool/zdata).
  current="$(ssh_client "sysrc -n crystal_clevis_zfs_datasets 2>/dev/null || true")"
  filtered="$(printf '%s\n' "$current" | tr ' ' '\n' | grep -vx "${POOL_NAME}" | tr '\n' ' ' | sed 's/ *$//')"
  if [ -n "$filtered" ]; then
    ssh_client "sysrc crystal_clevis_zfs_datasets=\"${filtered}\" >/dev/null"
  else
    ssh_client "sysrc -x crystal_clevis_zfs_datasets >/dev/null 2>&1 || true"
    ssh_client "sysrc -x crystal_clevis_zfs_enable >/dev/null 2>&1 || true"
  fi
}

# ============================================================
# PHASE 0 — pré-flight banc QEMU
# ============================================================

log "phase 0 — pré-flight"

[ -r "${BENCH_SSH_KEY}" ] || { ko "clé SSH du banc absente : ${BENCH_SSH_KEY}"; exit 2; }
[ -r "${BENCH_PUB_KEY}" ] || { ko "clé publique du banc absente : ${BENCH_PUB_KEY}"; exit 2; }

assert_tcp_open 2222 "VM tang SSH"
assert_tcp_open 2223 "VM client SSH"
assert_tcp_open 8888 "Tang #1"
assert_tcp_open 8889 "Tang #2"
assert_tcp_open 8890 "Tang #3"

# Vérifie que root SSH fonctionne sur la VM client.
client_uname="$(ssh_client uname -s 2>/dev/null || true)"
if [ "$client_uname" = "FreeBSD" ]; then
  ok "root@VM client répond FreeBSD"
else
  ko "root@VM client ne répond pas en SSH (lancez 22-promote-root-on-client.sh côté banc)"
  exit 2
fi

# Vérifie que crystal-clevis-zfs est installé sur la VM client.
ccz_version="$(ssh_client /usr/local/sbin/crystal-clevis-zfs version 2>/dev/null || true)"
if printf '%s' "$ccz_version" | grep -q '^crystal-clevis-zfs '; then
  ok "binaire crystal-clevis-zfs installé : ${ccz_version}"
else
  ko "binaire /usr/local/sbin/crystal-clevis-zfs absent sur la VM (lancez 21-provision-client.sh)"
  exit 2
fi

# ============================================================
# PHASE 1 — environnement beryl éphémère
# ============================================================

log "phase 1 — création env beryl dans ${BERYL_TEST_ROOT}"

mkdir -p "${BERYL_TEST_ROOT}/qemu/test"

cat > "${BERYL_TEST_ROOT}/_default.yml" <<EOF
freebsd:
  timezone: Europe/Paris
EOF

# Domaine + injection de la clé publique du banc inline (contournement
# du résolveur SSH qui ne sait pas lire un chemin absolu — voir
# ssh_key_resolver.cr).
PUB_KEY_INLINE="$(cat "${BENCH_PUB_KEY}")"
cat > "${BERYL_TEST_ROOT}/qemu/test.yml" <<EOF
ssh_keys:
  - ${PUB_KEY_INLINE}
EOF

# Host clientvm (ssh_host: 127.0.0.1 explicite, validé par le fix
# 3b19dfb du 28 avril 2026).
cat > "${BERYL_TEST_ROOT}/qemu/test/clientvm.yml" <<EOF
provider: local
ssh_host: 127.0.0.1
port: 2223
user: root
identity_file: ${BENCH_SSH_KEY}
freebsd:
  hostname: clientvm
  users:
    - name: admin
      primary_group: wheel
      shell: /bin/sh
      ssh_keys: []
  zfs:
    ${POOL_NAME}:
      mountpoint: ${POOL_MOUNTPOINT}
      raid: 0
      disks: [/dev/md${MD_UNIT}]
      encryption: true
EOF

# Génération de la clé locale (le chemin canonique attendu par
# Beryl::Encryption.key_path).
openssl rand -hex 32 > "${BERYL_TEST_ROOT}/qemu/test/clientvm.key"
chmod 0400 "${BERYL_TEST_ROOT}/qemu/test/clientvm.key"
ok "clé locale générée (64 chars hex, chmod 0400)"

# Sanity check : `beryl show` parse correctement.
assert_contains "beryl show parse YAML host" "ssh_host:       127.0.0.1" \
  run_beryl show qemu/clientvm

# ============================================================
# PHASE 2 — préparation pool ZFS sur la VM
# ============================================================

log "phase 2 — création pool ZFS chiffré sur la VM client"

# Reset pool éventuellement laissé d'un run précédent.
cleanup_vm 2>/dev/null || true

ssh_client "truncate -s ${POOL_SIZE} ${POOL_FILE} && mdconfig -a -t vnode -f ${POOL_FILE} -u ${MD_UNIT} >/dev/null"

# Création du pool chiffré, clé poussée via stdin (jamais en argv).
cat "${BERYL_TEST_ROOT}/qemu/test/clientvm.key" | ssh_client \
  "zpool create -f -O encryption=on -O keyformat=hex -O keylocation=prompt -O compression=lz4 -m ${POOL_MOUNTPOINT} ${POOL_NAME} /dev/md${MD_UNIT}"

assert_contains "pool ${POOL_NAME} créé et chiffré" "encryption" \
  ssh_client "zfs get -H -o property,value encryption ${POOL_NAME}"

# Export du pool pour simuler un état post-reboot.
ssh_client "zpool export ${POOL_NAME}"

# ============================================================
# PHASE 3 — TESTS
# ============================================================

log "T1 — beryl unlock mode ssh_unlock"
assert_contains "T1 unlock ssh_unlock" "terminé (1 pool(s) en ligne)" \
  run_beryl unlock qemu/clientvm
assert_contains "T1 dataset monté" "available" \
  ssh_client "zfs get -H -o value keystatus ${POOL_NAME}"

log "T1bis — idempotence (re-unlock = no-op)"
assert_contains "T1bis idempotence" "déjà importé" \
  run_beryl unlock qemu/clientvm

log "T2 — bascule en mode tang single-Tang"
cat > "${BERYL_TEST_ROOT}/qemu/test/clientvm.yml" <<EOF
provider: local
ssh_host: 127.0.0.1
port: 2223
user: root
identity_file: ${BENCH_SSH_KEY}
freebsd:
  hostname: clientvm
  users:
    - name: admin
      primary_group: wheel
      shell: /bin/sh
      ssh_keys: []
  zfs:
    ${POOL_NAME}:
      mountpoint: ${POOL_MOUNTPOINT}
      raid: 0
      disks: [/dev/md${MD_UNIT}]
      encryption:
        mode: tang
        tang:
          urls:
            - ${TANG_URL_1}
        compression: lz4
EOF

assert_contains "T2 tang-enroll single-Tang" "1 pool(s) enrôlé(s)" \
  run_beryl tang-enroll qemu/clientvm

# Export + unlock pour vérifier le déchiffrement via Tang.
ssh_client "zpool export ${POOL_NAME}"
assert_contains "T2 unlock mode tang single" "mode tang : ${TANG_URL_1}" \
  run_beryl unlock qemu/clientvm

log "T3 — bascule en SSS multi-Tang (3 Tangs threshold 2)"
cat > "${BERYL_TEST_ROOT}/qemu/test/clientvm.yml" <<EOF
provider: local
ssh_host: 127.0.0.1
port: 2223
user: root
identity_file: ${BENCH_SSH_KEY}
freebsd:
  hostname: clientvm
  users:
    - name: admin
      primary_group: wheel
      shell: /bin/sh
      ssh_keys: []
  zfs:
    ${POOL_NAME}:
      mountpoint: ${POOL_MOUNTPOINT}
      raid: 0
      disks: [/dev/md${MD_UNIT}]
      encryption:
        mode: tang
        tang:
          urls:
            - ${TANG_URL_1}
            - ${TANG_URL_2}
            - ${TANG_URL_3}
          threshold: 2
        compression: lz4
EOF

assert_contains "T3 tang-enroll SSS k=2/n=3" "3 Tangs, threshold 2" \
  run_beryl tang-enroll qemu/clientvm

ssh_client "zpool export ${POOL_NAME}"
assert_contains "T3 unlock SSS" "3 Tangs, threshold 2" \
  run_beryl unlock qemu/clientvm

log "T4 — robustesse : kill Tang #2, unlock doit toujours marcher (k=2 sur n=3)"
ssh_tang "sudo pkill -f 'tangd -p 8889' 2>/dev/null || true"
ssh_client "zpool export ${POOL_NAME}"
assert_contains "T4 unlock avec 1 Tang mort" "terminé (1 pool(s) en ligne)" \
  run_beryl unlock qemu/clientvm

log "T5 — ressusciter Tang #2 (cleanup pour ré-exécutions futures)"
ssh_tang "sudo daemon -f -p /var/run/tangd2.pid -o /var/log/tang2.log /usr/local/libexec/tangd -p 8889 -l /var/db/tang2"
sleep 1
if curl -sf --max-time 5 http://127.0.0.1:8889/adv >/dev/null; then
  ok "Tang #2 ressuscité"
else
  warn "Tang #2 ne répond pas après daemon -f — à relancer manuellement"
fi

log "tous les tests d'intégration sont passés"
