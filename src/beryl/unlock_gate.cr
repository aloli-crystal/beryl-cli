require "base64"

# Accès root LIMITÉ AU DÉVERROUILLAGE ZFS, pour les serveurs dont `/home`
# est chiffré (profil `standard` du pool boot).
#
# Avant le déverrouillage, `admin` peut se connecter (ses clés publiques sont
# aussi dans /etc/ssh/authorized_keys/<user>, en clair) mais pas devenir
# root : la configuration de sudo est dans /usr/local/etc, chiffré. root
# reste donc nécessaire pour `zfs load-key`, mais :
#
#   * `PermitRootLogin forced-commands-only` : jamais de session root ;
#   * chaque clé de root porte `restrict,command="<GATE>"` : le script
#     ci-dessous reçoit la commande demandée (`SSH_ORIGINAL_COMMAND`) et
#     n'exécute que les opérations ZFS de `beryl unlock` (liste fermée,
#     noms vérifiés, jamais d'`eval`), tout autre demande est refusée et
#     journalisée (auth).
#
# Une fois déverrouillé, tout repasse par `admin` + sudo (journaux
# nominatifs).
module Beryl::UnlockGate
  # Script de la commande imposée. /usr/local/sbin : outils d'administration
  # locaux (hier(7)), sur zroot EN CLAIR (seuls /home, /opt et
  # /usr/local/etc sont chiffrés par le profil).
  PATH = "/usr/local/sbin/beryl-unlock"

  # Clés publiques des comptes, lisibles avant le déverrouillage (sshd :
  # `AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u`).
  KEYS_DIR = "/etc/ssh/authorized_keys"

  AUTHORIZED_KEYS_FILE = ".ssh/authorized_keys #{KEYS_DIR}/%u"

  PERMIT_ROOT_LOGIN = "forced-commands-only"

  SCRIPT = <<-'SH'
    #!/bin/sh
    # Géré par beryl — commande imposée de root (authorized_keys :
    # restrict,command=...). N'exécute QUE les opérations ZFS de
    # `beryl unlock` ; tout le reste est refusé et journalisé.
    set -f
    PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin
    export PATH
    req=$SSH_ORIGINAL_COMMAND
    # Process.quote de beryl peut entourer un nom d'apostrophes.
    set -- $(printf '%s' "$req" | tr -d "'")
    ok() { case "$1" in ''|-*|*[!A-Za-z0-9_./:-]*) return 1 ;; esac; }
    logger -p auth.info -t beryl-unlock "demande : $req"
    case "$*" in
      "zpool list -H -o name "*)
        [ $# -eq 6 ] && ok "$6" && exec zpool list -H -o name "$6" ;;
      "zpool import -N "*)
        [ $# -eq 4 ] && ok "$4" && exec zpool import -N "$4" ;;
      "zfs get -H -o value keystatus "*)
        [ $# -eq 7 ] && ok "$7" && exec zfs get -H -o value keystatus "$7" ;;
      "zfs load-key "*)
        [ $# -eq 3 ] && ok "$3" && exec zfs load-key "$3" ;;
      "zfs mount -a -l")
        exec zfs mount -a -l ;;
      "zfs list -H -o name,mounted,mountpoint -r "*)
        [ $# -eq 7 ] && ok "$7" && exec zfs list -H -o name,mounted,mountpoint -r "$7" ;;
      "test -x /usr/local/sbin/clevis-zfs")
        exec test -x /usr/local/sbin/clevis-zfs ;;
      "/usr/local/sbin/clevis-zfs unlock --no-mount --dataset "*)
        [ $# -eq 5 ] && ok "$5" && exec /usr/local/sbin/clevis-zfs unlock --no-mount --dataset "$5" ;;
    esac
    logger -p auth.notice -t beryl-unlock "REFUSÉ : $req"
    echo "beryl-unlock : commande refusée (root ne sert qu'au déverrouillage ZFS) : $req" >&2
    exit 126
    SH

  # Ligne d'authorized_keys de root : la clé, restreinte à la commande imposée.
  def self.root_key_line(key : String) : String
    %(restrict,command="#{PATH}" #{key.strip})
  end

  def self.script_b64 : String
    Base64.strict_encode(SCRIPT + "\n")
  end
end
