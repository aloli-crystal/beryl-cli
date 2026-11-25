require "ssh"

module Beryl
  # Options ssh d'APPEL communes à toutes les connexions de beryl (le shard
  # `ssh` n'impose rien de tel : c'est à l'appelant de les demander).
  #
  # `IPQoS=ef` : priorité IP « temps réel » (DSCP EF), que le Wi-Fi (WMM) sert
  # en file « voix ». Sans terminal, OpenSSH 10 laisse le marquage par défaut
  # du système (`none`). Mesuré le 25 nov. 2026 depuis un poste (Wi-Fi) vers
  # un serveur, un aller-retour sur une session ouverte : ~240-260 ms en `none` (le
  # défaut), ~220-295 ms en `lowdelay`, 88-240 ms en `cs1` (instable), 55-63 ms
  # en `ef`, pour un ping de 46 ms. Le shard réémet `IPQoS` sur le rebond
  # `ProxyCommand` (bastion), qui est la connexion qui traverse le réseau local.
  SSH_OPTIONS = {"IPQoS" => "ef"}

  # Fabrique UNIQUE des connexions ssh de beryl : `SSH::Connection` avec les
  # options communes (`SSH_OPTIONS`), que les `options` de l'appelant peuvent
  # surcharger. Aucun `SSH::Connection.new` ailleurs dans beryl (spec garde-fou).
  def self.ssh_connection(
    host : String,
    user : String = "root",
    port : Int32 = 22,
    identity_file : String? = nil,
    options : Hash(String, String) = {} of String => String,
    jump_fallbacks : Array(String) = [] of String,
  ) : SSH::Connection
    SSH::Connection.new(
      host: host,
      user: user,
      port: port,
      identity_file: identity_file,
      options: SSH_OPTIONS.merge(options),
      jump_fallbacks: jump_fallbacks,
    )
  end
end
