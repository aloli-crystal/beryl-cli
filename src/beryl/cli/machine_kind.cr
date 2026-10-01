require "../config"

# Garde commune des commandes qui pilotent l'API « serveur dédié » de
# l'hébergeur (rescue, boot-hd, reboot --hard, vrack, bootstrap, dns).
# Un host `kind: vps` n'a pas de service `/dedicated/server/*` : sans
# cette garde, l'appel API échouerait en 404 avec un message obscur.
# Le support VPS viendra par une implémentation dédiée (cf.
# `adoc/vps-support.adoc`) ; d'ici là, refus explicite.
module Beryl::CLI::MachineKind
  # Vrai si la commande doit s'arrêter (host VPS) ; le message est
  # écrit sur STDERR. Usage : `return EXIT_X if MachineKind.refuse_vps(host, "rescue")`.
  def self.refuse_vps(host : Beryl::Config::ResolvedHost, command : String) : Bool
    return false unless host.vps?
    STDERR.puts "beryl : `#{command}` pilote l'API « serveur dédié » de l'hébergeur — " \
                "pas encore disponible pour un VPS (#{host.fqdn}, kind: vps)."
    true
  end
end
