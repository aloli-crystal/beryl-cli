require "option_parser"
require "../apply"
require "../freebsd_release"
require "./account_utils"
require "./info"   # scoped_hosts (portée société/domaine/host)
require "./unlock" # déverrouillage auto post-reboot (hosts chiffrés)
require "./ssh_probe"
require "./pkg_ops"        # Upgrade.base_pending (correctifs du dépôt de base)
require "./os_upgrade_job" # canari + parallèle + --status (portée multi-serveurs)

# `beryl os-upgrade <host> [--to X.Y] [--apply] [--reboot]` — met à jour le
# SYSTÈME FreeBSD (≠ `upgrade` = paquets seuls). CONSCIENT DU TYPE D'INSTALL :
#
#   * PKGBASE (base en paquets, dépôt `FreeBSD-base`) — le cas beryl par défaut :
#     montée de release = REPOINTER le dépôt `base_release_<minor>` puis
#     `pkg upgrade -r FreeBSD-base` + reboot. Pas de fusion /etc interactive.
#     Déjà sur la dernière release : CORRECTIFS de celle-ci (même branche,
#     sans repoint), sans avoir à préciser `--to`.
#   * DISTRIBUTION_SETS (base en tarballs) : `freebsd-update` — multi-étapes +
#     fusions interactives → beryl affiche le RUNBOOK (pas d'auto-apply).
#
# DRY-RUN par défaut. `--apply` exécute (repoint + pkg upgrade), s'arrête AVANT
# le reboot (sûr). `--reboot` ajoute le reboot + attente du retour SSH (pour
# enchaîner une flotte). Un host `protected: true` refuse `--apply`.
module Beryl::CLI::OsUpgrade
  EXIT_OK     = 0
  EXIT_USAGE  = 1
  EXIT_FAILED = 2

  BASE_REPO = "FreeBSD-base"
  # Franchir un `__FreeBSD_version` plus récent (les paquets base de la release
  # cible sont plus récents que le noyau courant) : mécanisme standard pkgbase.
  # Sans lui : `pkg: repository … contains packages for wrong OS version`.
  IGNORE_OSV = "IGNORE_OSVERSION=yes"

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    to : String? = nil
    apply = false
    reboot = false
    parallel = 4
    canary : String? = nil
    detach = false
    status = false
    job_dir : String? = nil
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl os-upgrade <host|société|domaine> [--to X.Y] [--apply] [--reboot] [--parallel N] [--canary HOST] [--detach]\n" \
                 "        beryl os-upgrade --status [TÂCHE]\n" \
                 "        Met à jour le système FreeBSD sur toute la portée. DRY-RUN par défaut.\n" \
                 "        Plusieurs serveurs en --apply : CANARI (un serveur, arrêt s'il échoue) puis\n" \
                 "        PARALLÈLE limité ; état suivi par `--status`."
      p.on("--to=VERSION", "Release cible X.Y (défaut : dernière de la branche courante)") { |v| to = v }
      p.on("--apply", "Exécute (repoint + pkg upgrade). S'arrête AVANT le reboot sauf --reboot") { apply = true }
      p.on("--reboot", "Avec --apply : reboot + attente du retour SSH (pour enchaîner une flotte)") { reboot = true }
      p.on("--parallel=N", "Plusieurs serveurs : N à la fois après le canari (défaut 4)") { |v| parallel = v.to_i }
      p.on("--canary=HOST", "Plusieurs serveurs : canari choisi (défaut : le premier de la portée)") { |v| canary = v }
      p.on("--detach", "Plusieurs serveurs : tâche en arrière-plan (rend la main ; suivi par --status)") { detach = true }
      p.on("--status", "État de la dernière tâche (ou de TÂCHE)") { status = true }
      p.on("--job=DIR", "(interne) orchestrateur d'une tâche détachée") { |v| job_dir = v }
      p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    return Beryl::CLI::OsUpgradeJob.status(positional.first?) if status
    if jd = job_dir
      return Beryl::CLI::OsUpgradeJob.run(jd, child_cmd(config_root))
    end
    if parallel < 1
      STDERR.puts "beryl : --parallel attend un entier ≥ 1."
      return EXIT_USAGE
    end

    # Périmètre : host, société ou domaine (comme `beryl update`/`upgrade`).
    scope = positional.first? || account_hint || domain_hint
    unless scope
      STDERR.puts "beryl : périmètre non précisé. USAGE : beryl os-upgrade <host|société|domaine> [--to X.Y] [--apply] [--reboot]"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    hosts = Beryl::CLI::Info.scoped_hosts(root, scope).select { |h| h.os == "freebsd" && !h.virtual }
    hosts.reject(&.installed?).each do |h|
      log "#{h.fqdn} : pas encore installé (installed: false) → ignoré."
    end
    hosts = hosts.select(&.installed?)
    if hosts.empty?
      STDERR.puts "beryl : aucun hôte FreeBSD dans le périmètre #{scope.inspect}."
      return EXIT_USAGE
    end
    # Portée multi-hôtes en DRY-RUN → tableau compact (état du parc), et non
    # le plan détaillé de chacun (illisible à 20 hôtes). Le détail reste
    # disponible hôte par hôte, ou en --apply.
    if hosts.size > 1 && !apply
      return fleet_summary(hosts, to)
    end
    if hosts.size == 1
      return upgrade_one(config_root, hosts.first, to, apply, reboot)
    end

    # Plusieurs serveurs en --apply : tâche (canari puis parallèle limité).
    fqdns = hosts.map(&.fqdn)
    if c = canary
      first = hosts.find { |h| h.fqdn == c || h.short_name == c }
      unless first
        STDERR.puts "beryl : canari « #{c} » absent de la portée #{scope.inspect}."
        return EXIT_USAGE
      end
      fqdns = [first.fqdn] + (fqdns - [first.fqdn])
    end
    log "périmètre #{scope} : #{fqdns.size} serveurs → canari #{fqdns.first}, puis #{parallel} en parallèle"
    log "⚠ SANS --reboot : le canari ne valide que l'INSTALLATION, pas le démarrage sur le nouveau noyau." unless reboot
    dir = Beryl::CLI::OsUpgradeJob.create(scope, fqdns, reboot, to, parallel)
    if detach
      pid = Beryl::CLI::OsUpgradeJob.detach(dir, child_cmd(config_root))
      log "tâche #{File.basename(dir)} lancée en arrière-plan (pid #{pid}) — suivi : `beryl os-upgrade --status`"
      return EXIT_OK
    end
    Beryl::CLI::OsUpgradeJob.run(dir, child_cmd(config_root))
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_FAILED
  end

  # Commande de base d'un processus enfant : CE binaire + options globales
  # (racine de config, transport), pour que l'enfant voie la même config.
  private def self.child_cmd(config_root : String) : Array(String)
    exe = Process.executable_path || PROGRAM_NAME
    cmd = [exe, "-c", config_root]
    cmd << "--transport=overlay" if Beryl.transport_mode == :overlay
    cmd
  end

  # Montée d'UN hôte (dry-run par défaut). Chaque `return` est LOCAL à l'hôte
  # (méthode appelée en boucle par `run` pour une portée société/domaine).
  private def self.upgrade_one(config_root : String, host : Beryl::Config::ResolvedHost, to : String?, apply : Bool, reboot : Bool) : Int32
    unless host.os == "freebsd"
      STDERR.puts "beryl : os-upgrade = FreeBSD uniquement (host : #{host.os})."
      return EXIT_USAGE
    end
    Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::RUNNING, "connexion")
    if apply && host.protected?
      log "#{host.fqdn} : protégé (protected: true) → --apply REFUSÉ (dry-run uniquement)."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::CANCELLED, "protégé (protected: true)")
      return EXIT_OK
    end

    # Trouve le user qui répond (cascade connect_users : admin, deploy… puis
    # root), avec la version déjà lue. Puis SudoShell sur CE user.
    user, probe = Beryl::CLI::SshProbe.reachable(host, "freebsd-version -r")
    cur_raw = probe.stdout.strip
    cur = parse_version(cur_raw)
    unless user && cur
      STDERR.puts "beryl : #{host.fqdn} injoignable en SSH (users tentés : #{host.connect_users.join(", ")})."
      STDERR.puts "        #{host.ssh_host}:#{host.port} → #{Beryl::CLI::SshProbe.compact_error(probe.stderr, probe.exit_code)} (exit #{probe.exit_code})"
      if d = probe.stderr.strip.lines.first?
        STDERR.puts "        détail : #{d}"
      end
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "SSH : #{Beryl::CLI::SshProbe.compact_error(probe.stderr, probe.exit_code)}")
      return EXIT_FAILED
    end
    shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection(user)))
    cur_major, cur_minor, _ = cur

    target =
      if t = to
        t
      else
        begin
          Beryl::FreebsdRelease.latest_by_branch[cur_major]?
        rescue
          nil
        end
      end
    unless target
      STDERR.puts "beryl : release cible indéterminée (réseau indispo ?) — précisez `--to X.Y`."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "release cible indéterminée")
      return EXIT_USAGE
    end

    ck = {cur_major, cur_minor}
    tk = Beryl::FreebsdRelease.version_key(target)
    log "#{host.fqdn} : #{cur_raw} → cible #{target}-RELEASE"
    # Cible ANTÉRIEURE : jamais de descente de release (même avec --to).
    # Cible ÉGALE : on continue → correctifs de la release courante (errata/SA).
    if tk < ck
      log "déjà sur #{cur_major}.#{cur_minor} (> #{target}) — rien à faire (pas de descente de release)."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::UPTODATE, "#{cur_raw} (> #{target})", cur_raw)
      return EXIT_OK
    end

    # Détection pkgbase : un système pkgbase a le paquet FreeBSD-runtime installé.
    pkgbase = shell.exec("pkg query %n FreeBSD-runtime", raise_on_error: false).stdout.strip == "FreeBSD-runtime"

    if pkgbase
      pkgbase_upgrade(config_root, shell, host, cur_major, cur_minor, target, tk, ck, apply, reboot)
    else
      freebsd_update_flow(config_root, shell, host, cur_raw, target, tk, ck, apply, reboot)
    end
  rescue ex
    STDERR.puts "beryl : #{host.fqdn} — erreur inattendue : #{ex.class}: #{ex.message}"
    Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "erreur inattendue : #{ex.message}")
    EXIT_FAILED
  end

  NOTE_UP     = "montée dispo"
  NOTE_PATCH  = "correctifs en attente"
  NOTE_OK     = "à jour"
  NOTE_REBOOT = "redémarrage en attente"

  record HostState, fqdn : String, ok : Bool, current : String?, target : String?, note : String

  # Résumé compact d'une portée multi-hôtes (dry-run) : une ligne par hôte
  # (version → cible, ou motif d'échec) + un décompte. Lisible à 20 hôtes.
  private def self.fleet_summary(hosts, to) : Int32
    states = hosts.map { |h| probe_one(h, to) }
    w = states.map(&.fqdn.size).max? || 20
    puts ""
    states.each do |st|
      ver = st.current ? (st.target ? "#{st.current} → #{st.target}" : st.current.not_nil!) : "—"
      puts "  #{st.fqdn.ljust(w)}  #{ver.ljust(26)}  #{st.note}"
    end
    up = states.count { |s| s.note.starts_with?(NOTE_UP) }
    patch = states.count { |s| s.note.includes?(NOTE_PATCH) }
    boot = states.count { |s| s.note.includes?(NOTE_REBOOT) }
    ready = states.count { |s| s.note.starts_with?(NOTE_OK) }
    ko = states.count { |s| !s.ok }
    puts ""
    puts "Résumé : #{up} à monter · #{patch} avec correctifs en attente · #{boot} à redémarrer · #{ready} à jour · #{ko} injoignables (sur #{states.size})."
    puts "→ détail : `beryl os-upgrade <host>` ; appliquer : `beryl os-upgrade <host> --apply [--reboot]`."
    EXIT_OK
  end

  # État d'un hôte pour le résumé de flotte, en LECTURE SEULE : version (sans
  # sudo) puis, si la release est la dernière, correctifs du dépôt de base en
  # attente (`pkg upgrade -n`, via sudo : rien n'est installé).
  private def self.probe_one(host, to) : HostState
    user, probe = Beryl::CLI::SshProbe.reachable(host, "freebsd-version -r")
    cur_raw = probe.stdout.strip
    cur = parse_version(cur_raw)
    unless user && cur
      return HostState.new(host.fqdn, false, nil, nil, "SSH KO : #{Beryl::CLI::SshProbe.compact_error(probe.stderr, probe.exit_code)}")
    end
    via = user == host.connect_user ? "" : " (via #{user})"
    cur_major, cur_minor, _ = cur
    target = to || begin
      Beryl::FreebsdRelease.latest_by_branch[cur_major]?
    rescue
      nil
    end
    unless target
      return HostState.new(host.fqdn, true, cur_raw, nil, "majeur #{cur_major} sans cible (branche EOL ?)#{via}")
    end
    up_needed = Beryl::FreebsdRelease.version_key(target) > {cur_major, cur_minor} || !to.nil?
    return HostState.new(host.fqdn, true, cur_raw, target, "#{NOTE_UP}#{via}") if up_needed
    shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection(user)))
    case n = Beryl::CLI::Upgrade.base_pending(shell)
    when nil then HostState.new(host.fqdn, true, cur_raw, target, "#{NOTE_OK} (release ; correctifs non vérifiés, pas en pkgbase)#{via}")
    when 0
      if (k = pending_kernel(shell))
        HostState.new(host.fqdn, true, cur_raw, target, "noyau #{k[:installed]} installé — #{NOTE_REBOOT}#{via}")
      else
        HostState.new(host.fqdn, true, cur_raw, target, "#{NOTE_OK}#{via}")
      end
    else HostState.new(host.fqdn, true, cur_raw, target, "#{n} paquet(s) de base — #{NOTE_PATCH}#{via}")
    end
  rescue ex
    HostState.new(host.fqdn, false, nil, nil, "erreur : #{ex.message}")
  end

  # Après une montée pkgbase, certaines confs de services base deviennent
  # incompatibles → à régénérer AVANT le reboot, sinon le service repart sur
  # une conf périmée. `local_unbound` (résolveur DNS local) : `setup` régénère
  # sa conf ; sans ça le DNS de l'hôte peut casser au redémarrage (message pkg
  # « run service local_unbound setup before restarting »).
  private def self.reconfigure_base_services(shell, host) : Nil
    enabled = shell.exec("sysrc -n local_unbound_enable 2>/dev/null", raise_on_error: false).stdout.strip.upcase
    return unless enabled == "YES"
    log "#{host.fqdn} : local_unbound activé → `service local_unbound setup` (régénération de la conf)"
    res = shell.exec("service local_unbound setup", raise_on_error: false)
    log "#{host.fqdn} : ⚠ `local_unbound setup` a échoué (#{res.stderr.strip.lines.last?}) — vérifiez le DNS après reboot." unless res.success?
  end

  # ── PKGBASE : repoint `base_release_<minor>` + pkg upgrade (+ reboot) ────────
  private def self.pkgbase_upgrade(config_root, shell, host, cur_major, cur_minor, target, tk, ck, apply, reboot) : Int32
    target_minor = tk[1]
    branch = "base_release_#{target_minor}"

    return pkgbase_patch(config_root, shell, host, target, apply, reboot) if tk == ck

    # Localise le fichier de conf du dépôt FreeBSD-base (beryl : /usr/local/etc/
    # pkg/repos/FreeBSD-base.conf ; on cherche large). SudoShell → `sh -c`.
    conf = shell.exec("grep -rl base_release /usr/local/etc/pkg/repos /etc/pkg 2>/dev/null | head -1", raise_on_error: false).stdout.strip
    if conf.empty?
      STDERR.puts "beryl : conf du dépôt FreeBSD-base introuvable (base_release) sur #{host.fqdn}."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "conf du dépôt FreeBSD-base introuvable")
      return EXIT_FAILED
    end
    cur_branch = shell.exec("grep -oE 'base_release_[0-9]+' #{conf} | head -1", raise_on_error: false).stdout.strip

    unless apply
      puts ""
      puts "Montée pkgbase #{cur_major}.#{cur_minor} → #{target} sur #{host.fqdn} (dry-run) :"
      puts "  1. repoint #{conf} : #{cur_branch} → #{branch}"
      puts "  2. #{IGNORE_OSV} pkg update -f -r #{BASE_REPO}"
      puts "  3. #{IGNORE_OSV} pkg upgrade -r #{BASE_REPO}   # voir le plan : --apply le montre réellement"
      puts "  4. shutdown -r now                    # (--reboot l'automatise)"
      puts ""
      puts "→ `beryl os-upgrade #{host.short_name} --to #{target} --apply` exécute 1-3 (s'arrête avant 4)."
      puts "  Ajoutez `--reboot` pour enchaîner le reboot + attente SSH."
      puts "NB : si `#{branch}` n'est pas encore publié sur le miroir, l'étape 2 échoue (rollback auto du repoint)."
      return EXIT_OK
    end

    # --apply : repoint, puis valide en rafraîchissant le catalogue. Si le
    # catalogue de la nouvelle branche est vide/absent (release pas publiée),
    # on ROLLBACK le repoint pour ne pas laisser le host sur une branche morte.
    log "#{host.fqdn} : repoint #{cur_branch} → #{branch} (#{conf})"
    shell.exec("sed -i '' -E 's/base_release_[0-9]+/#{branch}/g' #{conf}", raise_on_error: false)
    upd = shell.exec("#{IGNORE_OSV} pkg update -f -r #{BASE_REPO}", raise_on_error: false)
    unless upd.success?
      log "#{host.fqdn} : `pkg update` a échoué sur #{branch} (release pas encore publiée ?) → ROLLBACK vers #{cur_branch}."
      shell.exec("sed -i '' -E 's/base_release_[0-9]+/#{cur_branch}/g' #{conf}", raise_on_error: false)
      STDERR.puts upd.stderr.strip.lines.last?
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "branche #{branch} indisponible (rollback fait)")
      return EXIT_FAILED
    end

    log "#{host.fqdn} : pkg upgrade -y -r #{BASE_REPO}…"
    Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::RUNNING, "montée #{cur_major}.#{cur_minor} → #{target}")
    up = shell.exec("#{IGNORE_OSV} pkg upgrade -y -r #{BASE_REPO}", raise_on_error: false)
    puts up.stdout.strip
    unless up.success?
      STDERR.puts "beryl : pkg upgrade a échoué — #{up.stderr.strip.lines.last?}"
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "pkg upgrade : #{up.stderr.strip.lines.last?}")
      return EXIT_FAILED
    end

    after_base_upgrade(shell, host)
    finish(config_root, shell, host, "base #{target} installée", reboot)
  end

  # Correctifs de la release COURANTE (pkgbase, même branche base_release_<minor>) :
  # pas de repoint. Dry-run = `pkg upgrade -n` (liste des correctifs en attente) ;
  # --apply = `pkg upgrade -y` VÉRIFIÉ, puis reboot si --reboot.
  private def self.pkgbase_patch(config_root, shell, host, target, apply, reboot) : Int32
    upd = shell.exec("#{IGNORE_OSV} pkg update -f -r #{BASE_REPO}", raise_on_error: false)
    unless upd.success?
      STDERR.puts "beryl : #{host.fqdn} — `pkg update -r #{BASE_REPO}` a échoué : #{upd.stderr.strip.lines.last?}"
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "pkg update : #{upd.stderr.strip.lines.last?}")
      return EXIT_FAILED
    end
    plan = shell.exec("#{IGNORE_OSV} pkg upgrade -n -r #{BASE_REPO}", raise_on_error: false)
    unless pending_upgrades?(plan.stdout)
      # Correctifs déjà INSTALLÉS (apply précédent sans --reboot) mais noyau
      # pas encore chargé : seul le redémarrage reste à faire.
      if (k = pending_kernel(shell))
        log "#{host.fqdn} : correctifs installés, noyau #{k[:installed]} en attente (en service : #{k[:running]}) — REDÉMARRAGE requis."
        return finish(config_root, shell, host, "noyau #{k[:installed]} installé", reboot) if apply
        puts "→ `beryl os-upgrade #{host.short_name} --apply --reboot` (ou `beryl reboot #{host.short_name}`) le charge."
        return EXIT_OK
      end
      log "#{host.fqdn} : #{target}-RELEASE, aucun correctif en attente — rien à faire."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::UPTODATE, "aucun correctif en attente")
      return EXIT_OK
    end

    unless apply
      log "#{host.fqdn} : correctifs #{target}-RELEASE en attente (dry-run) :"
      puts plan.stdout.strip
      puts ""
      puts "→ `beryl os-upgrade #{host.short_name} --apply` les installe (s'arrête avant le reboot)."
      puts "  Ajoutez `--reboot` pour enchaîner le reboot + attente SSH."
      return EXIT_OK
    end

    log "#{host.fqdn} : correctifs #{target}-RELEASE → pkg upgrade -y -r #{BASE_REPO}…"
    Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::RUNNING, "installation des correctifs (#{Beryl::CLI::Upgrade.pending_count(plan.stdout)} paquets)")
    up = shell.exec("#{IGNORE_OSV} pkg upgrade -y -r #{BASE_REPO}", raise_on_error: false)
    puts up.stdout.strip
    unless up.success?
      STDERR.puts "beryl : #{host.fqdn} — pkg upgrade a échoué : #{up.stderr.strip.lines.last?}"
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "pkg upgrade : #{up.stderr.strip.lines.last?}")
      return EXIT_FAILED
    end

    after_base_upgrade(shell, host)
    finish(config_root, shell, host, "correctifs #{target}-RELEASE installés", reboot)
  end

  # Noyau INSTALLÉ (`freebsd-version -k`) différent du noyau EN SERVICE (`-r`) →
  # {installed, running}, sinon nil : correctifs posés, redémarrage en attente.
  def self.pending_kernel(shell : Beryl::Apply::Shell) : NamedTuple(installed: String, running: String)?
    res = shell.exec("freebsd-version -k; freebsd-version -r", raise_on_error: false)
    kernel_mismatch(res.stdout)
  end

  # Deux lignes (`-k` puis `-r`) → {installed, running} si elles diffèrent. Pure.
  def self.kernel_mismatch(output : String) : NamedTuple(installed: String, running: String)?
    lines = output.lines.map(&.strip).reject(&.empty?)
    return nil unless lines.size == 2 && lines[0] != lines[1]
    {installed: lines[0], running: lines[1]}
  end

  # Vrai si la sortie d'un `pkg upgrade -n` annonce des paquets à modifier
  # (« Number of packages to be upgraded: 43 ») ; faux si « … is up to date ».
  def self.pending_upgrades?(dry_run_output : String) : Bool
    dry_run_output.matches?(/^Number of packages to be (upgraded|installed|reinstalled|removed)/m)
  end

  # Après tout `pkg upgrade` du base : confs de services à régénérer + rappel
  # thin jails (leur base partagé /jails/.base est distinct du base host → à
  # rafraîchir, puis redémarrer les jails qui le montent en nullfs RO).
  private def self.after_base_upgrade(shell, host) : Nil
    reconfigure_base_services(shell, host)
    if shell.exec("test -d /jails/.base", raise_on_error: false).success?
      log "#{host.fqdn} : des thin jails partagent /jails/.base → rafraîchissez-le " \
          "(`beryl apply #{host.short_name} jail-base`) puis redémarrez les jails (`service jail restart`)."
    end
  end

  # Fin commune d'une mise à jour système : sans --reboot, rappel du reboot ;
  # avec --reboot, reboot + attente du retour SSH (+ déverrouillage si chiffré).
  private def self.finish(config_root, shell, host, done : String, reboot : Bool) : Int32
    unless reboot
      log "#{host.fqdn} : #{done}. REBOOTEZ pour démarrer dessus : `shutdown -r now`."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::UPGRADED, "#{done} — redémarrage à faire")
      return EXIT_OK
    end

    log "#{host.fqdn} : reboot…"
    Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::RUNNING, "#{done} — redémarrage")
    shell.exec("shutdown -r now", raise_on_error: false)
    if wait_back(host)
      new = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection))
        .exec("freebsd-version -r", raise_on_error: false).stdout.strip
      log "#{host.fqdn} : revenu — #{new}"
      # Host chiffré : il revient VERROUILLÉ (datasets non montés) → déverrouille
      # pour qu'il soit opérationnel (sinon /home, /usr/local/etc absents).
      if host.encrypted?
        log "#{host.fqdn} : chiffré → déverrouillage post-reboot (beryl unlock)…"
        Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::RUNNING, "revenu en #{new} — déverrouillage", new)
        unless Beryl::CLI::Unlock.run(config_root, [host.fqdn]) == 0
          Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "revenu en #{new}, mais déverrouillage en échec (beryl unlock #{host.short_name})", new)
          return EXIT_FAILED
        end
      end
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::UPGRADED, "revenu en #{new}", new)
      EXIT_OK
    else
      STDERR.puts "beryl : #{host.fqdn} n'est pas revenu en SSH après reboot (vérifiez via la console/IPMI)."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "pas revenu en SSH après redémarrage (console/IPMI)")
      EXIT_FAILED
    end
  end

  # Attend le retour SSH après reboot (grâce initiale + polling). True si revenu.
  private def self.wait_back(host, grace = 20, timeout = 300, interval = 15) : Bool
    sleep grace.seconds
    deadline = Time.instant + timeout.seconds
    while Time.instant < deadline
      begin
        return true if host.connection.exec("uname -s", raise_on_error: false).success?
      rescue
        # pas encore là
      end
      sleep interval.seconds
    end
    false
  end

  # ── DISTRIBUTION_SETS : freebsd-update (runbook ; patchs auto via --apply) ───
  private def self.freebsd_update_flow(config_root, shell, host, cur_raw, target, tk, ck, apply, reboot) : Int32
    if tk == ck
      if apply
        log "#{host.fqdn} : freebsd-update fetch install (correctifs)…"
        res = shell.exec("freebsd-update --not-running-from-cron fetch install", raise_on_error: false)
        puts res.stdout.strip unless res.stdout.strip.empty?
        unless res.success?
          Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::FAILED, "freebsd-update : #{res.stderr.strip.lines.last?}")
          return EXIT_FAILED
        end
        return finish(config_root, shell, host, "correctifs appliqués (reboot utile si nouveau noyau)", reboot)
      end
      puts ""
      puts "Correctifs FreeBSD (#{target}-RELEASE) — runbook :"
      puts "  freebsd-update fetch install"
      puts "→ `beryl os-upgrade #{host.short_name} --apply` exécute ces correctifs."
      return EXIT_OK
    end

    if apply
      log "montée de release : --apply non automatisé pour freebsd-update (reboots + fusions interactives)."
      Beryl::CLI::OsUpgradeJob.report(Beryl::CLI::OsUpgradeJob::CANCELLED, "montée de release freebsd-update : à la main (runbook)")
    end
    h = host.short_name
    puts ""
    puts "Montée de RELEASE #{cur_raw} → #{target}-RELEASE sur #{host.fqdn} (freebsd-update)"
    puts "─" * 64
    puts "⚠️  Multi-étapes AVEC REBOOTS + fusions de config interactives — à la main."
    puts ""
    puts "  freebsd-update -r #{target}-RELEASE upgrade"
    puts "  freebsd-update install      # noyau ; puis : shutdown -r now"
    puts "  freebsd-update install      # userland (après reboot)"
    puts "  pkg upgrade -f              # recompile pour le nouvel ABI ; puis reboot"
    puts "  freebsd-update install      # finalisation"
    puts ""
    puts "Doc : https://docs.freebsd.org/en/books/handbook/cutting-edge/#freebsdupdate-upgrade"
    EXIT_OK
  end

  # Parse « 15.0-RELEASE-p10 » → {major, minor, patch?}. nil si illisible.
  def self.parse_version(s : String) : {Int32, Int32, Int32?}?
    m = s.match(/(\d+)\.(\d+)(?:-RELEASE)?(?:-p(\d+))?/)
    return nil unless m
    {m[1].to_i, m[2].to_i, m[3]?.try(&.to_i)}
  end

  # Nom de branche pkgbase pour une release X.Y (« 15.1 » → « base_release_1 »).
  def self.base_branch(version : String) : String
    "base_release_#{Beryl::FreebsdRelease.version_key(version)[1]}"
  end

  private def self.log(msg : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl os-upgrade] #{msg}"
  end
end
