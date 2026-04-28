#!/usr/bin/env bash
# Arrête le banc QEMU complet (VMs tang + client).
#
# Wrapper qui appelle `99-stop-all.sh` du shard. Préserve les
# disques qcow2 dans `prod-crystal/qemu/run/` — un futur
# `start-bench.sh` redémarre les VMs sans re-provisionner.
#
# Usage :
#   ./stop-bench.sh            # stoppe les 2 VMs proprement
#   ./stop-bench.sh --wipe     # stoppe + supprime run/*.qcow2 et run/*.iso
#                              # (le prochain start-bench refait l'install à zéro)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/assert.sh
source "${SCRIPT_DIR}/lib/assert.sh"

BENCH_DIR="${HOME}/prod-crystal/qemu"

if [ ! -d "${BENCH_DIR}" ]; then
  ko "banc QEMU shard absent : ${BENCH_DIR}"
  exit 1
fi

WIPE=false
for arg in "$@"; do
  case "$arg" in
    --wipe) WIPE=true ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed -n '/^# /s/^# \?//p'
      exit 0 ;;
    *) ko "argument inconnu : $arg"; exit 1 ;;
  esac
done

cd "${BENCH_DIR}"

log "→ 99-stop-all.sh"
if ! ./99-stop-all.sh; then
  ko "99-stop-all.sh a échoué (code $?)"
  exit 1
fi
ok "VMs arrêtées"

if [ "$WIPE" = true ]; then
  log "→ wipe : suppression de run/*.qcow2 et run/*.iso"
  rm -f "${BENCH_DIR}"/run/*.qcow2 "${BENCH_DIR}"/run/*.iso
  ok "disques supprimés (le prochain start-bench refait tout à zéro)"
fi
