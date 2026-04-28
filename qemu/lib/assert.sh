# shellcheck shell=bash
# Assertions et helpers communs pour les tests d'intégration beryl
# qui consomment le banc QEMU de `crystal-clevis-zfs` (vit dans
# `prod-crystal/qemu/`, sera absorbé par le shard).
#
# Convention de retour :
#   - 0  = test OK
#   - 1+ = test KO (le caller décide d'arrêter ou pas)
#
# Tous les helpers logguent sur STDERR. Les résultats utiles
# (chaînes à capturer) sortent sur STDOUT.

set -euo pipefail

# Couleurs ANSI (désactivées si stdout n'est pas un TTY).
if [ -t 2 ]; then
  C_GREEN=$'\033[1;32m'
  C_RED=$'\033[1;31m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_BLUE=""
  C_RESET=""
fi

log() {
  printf '%s[test-beryl]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2
}

ok() {
  printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2
}

ko() {
  printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  return 1
}

warn() {
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

# Vérifie qu'un port TCP est ouvert sur l'hôte local.
assert_tcp_open() {
  local port="$1"
  local label="${2:-tcp:$port}"
  if nc -z -G 2 127.0.0.1 "$port" 2>/dev/null; then
    ok "$label répond sur 127.0.0.1:$port"
  else
    ko "$label NE répond PAS sur 127.0.0.1:$port"
  fi
}

# Vérifie qu'une chaîne attendue est dans la sortie d'une commande.
# `$1` = description, `$2` = chaîne attendue, `$@` (à partir de 3) = commande.
assert_contains() {
  local desc="$1"
  local needle="$2"
  shift 2
  local out
  if ! out="$("$@" 2>&1)"; then
    ko "$desc — la commande a échoué"
    printf '%s\n' "$out" >&2
    return 1
  fi
  if printf '%s' "$out" | grep -F -q -- "$needle"; then
    ok "$desc"
  else
    ko "$desc — chaîne attendue absente : « $needle »"
    printf '%s\n' "$out" >&2
    return 1
  fi
}

# Vérifie qu'une chaîne *n'est pas* présente dans la sortie d'une commande.
assert_not_contains() {
  local desc="$1"
  local needle="$2"
  shift 2
  local out
  if ! out="$("$@" 2>&1)"; then
    ko "$desc — la commande a échoué"
    printf '%s\n' "$out" >&2
    return 1
  fi
  if printf '%s' "$out" | grep -F -q -- "$needle"; then
    ko "$desc — chaîne inattendue présente : « $needle »"
    printf '%s\n' "$out" >&2
    return 1
  else
    ok "$desc"
  fi
}

# Exécute une commande SSH sur la VM client (root@127.0.0.1:2223).
# Le banc QEMU shard expose la VM client sur ce port, et le script
# `22-promote-root-on-client.sh` y a posé root SSH.
ssh_client() {
  ssh \
    -i "${BENCH_SSH_KEY}" \
    -p 2223 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=5 \
    root@127.0.0.1 \
    "$@"
}

# Exécute une commande SSH sur la VM tang (freebsd@127.0.0.1:2222 + sudo).
ssh_tang() {
  ssh \
    -i "${BENCH_SSH_KEY}" \
    -p 2222 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=5 \
    freebsd@127.0.0.1 \
    "$@"
}

# Exécute beryl avec le config_root du test. `BERYL_TEST_ROOT` doit
# être défini par le caller. Capture stdout+stderr, retourne le code.
run_beryl() {
  ( cd "${BERYL_REPO}" && crystal run src/beryl/cli.cr -- -c "${BERYL_TEST_ROOT}" "$@" 2>&1 )
}
