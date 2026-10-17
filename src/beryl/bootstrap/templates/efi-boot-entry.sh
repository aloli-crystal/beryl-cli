#!/bin/sh
# beryl bootstrap : entrée de démarrage UEFI « FreeBSD <disque> » pour chaque
# disque boot, posée depuis le rescue Linux APRÈS l'installation et AVANT le
# redémarrage. Sans elle, le firmware ne connaît le disque que s'il a lui-même
# créé une entrée « UEFI OS » (\EFI\BOOT\BOOTX64.EFI) — ce qu'une carte peut
# ne faire qu'au démarrage SUIVANT l'apparition de la partition EFI.
#
# Ordre de démarrage : les entrées réseau en tête (PXE…) RESTENT en tête —
# l'hébergeur (OVH) pilote rescue/disque par le démarrage réseau ; les
# entrées FreeBSD viennent juste après, puis le reste de l'ordre d'origine.
# Les anciennes entrées « FreeBSD <disque> » (bootstrap précédent) sont
# remplacées.
#
# Variables : DISKS (« /dev/nvme0n1 /dev/nvme1n1 »), DRY (1 = n'écrit rien,
# affiche l'ordre actuel et l'ordre prévu), EFIVARS (tests).
set -u
V="${EFIVARS:-/sys/firmware/efi/efivars}"
G=8be4df61-93ca-11d2-aa0d-00e098032b8c
DRY="${DRY:-0}"

if [ ! -d "$V" ]; then
  echo "démarrage BIOS (pas d'UEFI) : aucune entrée à poser"
  exit 0
fi

# BootOrder : 4 octets d'attributs, puis des numéros sur 16 bits.
order() {
  cat "$V/BootOrder-$G" 2>/dev/null | od -An -tx2 -j4 -v | tr -s ' \n' '  ' |
    sed 's/^ *//;s/ *$//' | tr 'abcdef' 'ABCDEF'
}

# Libellé d'une entrée : UTF-16 après 4 + 4 + 2 octets, jusqu'au premier octet
# non imprimable (début du chemin de périphérique).
label() {
  cat "$V/Boot$1-$G" 2>/dev/null | tail -c +11 | tr -d '\000' |
    tr -c '[:print:]' '\n' | head -n 1 | cut -c1-60
}

is_net() {
  case "$(label "$1")" in
    *PXE* | *IPv4* | *IPv6* | *IP4* | *IP6* | *Network* | *HTTP*) return 0 ;;
  esac
  return 1
}

is_ours() {
  case "$(label "$1")" in
    "FreeBSD "*) return 0 ;;
  esac
  return 1
}

show() {
  for n in $1; do
    printf '    %s  %s\n' "$n" "$(label "$n")"
  done
}

before=$(order)
kept=""
for n in $before; do
  is_ours "$n" || kept="$kept $n"
done
net=""
rest=""
in_net=1
for n in $kept; do
  if [ "$in_net" = 1 ] && is_net "$n"; then
    net="$net $n"
  else
    in_net=0
    rest="$rest $n"
  fi
done

if [ "$DRY" = 1 ]; then
  echo "  ordre actuel :"
  show "$before"
  echo "  ordre prévu :"
  show "$net"
  for d in $DISKS; do
    printf '    ----  FreeBSD %s (nouvelle entrée)\n' "${d##*/}"
  done
  show "$rest"
  exit 0
fi

command -v efibootmgr >/dev/null 2>&1 || {
  echo "efibootmgr absent du rescue : entrée non posée" >&2
  exit 1
}

# Anciennes entrées beryl, dans l'ordre ou non.
for f in "$V"/Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-"$G"; do
  [ -e "$f" ] || continue
  n=${f##*/Boot}
  n=${n%%-*}
  is_ours "$n" && efibootmgr -q -b "$n" -B
done

created=""
failed=0
for d in $DISKS; do
  # Partition EFI du disque, d'après son type GPT (pas de numéro supposé), lue
  # SUR LE DISQUE par partx : la table du noyau du rescue date d'avant
  # l'installation (écrite depuis QEMU, jamais relue) — lsblk n'y voit rien.
  # partx -a/-u mettent aussi la table du noyau à jour, pour efibootmgr.
  partx -a "$d" 2>/dev/null || true
  partx -u "$d" 2>/dev/null || true
  part=$(partx -g -o NR,TYPE "$d" 2>/dev/null |
    awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1; exit }')
  if [ -z "$part" ]; then
    echo "$d : aucune partition EFI, entrée non posée" >&2
    failed=1
    continue
  fi
  pre=$(order)
  efibootmgr -q -c -d "$d" -p "$part" -L "FreeBSD ${d##*/}" -l '\EFI\FreeBSD\loader.efi' || exit 1
  for n in $(order); do
    case " $pre " in
      *" $n "*) ;;
      *) created="$created $n" ;;
    esac
  done
done

final=$(echo $net $created $rest | tr ' ' ',')
efibootmgr -q -o "$final" || exit 1
echo "  ordre avant :"
show "$before"
echo "  ordre après :"
show "$(order)"
exit "$failed"
