#!/bin/bash
# Script "au réveil" : installe FreeBSD 15 sur loulou.aloli.net via beryl.
#
# Pré-requis :
#   - ns3156789.ip-51-83-6.eu est EN RESCUE (via beryl rescue fait hier)
#   - ~/.beryl/.env.yml contient les credentials OVH AVEC le droit
#     PUT /services/* (consumer key régénérée dans la nuit par Philippe)
#   - Disque unique détecté : /dev/sda (INTEL SSDSA2CW120G3 ~120 Go)
#
# Flux (minutes indicatives) :
#   1. scan --dns --write : DNS A + AAAA, reverses, rename OVH,       ~2 min
#      écriture ~/.beryl/aloli.net/loulou.yml avec RAID 0 sur sda
#   2. bootstrap loulou   : mfsBSD-in-QEMU + bsdinstall no-chroot,    ~25 min
#      reboot sur disque, attente SSH admin
#
# Logs horodatés dans /tmp/beryl-YYYYMMDD-HHMMSS.log
# Ctrl+C = arrêt propre (pas de rollback, beryl est idempotent).

set -euo pipefail

BERYL="/Users/philippe/prod-crystal/beryl/bin/beryl"
HOST="ns3156789.ip-51-83-6.eu"
DOMAIN="aloli.net"
SHORT="loulou"
LOG="/tmp/beryl-$(date +%Y%m%d-%H%M%S).log"

echo "[$(date +%H:%M:%S)] Début — logs dans $LOG" | tee -a "$LOG"

echo "[$(date +%H:%M:%S)] === Étape 1/2 : scan --dns --write ===" | tee -a "$LOG"
"$BERYL" scan "$HOST" \
  --domain="$DOMAIN" \
  --dns \
  --write \
  --hostname="$SHORT" \
  --disks=sda \
  --raid=0 \
  --non-interactive 2>&1 | tee -a "$LOG"

echo "[$(date +%H:%M:%S)] === Étape 2/2 : bootstrap $SHORT.$DOMAIN ===" | tee -a "$LOG"
"$BERYL" bootstrap "$SHORT.$DOMAIN" 2>&1 | tee -a "$LOG"

echo "[$(date +%H:%M:%S)] Terminé. Vérifiez : ssh admin@$SHORT.$DOMAIN" | tee -a "$LOG"
