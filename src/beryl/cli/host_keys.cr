require "../config"
require "../known_hosts"

# Clés d'hôte d'un serveur dans le `known_hosts` de l'opérateur, oubliées à
# chaque changement de système : `beryl rescue` (rescue Linux), `beryl
# boot-hd` (retour au système installé) et `beryl bootstrap` (nouvelle
# installation). Sans cela, son prochain `ssh` bute sur « REMOTE HOST
# IDENTIFICATION HAS CHANGED » (beryl lui-même ne vérifie pas les clés).
module Beryl::CLI::HostKeys
  # Noms et adresses sous lesquels l'opérateur a pu joindre le serveur
  # (FQDN, nom hébergeur, IP publiques, vRack, overlay).
  def self.names(host : Beryl::Config::ResolvedHost) : Array(String)
    names = [host.fqdn, host.ssh_host, host.rescue_ssh_host]
    names.concat([host.ovh_service_name, host.ovh_ipv4, host.ovh_ipv6, host.overlay_ip].compact)
    names.concat(host.vrack_ips)
    names.uniq
  end

  # Retire les clés et le signale ; un échec n'invalide pas la commande.
  def self.forget(host : Beryl::Config::ResolvedHost, command : String) : Nil
    found = Beryl::KnownHosts.forget(names(host), host.port)
    return if found.empty?
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl #{command}] known_hosts : anciennes clés d'hôte retirées (#{found.join(", ")}) ; copie dans #{Beryl::KnownHosts.default_path}.old"
  rescue ex
    STDERR.puts "beryl : ⚠ les anciennes clés d'hôte de #{host.fqdn} n'ont pas pu être retirées de known_hosts (#{ex.message}) — lancez `ssh-keygen -R #{host.fqdn}`."
  end
end
