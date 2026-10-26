require "ssh"
require "../apply/shell"

module Beryl::CLI
  # Connexion SSH dont chaque commande tourne en ROOT : telle quelle si beryl
  # est connecté en root, sinon via `sudo -n` (NOPASSWD attendu, comme `sync`).
  # Pour les commandes qui pilotent ZFS directement (`unlock`, `lock`,
  # `status`, `tang-enroll`) : root SSH coupé sur les hôtes durcis
  # (`PermitRootLogin no`), le compte de connexion (`admin`) ne voit aucun
  # pool sans escalade (« no such pool available »). L'entrée standard (clé
  # de `zfs load-key`) traverse `sudo`.
  class RootConn
    getter inner : SSH::Connection

    def initialize(@inner : SSH::Connection)
    end

    def user : String
      @inner.user
    end

    def host : String
      @inner.host
    end

    def root? : Bool
      @inner.user == "root"
    end

    def exec(command : String, stdin : String? = nil, raise_on_error : Bool = true) : SSH::Result
      @inner.exec(self.class.line(command, root?), stdin: stdin, raise_on_error: raise_on_error)
    end

    # Ligne envoyée : la commande telle quelle en root, sinon enrobée
    # (`sudo -n sh -c '…'`, pipes et redirections compris). Pur.
    def self.line(command : String, root : Bool) : String
      root ? command : "sudo -n #{Beryl::Apply.sh_line(command)}"
    end
  end
end
