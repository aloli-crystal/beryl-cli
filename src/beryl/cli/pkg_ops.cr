require "option_parser"
require "../apply"
require "./info" # scoped_hosts + recipe_packages
require "./account_utils"

# Mises à jour de paquets façon Homebrew, sur une PORTÉE (société/domaine/host/
# tous) :
#   beryl update  [portée]              → `pkg update` : rafraîchit le catalogue
#   beryl upgrade [portée] [--apply]    → `pkg upgrade` : par défaut DRY-RUN (plan
#                                          via `pkg upgrade -n`) ; --apply exécute
#
# Sécurité :
#   * `upgrade` est dry-run par DÉFAUT (ne change rien sans --apply).
#   * Un host `protected: true` (host.yml) REFUSE toute écriture (`update`,
#     `upgrade --apply`) — pour les serveurs sensibles (cible de pentest, gelés).
#     Le dry-run d'`upgrade` y reste autorisé (lecture seule). Aucun nom d'hôte
#     en dur (règle libre) : c'est le flag config qui protège.
#
# Exécution en root via SudoShell (comme `beryl apply`). FreeBSD uniquement.
module Beryl::CLI
  module PkgOps
    # Exécute une commande pkg en root sur un host. Renvoie {ok, sortie}.
    def self.run_pkg(host : Beryl::Config::ResolvedHost, cmd : String) : {Bool, String}
      shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection))
      res = shell.exec(cmd, raise_on_error: false)
      {res.success?, (res.stdout + res.stderr)}
    rescue ex
      {false, ex.message || "erreur de connexion"}
    end

    # Hosts FreeBSD de la portée (les autres OS n'ont pas `pkg`).
    def self.freebsd_hosts(root : Beryl::Config::Root, scope : String?) : Array(Beryl::Config::ResolvedHost)
      Beryl::CLI::Info.scoped_hosts(root, scope).select { |h| h.os == "freebsd" && !h.virtual }
    end

    def self.log(cmd : String, msg : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl #{cmd}] #{msg}"
    end

    # Host chiffré ET VERROUILLÉ ? (au moins une unité avec keystatus=unavailable).
    # Une opération qui écrit dans un point de montage chiffré non monté
    # corromprait l'état → on refuse tant que ce n'est pas `beryl unlock`. csh-safe.
    def self.locked?(host : Beryl::Config::ResolvedHost) : Bool
      return false unless host.encrypted?
      shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection))
      host.encryption_units.any? do |u|
        ks = shell.exec("zfs get -H -o value keystatus #{Process.quote(u)}", raise_on_error: false).stdout.strip
        ks == "unavailable"
      end
    rescue
      false
    end
  end

  # `beryl update [portée]` — `pkg update` (rafraîchit le catalogue des dépôts).
  module Update
    EXIT_OK     = 0
    EXIT_USAGE  = 1
    EXIT_FAILED = 2

    def self.run(config_root : String, args : Array(String)) : Int32
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl update [portée]   (pkg update — rafraîchit le catalogue des dépôts)"
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
      scope = positional.first?
      scope ||= account_hint || domain_hint
      hosts = PkgOps.freebsd_hosts(root, scope)
      if hosts.empty?
        STDERR.puts "beryl : aucun host FreeBSD dans la portée."
        return EXIT_USAGE
      end

      failures = 0
      hosts.each do |h|
        if h.protected?
          PkgOps.log("update", "#{h.short_name} : protégé (protected: true) → SKIP (aucune écriture)")
          next
        end
        ok, output = PkgOps.run_pkg(h, "pkg update")
        if ok
          PkgOps.log("update", "#{h.short_name} : catalogue à jour")
        else
          PkgOps.log("update", "#{h.short_name} : ÉCHEC — #{output.lines.last?.try(&.strip)}")
          failures += 1
        end
      end
      failures > 0 ? EXIT_FAILED : EXIT_OK
    rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost
      STDERR.puts "beryl : #{ex.message}"
      EXIT_USAGE
    end
  end

  # `beryl upgrade [portée] [--apply] [--recipes]` — `pkg upgrade`. DRY-RUN par
  # défaut (plan via `pkg upgrade -n`) ; `--apply` exécute réellement.
  module Upgrade
    EXIT_OK     = 0
    EXIT_USAGE  = 1
    EXIT_FAILED = 2

    def self.run(config_root : String, args : Array(String)) : Int32
      account_hint : String? = nil
      domain_hint : String? = nil
      apply = false
      recipes_only = false
      positional = [] of String
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl upgrade [portée] [--apply] [--recipes]\n" \
                   "        pkg upgrade — DRY-RUN par défaut (plan) ; --apply pour exécuter."
        p.on("--apply", "Exécute réellement (sinon : dry-run, affiche le plan sans rien changer)") { apply = true }
        p.on("--recipes", "Ne met à jour QUE les paquets gérés par les recettes (défaut : tous)") { recipes_only = true }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
      scope = positional.first? || account_hint || domain_hint
      hosts = PkgOps.freebsd_hosts(root, scope)
      if hosts.empty?
        STDERR.puts "beryl : aucun host FreeBSD dans la portée."
        return EXIT_USAGE
      end
      PkgOps.log("upgrade", apply ? "MODE --apply (modifie les serveurs)" : "DRY-RUN (aucune modification ; --apply pour exécuter)")

      failures = 0
      hosts.each do |h|
        # Garde-fou : un host protégé refuse toute ÉCRITURE. Le dry-run (-n,
        # lecture seule) reste permis pour voir le plan.
        if apply && h.protected?
          PkgOps.log("upgrade", "#{h.short_name} : protégé (protected: true) → --apply REFUSÉ (dry-run uniquement)")
          next
        end
        # Chiffré + verrouillé : pkg écrirait dans /usr/local/etc (dataset non
        # monté) → on refuse l'écriture tant que ce n'est pas déverrouillé.
        if apply && PkgOps.locked?(h)
          PkgOps.log("upgrade", "#{h.short_name} : chiffré et VERROUILLÉ → `beryl unlock #{h.short_name}` d'abord (SKIP).")
          next
        end

        pkgs_suffix = ""
        if recipes_only
          pkgs = Beryl::CLI::Info.recipe_packages(config_root, [h])
          if pkgs.empty?
            PkgOps.log("upgrade", "#{h.short_name} : aucune recette avec pkg-install → rien à faire")
            next
          end
          pkgs_suffix = " #{pkgs.join(" ")}"
        end

        cmd = apply ? "pkg upgrade -y#{pkgs_suffix}" : "pkg upgrade -n#{pkgs_suffix}"
        PkgOps.log("upgrade", "#{h.short_name} : #{cmd}")
        ok, output = PkgOps.run_pkg(h, cmd)
        # En dry-run, `pkg upgrade -n` sort non-zéro s'il n'y a RIEN à faire sur
        # certaines versions de pkg — on n'en fait pas un échec, on affiche.
        puts "───── #{h.short_name} ─────"
        puts output.strip.empty? ? "(rien à mettre à jour)" : output.strip
        puts
        failures += 1 if apply && !ok
      end

      if apply && failures > 0
        STDERR.puts "beryl : #{failures} serveur(s) en échec."
        return EXIT_FAILED
      end
      EXIT_OK
    rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost
      STDERR.puts "beryl : #{ex.message}"
      EXIT_USAGE
    end
  end
end
