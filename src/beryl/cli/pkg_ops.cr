require "option_parser"
require "../apply"
require "./info" # scoped_hosts + recipe_packages
require "./account_utils"
require "./ssh_probe"

# Mises à jour de paquets façon Homebrew, sur une PORTÉE (société/domaine/host/
# tous) :
#   beryl update  [portée]              → `pkg update` : rafraîchit le catalogue
#   beryl upgrade [portée] [--apply]    → `pkg upgrade` des PAQUETS LOGICIELS :
#                                          DRY-RUN par défaut (`-n`) ; --apply exécute.
#                                          Le SYSTÈME de base (dépôt FreeBSD-base :
#                                          noyau, userland) n'est JAMAIS touché ici,
#                                          seulement signalé → `beryl os-upgrade`
#                                          (redémarrage, local_unbound, jails).
#
# Sécurité :
#   * `upgrade` est dry-run par DÉFAUT (ne change rien sans --apply).
#   * Un host `protected: true` (host.yml) REFUSE toute écriture (`update`,
#     `upgrade --apply`) — pour les serveurs sensibles (cible de pentest, gelés).
#     Le dry-run d'`upgrade` y reste autorisé (lecture seule). Aucun nom d'hôte
#     en dur (règle libre) : c'est le flag config qui protège.
#   * Un host `installed: false` (pas encore bootstrappé) est sauté.
#
# Connexion : premier user de `connect_users` qui répond (admin… puis root),
# exécution en root via SudoShell (comme `beryl apply`). FreeBSD uniquement.
module Beryl::CLI
  module PkgOps
    # Shell root sur le host via le premier user de connexion qui répond ; nil
    # (motif SSH court journalisé) si aucun ne passe.
    def self.connect(cmd : String, host : Beryl::Config::ResolvedHost) : Beryl::Apply::SudoShell?
      user, probe = Beryl::CLI::SshProbe.reachable(host)
      unless user
        log(cmd, "#{host.short_name} : SSH KO — #{Beryl::CLI::SshProbe.compact_error(probe.stderr, probe.exit_code)} " \
                 "(users tentés : #{host.connect_users.join(", ")})")
        return nil
      end
      Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection(user)))
    rescue ex
      log(cmd, "#{host.short_name} : SSH KO — #{ex.message || "erreur de connexion"}")
      nil
    end

    # Exécute une commande pkg en root. Renvoie {ok, sortie}.
    def self.run_pkg(shell : Beryl::Apply::SudoShell, cmd : String) : {Bool, String}
      res = shell.exec(cmd, raise_on_error: false)
      {res.success?, (res.stdout + res.stderr)}
    rescue ex
      {false, ex.message || "erreur de connexion"}
    end

    # Hosts FreeBSD INSTALLÉS de la portée (les autres OS n'ont pas `pkg`) ;
    # ceux marqués `installed: false` sont signalés puis écartés.
    def self.freebsd_hosts(cmd : String, root : Beryl::Config::Root, scope : String?) : Array(Beryl::Config::ResolvedHost)
      hosts = Beryl::CLI::Info.scoped_hosts(root, scope).select { |h| h.os == "freebsd" && !h.virtual }
      hosts.reject(&.installed?).each do |h|
        log(cmd, "#{h.short_name} : pas encore installé (installed: false) → SKIP")
      end
      hosts.select(&.installed?)
    end

    def self.log(cmd : String, msg : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl #{cmd}] #{msg}"
    end

    # Host chiffré ET VERROUILLÉ ? (au moins une unité avec keystatus=unavailable).
    # Une opération qui écrit dans un point de montage chiffré non monté
    # corromprait l'état → on refuse tant que ce n'est pas `beryl unlock`. csh-safe.
    def self.locked?(host : Beryl::Config::ResolvedHost, shell : Beryl::Apply::SudoShell) : Bool
      return false unless host.encrypted?
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
      hosts = PkgOps.freebsd_hosts("update", root, scope)
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
        unless shell = PkgOps.connect("update", h)
          failures += 1
          next
        end
        ok, output = PkgOps.run_pkg(shell, "pkg update")
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

    # Dépôt du SYSTÈME de base (pkgbase) : réservé à `beryl os-upgrade`.
    BASE_REPO = "FreeBSD-base"

    # `pkg upgrade` des seuls paquets LOGICIELS : `pkgs` (liste fermée, mode
    # --recipes) ou, sinon, les paquets installés HORS du dépôt de base et
    # disponibles dans un dépôt (`pkg upgrade` sans nom toucherait aussi le
    # noyau). Les règles de pkg s'appliquent tel quel à cette liste (versions,
    # options changées, nouvelles dépendances). Lecture seule en dry-run :
    # aucun verrou posé. Aucun paquet logiciel → rien, jamais `pkg upgrade` nu.
    def self.software_cmd(apply : Bool, pkgs : Array(String)? = nil) : String
      flag = apply ? "-y" : "-n"
      if pkgs && !pkgs.empty?
        return "pkg upgrade #{flag} #{pkgs.map { |p| Process.quote(p) }.join(" ")}"
      end
      <<-SH
        pkg update -q || exit $?
        set -- $({ pkg rquery -a '%n'; echo --; pkg query '%n %R'; } | awk '
          !sep && $0 == "--" { sep = 1; next }
          !sep { remote[$1] = 1; next }
          $2 != "#{BASE_REPO}" && ($1 in remote) { print $1 }')
        [ $# -gt 0 ] || { echo "aucun paquet logiciel à examiner"; exit 0; }
        pkg upgrade #{flag} "$@"
        SH
    end

    # Nombre de paquets du système de base en attente (lecture seule), nil si
    # le serveur n'est pas en pkgbase ou si la sonde échoue.
    def self.base_pending(shell : Beryl::Apply::Shell) : Int32?
      return nil unless shell.exec("pkg query %n FreeBSD-runtime", raise_on_error: false).stdout.strip == "FreeBSD-runtime"
      # Catalogue du dépôt de base rafraîchi d'abord : sinon le décompte vient d'un
      # catalogue périmé (cas du résumé de flotte d'`os-upgrade`).
      res = shell.exec("IGNORE_OSVERSION=yes pkg update -q -r #{BASE_REPO} >/dev/null 2>&1; IGNORE_OSVERSION=yes pkg upgrade -n -r #{BASE_REPO}", raise_on_error: false)
      pending_count(res.stdout)
    rescue
      nil
    end

    # « Number of packages to be upgraded: 7 » (+ installed/reinstalled) → 7.
    # 0 si pkg annonce que tout est à jour. Fonction pure.
    def self.pending_count(output : String) : Int32
      output.scan(/^Number of packages to be (?:upgraded|installed|reinstalled): (\d+)/m).sum(&.[1].to_i)
    end

    def self.run(config_root : String, args : Array(String)) : Int32
      account_hint : String? = nil
      domain_hint : String? = nil
      apply = false
      recipes_only = false
      positional = [] of String
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl upgrade [portée] [--apply] [--recipes]\n" \
                   "        Paquets LOGICIELS (le système de base : `beryl os-upgrade`) — DRY-RUN par défaut ; --apply pour exécuter."
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
      hosts = PkgOps.freebsd_hosts("upgrade", root, scope)
      if hosts.empty?
        STDERR.puts "beryl : aucun host FreeBSD dans la portée."
        return EXIT_USAGE
      end
      PkgOps.log("upgrade", apply ? "MODE --apply (modifie les serveurs)" : "DRY-RUN (aucune modification ; --apply pour exécuter)")

      failures = 0
      unreachable = 0
      base_hosts = [] of String
      hosts.each do |h|
        # Garde-fou : un host protégé refuse toute ÉCRITURE. Le dry-run (-n,
        # lecture seule) reste permis pour voir le plan.
        if apply && h.protected?
          PkgOps.log("upgrade", "#{h.short_name} : protégé (protected: true) → --apply REFUSÉ (dry-run uniquement)")
          next
        end
        unless shell = PkgOps.connect("upgrade", h)
          unreachable += 1
          next
        end
        # Chiffré + verrouillé : pkg écrirait dans /usr/local/etc (dataset non
        # monté) → on refuse l'écriture tant que ce n'est pas déverrouillé.
        if apply && PkgOps.locked?(h, shell)
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

        cmd = software_cmd(apply, recipes_only ? pkgs_suffix.split : nil)
        PkgOps.log("upgrade", "#{h.short_name} : paquets logiciels (hors #{BASE_REPO}) → pkg upgrade #{apply ? "-y" : "-n"}")
        ok, output = PkgOps.run_pkg(shell, cmd)
        # En dry-run, `pkg upgrade -n` sort non-zéro s'il n'y a RIEN à faire sur
        # certaines versions de pkg — on n'en fait pas un échec, on affiche.
        puts "───── #{h.short_name} ─────"
        puts output.strip.empty? ? "(rien à mettre à jour)" : output.strip
        puts
        failures += 1 if apply && !ok

        # Système de base : JAMAIS touché ici (redémarrage, local_unbound,
        # jails → `beryl os-upgrade`), seulement signalé, en lecture seule.
        if (n = base_pending(shell)) && n > 0
          PkgOps.log("upgrade", "#{h.short_name} : système de base — #{n} paquet(s) en attente, NON installés ici → `beryl os-upgrade #{h.short_name}`")
          base_hosts << h.short_name
        end
      end

      unless base_hosts.empty?
        STDERR.puts "beryl : mises à jour du SYSTÈME en attente sur #{base_hosts.join(", ")} → `beryl os-upgrade <serveur>` (gère le redémarrage)."
      end

      STDERR.puts "beryl : #{unreachable} serveur(s) injoignable(s) en SSH." if unreachable > 0
      STDERR.puts "beryl : #{failures} serveur(s) en échec." if apply && failures > 0
      return EXIT_FAILED if unreachable > 0 || (apply && failures > 0)
      EXIT_OK
    rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost
      STDERR.puts "beryl : #{ex.message}"
      EXIT_USAGE
    end
  end
end
