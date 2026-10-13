require "../apply"

# Joindre un host par le PREMIER user de connexion qui répond (cascade
# `connect_users` : admin, deploy… puis root), et résumer un échec SSH en une
# ligne lisible. Partagé par les commandes de flotte (`os-upgrade`, `update`,
# `upgrade`).
module Beryl::CLI::SshProbe
  extend self

  # Exécute `cmd` avec chaque user de `connect_users` et renvoie le PREMIER qui
  # répond (sortie non vide), avec son résultat. S'arrête dès une erreur
  # RÉSEAU (timeout/refus/DNS) : inutile de tester d'autres users sur un hôte
  # injoignable. Renvoie {user_ok | nil, dernier_résultat}.
  def reachable(host : Beryl::Config::ResolvedHost, cmd : String = "uname -s") : {String?, SSH::Result}
    last = SSH::Result.new("", "", 255)
    host.connect_users.each do |u|
      res = Beryl::Apply::SshShell.new(host.connection(u)).exec(cmd, raise_on_error: false)
      return {u, res} if res.success? && !res.stdout.strip.empty?
      last = res
      break if network_error?(res.stderr)
    end
    {nil, last}
  end

  def network_error?(stderr : String) : Bool
    s = stderr.downcase
    s.includes?("timed out") || s.includes?("timeout") || s.includes?("banner exchange") ||
      s.includes?("connection refused") || s.includes?("could not resolve") || s.includes?("name or service")
  end

  # Motif SSH lisible en une ligne (sans le préfixe `user@host:`).
  def compact_error(stderr : String, exit_code : Int32) : String
    s = stderr.downcase
    return "clé refusée (publickey)" if s.includes?("permission denied")
    return "timeout / injoignable" if s.includes?("timed out") || s.includes?("timeout") || s.includes?("banner exchange")
    return "hôte inconnu (DNS)" if s.includes?("could not resolve") || s.includes?("name or service")
    return "connexion refusée" if s.includes?("connection refused")
    "SSH exit #{exit_code}"
  end
end
