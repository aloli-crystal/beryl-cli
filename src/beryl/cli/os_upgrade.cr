require "option_parser"
require "../apply"
require "../freebsd_release"
require "./account_utils"
require "./info"   # scoped_hosts (portée société/domaine/host)
require "./unlock" # déverrouillage auto post-reboot (hosts chiffrés)

# `beryl os-upgrade <host> [--to X.Y] [--apply] [--reboot]` — met à jour le
# SYSTÈME FreeBSD (≠ `upgrade` = paquets seuls). CONSCIENT DU TYPE D'INSTALL :
#
#   * PKGBASE (base en paquets, dépôt `FreeBSD-base`) — le cas beryl par défaut :
#     montée de release = REPOINTER le dépôt `base_release_<minor>` puis
#     `pkg upgrade -r FreeBSD-base` + reboot. Pas de fusion /etc interactive.
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
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl os-upgrade <host|société|domaine> [--to X.Y] [--apply] [--reboot]\n" \
                 "        Met à jour le système FreeBSD sur toute la portée. DRY-RUN par défaut."
      p.on("--to=VERSION", "Release cible X.Y (défaut : dernière de la branche courante)") { |v| to = v }
      p.on("--apply", "Exécute (repoint + pkg upgrade). S'arrête AVANT le reboot sauf --reboot") { apply = true }
      p.on("--reboot", "Avec --apply : reboot + attente du retour SSH (pour enchaîner une flotte)") { reboot = true }
      p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    # Périmètre : host, société ou domaine (comme `beryl update`/`upgrade`).
    scope = positional.first? || account_hint || domain_hint
    unless scope
      STDERR.puts "beryl : périmètre non précisé. USAGE : beryl os-upgrade <host|société|domaine> [--to X.Y] [--apply] [--reboot]"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    hosts = Beryl::CLI::Info.scoped_hosts(root, scope).select { |h| h.os == "freebsd" && !h.virtual }
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
    log "périmètre #{scope} : #{hosts.size} hôtes → #{hosts.map(&.fqdn).join(", ")}" if hosts.size > 1

    # Séquentiel : avec --reboot chaque hôte est rebooté et attendu AVANT le
    # suivant (montée de flotte sûre). Un hôte en échec n'arrête pas les autres.
    rc = EXIT_OK
    hosts.each do |host|
      r = upgrade_one(config_root, host, to, apply, reboot)
      rc = r unless r == EXIT_OK
    end
    rc
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_FAILED
  end

  # Montée d'UN hôte (dry-run par défaut). Chaque `return` est LOCAL à l'hôte
  # (méthode appelée en boucle par `run` pour une portée société/domaine).
  private def self.upgrade_one(config_root : String, host : Beryl::Config::ResolvedHost, to : String?, apply : Bool, reboot : Bool) : Int32
    unless host.os == "freebsd"
      STDERR.puts "beryl : os-upgrade = FreeBSD uniquement (host : #{host.os})."
      return EXIT_USAGE
    end
    if apply && host.protected?
      log "#{host.fqdn} : protégé (protected: true) → --apply REFUSÉ (dry-run uniquement)."
      return EXIT_OK
    end

    # Trouve le user qui répond (cascade connect_users : admin, deploy… puis
    # root), avec la version déjà lue. Puis SudoShell sur CE user.
    user, probe = probe_reachable(host)
    cur_raw = probe.stdout.strip
    cur = parse_version(cur_raw)
    unless user && cur
      STDERR.puts "beryl : #{host.fqdn} injoignable en SSH (users tentés : #{host.connect_users.join(", ")})."
      STDERR.puts "        #{host.ssh_host}:#{host.port} → #{compact_ssh_error(probe.stderr, probe.exit_code)} (exit #{probe.exit_code})"
      if d = probe.stderr.strip.lines.first?
        STDERR.puts "        détail : #{d}"
      end
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
      return EXIT_USAGE
    end

    ck = {cur_major, cur_minor}
    tk = Beryl::FreebsdRelease.version_key(target)
    log "#{host.fqdn} : #{cur_raw} → cible #{target}-RELEASE"
    if tk <= ck && to.nil?
      log "déjà sur #{cur_major}.#{cur_minor} (≥ #{target}) — rien à faire."
      return EXIT_OK
    end

    # Détection pkgbase : un système pkgbase a le paquet FreeBSD-runtime installé.
    pkgbase = shell.exec("pkg query %n FreeBSD-runtime", raise_on_error: false).stdout.strip == "FreeBSD-runtime"

    if pkgbase
      pkgbase_upgrade(config_root, shell, host, cur_major, cur_minor, target, tk, ck, apply, reboot)
    else
      freebsd_update_flow(shell, host, cur_raw, target, tk, ck, apply)
    end
  rescue ex
    STDERR.puts "beryl : #{host.fqdn} — erreur inattendue : #{ex.class}: #{ex.message}"
    EXIT_FAILED
  end

  NOTE_UP = "montée dispo"
  NOTE_OK = "à jour"

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
    ready = states.count { |s| s.note.starts_with?(NOTE_OK) }
    ko = states.count { |s| !s.ok }
    puts ""
    puts "Résumé : #{up} à monter · #{ready} à jour · #{ko} injoignables (sur #{states.size})."
    puts "→ détail : `beryl os-upgrade <host>` ; monter : `beryl os-upgrade <host> --apply [--reboot]`."
    EXIT_OK
  end

  # Lecture SEULE (pas de sudo) de l'état d'un hôte, pour le résumé de flotte.
  private def self.probe_one(host, to) : HostState
    user, probe = probe_reachable(host)
    cur_raw = probe.stdout.strip
    cur = parse_version(cur_raw)
    unless user && cur
      return HostState.new(host.fqdn, false, nil, nil, "SSH KO : #{compact_ssh_error(probe.stderr, probe.exit_code)}")
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
    HostState.new(host.fqdn, true, cur_raw, target, "#{up_needed ? NOTE_UP : NOTE_OK}#{via}")
  rescue ex
    HostState.new(host.fqdn, false, nil, nil, "erreur : #{ex.message}")
  end

  # Tente les users de connexion en cascade (`connect_users`) et renvoie le
  # PREMIER qui répond, avec le `freebsd-version -r`. S'arrête dès une erreur
  # RÉSEAU (timeout/refus/DNS) : inutile de tester d'autres users sur un hôte
  # injoignable. Renvoie {user_ok | nil, dernier_résultat}.
  private def self.probe_reachable(host) : {String?, SSH::Result}
    last = SSH::Result.new("", "", 255)
    host.connect_users.each do |u|
      res = Beryl::Apply::SshShell.new(host.connection(u)).exec("freebsd-version -r", raise_on_error: false)
      return {u, res} if res.success? && !res.stdout.strip.empty?
      last = res
      break if network_error?(res.stderr)
    end
    {nil, last}
  end

  private def self.network_error?(stderr : String) : Bool
    s = stderr.downcase
    s.includes?("timed out") || s.includes?("timeout") || s.includes?("banner exchange") ||
      s.includes?("connection refused") || s.includes?("could not resolve") || s.includes?("name or service")
  end

  # Motif SSH lisible en une ligne (sans le préfixe `user@host:`).
  private def self.compact_ssh_error(stderr : String, exit_code : Int32) : String
    s = stderr.downcase
    return "clé refusée (publickey)" if s.includes?("permission denied")
    return "timeout / injoignable" if s.includes?("timed out") || s.includes?("timeout") || s.includes?("banner exchange")
    return "hôte inconnu (DNS)" if s.includes?("could not resolve") || s.includes?("name or service")
    return "connexion refusée" if s.includes?("connection refused")
    "SSH exit #{exit_code}"
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

    if tk == ck
      # Même release : pas de repoint, juste d'éventuels errata.
      cmd = apply ? "pkg upgrade -y -r #{BASE_REPO}" : "pkg upgrade -n -r #{BASE_REPO}"
      log "#{host.fqdn} : pkgbase, même release → #{cmd}"
      res = shell.exec("#{IGNORE_OSV} pkg update -f -r #{BASE_REPO} ; #{IGNORE_OSV} #{cmd}", raise_on_error: false)
      puts res.stdout.strip
      return EXIT_OK
    end

    # Localise le fichier de conf du dépôt FreeBSD-base (beryl : /usr/local/etc/
    # pkg/repos/FreeBSD-base.conf ; on cherche large). SudoShell → `sh -c`.
    conf = shell.exec("grep -rl base_release /usr/local/etc/pkg/repos /etc/pkg 2>/dev/null | head -1", raise_on_error: false).stdout.strip
    if conf.empty?
      STDERR.puts "beryl : conf du dépôt FreeBSD-base introuvable (base_release) sur #{host.fqdn}."
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
      return EXIT_FAILED
    end

    log "#{host.fqdn} : pkg upgrade -y -r #{BASE_REPO}…"
    up = shell.exec("#{IGNORE_OSV} pkg upgrade -y -r #{BASE_REPO}", raise_on_error: false)
    puts up.stdout.strip
    unless up.success?
      STDERR.puts "beryl : pkg upgrade a échoué — #{up.stderr.strip.lines.last?}"
      return EXIT_FAILED
    end

    reconfigure_base_services(shell, host)

    # Thin jails : le base host vient d'être patché, MAIS le base partagé des
    # jails (/jails/.base) est distinct → il faut le rafraîchir aussi, puis
    # redémarrer les jails (elles le montent en nullfs RO).
    if shell.exec("test -d /jails/.base", raise_on_error: false).success?
      log "#{host.fqdn} : des thin jails partagent /jails/.base → rafraîchissez-le " \
          "(`beryl apply #{host.short_name} jail-base`) puis redémarrez les jails (`service jail restart`)."
    end

    unless reboot
      log "#{host.fqdn} : base #{target} installée. REBOOTEZ pour démarrer dessus : `shutdown -r now`."
      return EXIT_OK
    end

    log "#{host.fqdn} : reboot…"
    shell.exec("shutdown -r now", raise_on_error: false)
    if wait_back(host)
      new = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection))
        .exec("freebsd-version -r", raise_on_error: false).stdout.strip
      log "#{host.fqdn} : revenu — #{new}"
      # Host chiffré : il revient VERROUILLÉ (datasets non montés) → déverrouille
      # pour qu'il soit opérationnel (sinon /home, /usr/local/etc absents).
      if host.encrypted?
        log "#{host.fqdn} : chiffré → déverrouillage post-reboot (beryl unlock)…"
        Beryl::CLI::Unlock.run(config_root, [host.fqdn])
      end
      EXIT_OK
    else
      STDERR.puts "beryl : #{host.fqdn} n'est pas revenu en SSH après reboot (vérifiez via la console/IPMI)."
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
  private def self.freebsd_update_flow(shell, host, cur_raw, target, tk, ck, apply) : Int32
    if tk == ck
      if apply
        log "#{host.fqdn} : freebsd-update fetch install (correctifs)…"
        res = shell.exec("freebsd-update --not-running-from-cron fetch install", raise_on_error: false)
        puts res.stdout.strip unless res.stdout.strip.empty?
        return EXIT_FAILED unless res.success?
        log "#{host.fqdn} : correctifs appliqués. Rebootez si nouveau noyau (`shutdown -r now`)."
        return EXIT_OK
      end
      puts ""
      puts "Correctifs FreeBSD (#{target}-RELEASE) — runbook :"
      puts "  freebsd-update fetch install"
      puts "→ `beryl os-upgrade #{host.short_name} --apply` exécute ces correctifs."
      return EXIT_OK
    end

    log "montée de release : --apply non automatisé pour freebsd-update (reboots + fusions interactives)." if apply
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
