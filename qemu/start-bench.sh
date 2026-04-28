#!/usr/bin/env bash
# Démarre le banc QEMU complet pour les tests d'intégration beryl.
#
# Wrapper qui enchaîne les 7 scripts du shard `crystal-clevis-zfs`
# (vit dans `prod-crystal/qemu/`, sera absorbé par le shard) :
#
#   00-fetch-image.sh           télécharge l'image FreeBSD aarch64 (~10 min 1ʳᵉ fois)
#   01-prepare-disks.sh         clone l'image + génère les seeds cloud-init
#   10-run-tang.sh              boot la VM tang en arrière-plan
#   11-run-client.sh            boot la VM client en arrière-plan
#   20-provision-tang.sh        installe tang + lance les 3 tangd
#   21-provision-client.sh      installe crystal + clone shard + build binaire
#   22-promote-root-on-client.sh   active root SSH sur la VM client (pour beryl)
#
# Idempotent : chaque script du shard est lui-même idempotent. On peut
# relancer en boucle sans dommage. Si une étape échoue, le script
# s'arrête et affiche le code de retour.
#
# Usage :
#   ./start-bench.sh           # enchaîne tout
#   ./start-bench.sh --skip-fetch   # saute 00 (utile si l'image est déjà là)
#
# Pour stopper : ./stop-bench.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

BENCH_DIR="${HOME}/prod-crystal/qemu"

if [ ! -d "${BENCH_DIR}" ]; then
  ko "banc QEMU shard absent : ${BENCH_DIR}"
  printf '%s\n' \
    "Le banc vit dans le shard \`crystal-clevis-zfs\`. À ce jour il" \
    "n'est pas encore packagé dans le repo du shard et survit dans" \
    "${BENCH_DIR}. Vérifiez auprès de Philippe qu'il y est bien." >&2
  exit 1
fi

SKIP_FETCH=false
for arg in "$@"; do
  case "$arg" in
    --skip-fetch) SKIP_FETCH=true ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed -n '/^# /s/^# \?//p'
      exit 0 ;;
    *) ko "argument inconnu : $arg"; exit 1 ;;
  esac
done

cd "${BENCH_DIR}"

run_step() {
  local step="$1"
  log "→ ${step}"
  if ! ./"${step}"; then
    ko "étape ${step} a échoué (code $?)"
    exit 1
  fi
}

if [ "$SKIP_FETCH" = false ]; then
  run_step "00-fetch-image.sh"
else
  log "→ 00-fetch-image.sh (sauté via --skip-fetch)"
fi
run_step "01-prepare-disks.sh"
run_step "10-run-tang.sh"
run_step "11-run-client.sh"
run_step "20-provision-tang.sh"
run_step "21-provision-client.sh"
run_step "22-promote-root-on-client.sh"

ok "banc QEMU démarré et provisionné"
log "vous pouvez maintenant lancer : ${SCRIPT_DIR}/test-beryl.sh"
