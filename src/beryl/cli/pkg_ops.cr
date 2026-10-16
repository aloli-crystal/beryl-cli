require "option_parser"
require "./option_errors"
require "../apply"
require "./info" # scoped_hosts + recipe_packages
require "./account_utils"
require "./ssh_probe"
require "./fleet_job" # canari + parallèle + --status (portée multi-serveurs)

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
        return
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
      Beryl::CLI.handle_option_errors(parser).parse(args)

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

    alias FJ = Beryl::CLI::FleetJob

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
      return unless shell.exec("pkg query %n FreeBSD-runtime", raise_on_error: false).stdout.strip == "FreeBSD-runtime"
      # Catalogue du dépôt de base rafraîchi d'abord : sinon le décompte vient d'un
      # catalogue périmé (cas du résumé de flotte d'`os-upgrade`).
      res = shell.exec("IGNORE_OSVERSION=yes pkg update -q -r #{BASE_REPO} >/dev/null 2>&1; IGNORE_OSVERSION=yes pkg upgrade -n -r #{BASE_REPO}", raise_on_error: false)
      pending_count(res.stdout)
    rescue
      nil
    end

    # Paquets MODIFIÉS annoncés par `pkg upgrade` (-n ou -y) : sections
    # « Installed packages to be UPGRADED: » (`\tnom: a -> b [dépôt]`) et
    # « … REINSTALLED: » (`\tnom-version [dépôt] (options changed)`). Les
    # nouveaux paquets (INSTALLED) ne font tourner aucun service existant :
    # ignorés. Pur.
    def self.changed_packages(output : String) : Array(String)
      names = [] of String
      section : Symbol? = nil
      output.each_line do |line|
        if line.starts_with?("Installed packages to be UPGRADED:")
          section = :upgraded
        elsif line.starts_with?("Installed packages to be REINSTALLED:")
          section = :reinstalled
        elsif !line.starts_with?('\t') && !line.starts_with?("  ")
          section = nil
        elsif section && (item = line.strip.split.first?)
          names << (section == :upgraded ? item.rchop(':') : (item.rindex('-').try { |i| item[0...i] } || item))
        end
      end
      names.uniq
    end

    # Services ACTIVÉS touchés par une mise à jour : scripts rc.d des paquets
    # modifiés ET de tous ceux qui en dépendent, de proche en proche (une
    # bibliothèque comme expat ou openssl met à jour le code de nginx, git…).
    # Un service qui tourne garde l'ancien code en mémoire tant qu'il n'est pas
    # relancé. Lecture seule.
    def self.services_cmd(pkgs : Array(String)) : String
      <<-SH
        seen=" "
        set -- #{pkgs.join(" ")}
        while [ $# -gt 0 ]; do
          p=$1; shift
          case "$seen" in *" $p "*) continue ;; esac
          seen="$seen$p "
          set -- "$@" $(pkg query %rn "$p" 2>/dev/null)
        done
        for p in $seen; do pkg query %Fp "$p" 2>/dev/null; done |
          sed -n 's|^/usr/local/etc/rc.d/||p' | sort -u |
          while read -r s; do service "$s" enabled >/dev/null 2>&1 && echo "$s"; done
        SH
    end

    def self.affected_services(shell : Beryl::Apply::Shell, pkgs : Array(String)) : Array(String)
      return [] of String if pkgs.empty?
      shell.exec(services_cmd(pkgs), raise_on_error: false).stdout.lines.map(&.strip).reject(&.empty?)
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
      restart = true
      parallel = 4
      canary : String? = nil
      detach = false
      status = false
      job_dir : String? = nil
      positional = [] of String
      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl upgrade [portée] [--apply] [--recipes] [--no-restart] [--parallel N] [--canary HOST] [--detach]\n" \
                   "        beryl upgrade --status [TÂCHE]\n" \
                   "        Paquets LOGICIELS (le système de base : `beryl os-upgrade`) — DRY-RUN par défaut ; --apply pour exécuter.\n" \
                   "        Les services ACTIVÉS touchés (paquet ou bibliothèque modifiés) sont relancés.\n" \
                   "        Plusieurs serveurs en --apply : CANARI puis PARALLÈLE limité ; état suivi par `--status`."
        p.on("--apply", "Exécute réellement (sinon : dry-run, affiche le plan sans rien changer)") { apply = true }
        p.on("--recipes", "Ne met à jour QUE les paquets gérés par les recettes (défaut : tous)") { recipes_only = true }
        p.on("--no-restart", "Ne relance pas les services touchés (seulement signalés)") { restart = false }
        p.on("--parallel=N", "Plusieurs serveurs : N à la fois après le canari (défaut 4)") { |v| parallel = v.to_i }
        p.on("--canary=HOST", "Plusieurs serveurs : canari choisi (défaut : le premier de la portée)") { |v| canary = v }
        p.on("--detach", "Plusieurs serveurs : tâche en arrière-plan (suivi par --status)") { detach = true }
        p.on("--status", "État de la dernière tâche (ou de TÂCHE)") { status = true }
        p.on("--job=DIR", "(interne) orchestrateur d'une tâche détachée") { |v| job_dir = v }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      Beryl::CLI.handle_option_errors(parser).parse(args)

      return Beryl::CLI::FleetJob.status("upgrade", positional.first?) if status
      if jd = job_dir
        return Beryl::CLI::FleetJob.run(jd, Beryl::CLI::FleetJob.self_cmd(config_root))
      end
      if parallel < 1
        STDERR.puts "beryl : --parallel attend un entier ≥ 1."
        return EXIT_USAGE
      end

      root = Beryl::Config::Root.load(config_root)
      scope = positional.first? || account_hint || domain_hint
      hosts = PkgOps.freebsd_hosts("upgrade", root, scope)
      if hosts.empty?
        STDERR.puts "beryl : aucun host FreeBSD dans la portée."
        return EXIT_USAGE
      end

      # Plusieurs serveurs en --apply : tâche (canari puis parallèle limité).
      if apply && hosts.size > 1
        fqdns = hosts.map(&.fqdn)
        if c = canary
          first = hosts.find { |h| h.fqdn == c || h.short_name == c }
          unless first
            STDERR.puts "beryl : canari « #{c} » absent de la portée #{scope.inspect}."
            return EXIT_USAGE
          end
          fqdns = [first.fqdn] + (fqdns - [first.fqdn])
        end
        child_args = ["--apply"]
        child_args << "--recipes" if recipes_only
        child_args << "--no-restart" unless restart
        PkgOps.log("upgrade", "portée #{scope} : #{fqdns.size} serveurs → canari #{fqdns.first}, puis #{parallel} en parallèle")
        groups = hosts.compact_map { |h| h.reboot_group.try { |g| {h.fqdn, g} } }.to_h
        dir = Beryl::CLI::FleetJob.create("upgrade", scope || "tous", fqdns, child_args, parallel, groups,
          account: hosts.first.account_name, config_root: config_root)
        if detach
          pid = Beryl::CLI::FleetJob.detach(dir, Beryl::CLI::FleetJob.self_cmd(config_root))
          PkgOps.log("upgrade", "tâche #{File.basename(dir)} lancée en arrière-plan (pid #{pid}) — suivi : `beryl upgrade --status`")
          return EXIT_OK
        end
        return Beryl::CLI::FleetJob.run(dir, Beryl::CLI::FleetJob.self_cmd(config_root))
      end

      PkgOps.log("upgrade", apply ? "MODE --apply (modifie les serveurs)" : "DRY-RUN (aucune modification ; --apply pour exécuter)")
      failures = 0
      unreachable = 0
      base_hosts = [] of String
      hosts.each do |h|
        r = upgrade_one(config_root, h, apply, recipes_only, restart)
        failures += 1 if r == :failed
        unreachable += 1 if r == :unreachable
        base_hosts << h.short_name if r == :base_pending
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

    # UN serveur. Renvoie :ok, :failed, :unreachable ou :base_pending (paquets
    # faits, mais système de base en attente). Rapporte son état à la tâche de
    # flotte quand il tourne en processus enfant (no-op sinon).
    private def self.upgrade_one(config_root, h, apply : Bool, recipes_only : Bool, restart : Bool) : Symbol
      FJ.report(FJ::RUNNING, "connexion")
      # Garde-fou : un host protégé refuse toute ÉCRITURE. Le dry-run (-n,
      # lecture seule) reste permis pour voir le plan.
      if apply && h.protected?
        PkgOps.log("upgrade", "#{h.short_name} : protégé (protected: true) → --apply REFUSÉ (dry-run uniquement)")
        FJ.report(FJ::CANCELLED, "protégé (protected: true)")
        return :ok
      end
      unless shell = PkgOps.connect("upgrade", h)
        FJ.report(FJ::FAILED, "SSH injoignable")
        return :unreachable
      end
      # Chiffré + verrouillé : pkg écrirait dans /usr/local/etc (dataset non
      # monté) → on refuse l'écriture tant que ce n'est pas déverrouillé.
      if apply && PkgOps.locked?(h, shell)
        PkgOps.log("upgrade", "#{h.short_name} : chiffré et VERROUILLÉ → `beryl unlock #{h.short_name}` d'abord (SKIP).")
        FJ.report(FJ::FAILED, "chiffré et verrouillé : `beryl unlock #{h.short_name}` d'abord")
        return :failed
      end

      pkgs : Array(String)? = nil
      if recipes_only
        pkgs = Beryl::CLI::Info.recipe_packages(config_root, [h])
        if pkgs.empty?
          PkgOps.log("upgrade", "#{h.short_name} : aucune recette avec pkg-install → rien à faire")
          FJ.report(FJ::UPTODATE, "aucune recette avec pkg-install")
          return :ok
        end
      end

      PkgOps.log("upgrade", "#{h.short_name} : paquets logiciels (hors #{BASE_REPO}) → pkg upgrade #{apply ? "-y" : "-n"}")
      FJ.report(FJ::RUNNING, apply ? "mise à jour des paquets" : "plan", touched: apply)
      ok, output = PkgOps.run_pkg(shell, software_cmd(apply, pkgs))
      # En dry-run, `pkg upgrade -n` sort non-zéro s'il n'y a RIEN à faire sur
      # certaines versions de pkg — on n'en fait pas un échec, on affiche.
      puts "───── #{h.short_name} ─────"
      puts output.strip.empty? ? "(rien à mettre à jour)" : output.strip
      puts
      if apply && !ok
        FJ.report(FJ::FAILED, "pkg upgrade : #{output.strip.lines.last?}")
        return :failed
      end

      changed = changed_packages(output)
      result = restart_services(h, shell, changed, apply, restart)

      # Système de base : JAMAIS touché ici (redémarrage, local_unbound,
      # jails → `beryl os-upgrade`), seulement signalé, en lecture seule.
      base = base_pending(shell)
      if base && base > 0
        PkgOps.log("upgrade", "#{h.short_name} : système de base — #{base} paquet(s) en attente, NON installés ici → `beryl os-upgrade #{h.short_name}`")
      end
      if apply
        base_note = base && base > 0 ? " ; système : #{base} paquet(s) en attente (os-upgrade)" : ""
        if result[:failed].present?
          FJ.report(FJ::FAILED, "#{changed.size} paquet(s) mis à jour, mais service(s) non relancé(s) : #{result[:failed].join(", ")}#{base_note}")
          return :failed
        elsif changed.empty?
          FJ.report(FJ::UPTODATE, "paquets à jour#{base_note}")
        else
          FJ.report(FJ::UPGRADED, "#{changed.size} paquet(s)#{result[:note]}#{base_note}")
        end
      end
      base && base > 0 ? :base_pending : :ok
    end

    # Services touchés par `changed` : relancés (--apply), signalés sinon.
    # Renvoie {failed: services en échec, note: résumé pour l'état}.
    private def self.restart_services(h, shell, changed : Array(String), apply : Bool, restart : Bool) : NamedTuple(failed: Array(String), note: String)
      none = {failed: [] of String, note: ""}
      return none if changed.empty?
      services = affected_services(shell, changed)
      return none if services.empty?
      unless apply && restart
        why = apply ? "--no-restart" : "dry-run"
        PkgOps.log("upgrade", "#{h.short_name} : service(s) touché(s), à relancer (#{why}) : #{services.join(", ")}")
        return {failed: [] of String, note: " ; services à relancer : #{services.join(", ")}"}
      end
      failed = [] of String
      services.each do |svc|
        PkgOps.log("upgrade", "#{h.short_name} : service #{svc} restart (paquet ou bibliothèque mis à jour)")
        r = shell.exec("service #{Process.quote(svc)} restart", raise_on_error: false)
        unless r.success?
          PkgOps.log("upgrade", "#{h.short_name} : ⚠ #{svc} restart en échec : #{(r.stderr + r.stdout).strip.lines.last?}")
          failed << svc
        end
      end
      {failed: failed, note: " ; relancé(s) : #{(services - failed).join(", ")}"}
    end
  end
end
