require "option_parser"
require "../apply"
require "../freebsd_release"
require "./account_utils"

# `beryl os-upgrade <host> [--to X.Y] [--apply]` — met à jour le SYSTÈME FreeBSD
# (≠ `upgrade` qui ne touche QUE les paquets). Deux cas :
#
#   * CORRECTIFS (même release, -pN) : `freebsd-update fetch install` —
#     non-interactif, automatisable. `--apply` le fait (reboot éventuel signalé).
#   * MONTÉE DE RELEASE (X.Y → X.Z) : multi-étapes AVEC REBOOTS + fusions de
#     config interactives + recompilation pkg (ABI). TROP risqué à automatiser
#     d'un coup → beryl AFFICHE le runbook précis ; `--apply` le REFUSE.
#
# DRY-RUN par défaut (affiche le plan/runbook, ne touche à rien). `--apply` pour
# exécuter (correctifs uniquement). Un host `protected: true` refuse `--apply`.
module Beryl::CLI::OsUpgrade
  EXIT_OK     = 0
  EXIT_USAGE  = 1
  EXIT_FAILED = 2

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    to : String? = nil
    apply = false
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl os-upgrade <host> [--to X.Y] [--apply]\n" \
                 "        Met à jour le système FreeBSD. DRY-RUN par défaut ; --apply exécute\n" \
                 "        (correctifs uniquement ; une montée de RELEASE affiche le runbook)."
      p.on("--to=VERSION", "Release cible X.Y (défaut : dernière de la branche courante)") { |v| to = v }
      p.on("--apply", "Exécute les CORRECTIFS (sinon : dry-run / runbook)") { apply = true }
      p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl os-upgrade <host> [--to X.Y] [--apply]"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(parsed[:host], account_hint: account_hint, domain_hint: domain_hint)
    unless host.os == "freebsd"
      STDERR.puts "beryl : os-upgrade = FreeBSD uniquement (host : #{host.os})."
      return EXIT_USAGE
    end

    shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection))

    # Version courante (userland en cours d'exécution).
    cur_raw = shell.exec("freebsd-version -r", raise_on_error: false).stdout.strip
    cur = parse_version(cur_raw)
    unless cur
      STDERR.puts "beryl : impossible de lire la version FreeBSD de #{host.fqdn} (`freebsd-version -r` → #{cur_raw.inspect})."
      return EXIT_FAILED
    end
    cur_major, cur_minor, _ = cur

    # Release cible : --to, sinon dernière de la branche courante (réseau).
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
    tk = Beryl::FreebsdRelease.version_key(target)
    ck = {cur_major, cur_minor}

    log "#{host.fqdn} : en cours #{cur_raw} → cible #{target}-RELEASE"

    if tk < ck
      log "déjà sur une release ≥ #{target} — rien à faire."
      return EXIT_OK
    end

    if tk == ck
      # Même release : seuls des CORRECTIFS (-pN) peuvent manquer.
      if apply
        return apply_patches(shell, host)
      else
        puts ""
        puts "Correctifs FreeBSD (#{target}-RELEASE) — runbook :"
        puts "  freebsd-update fetch install     # applique les correctifs de sécurité"
        puts "  # reboot SEULEMENT si un nouveau noyau a été installé"
        puts ""
        puts "→ `beryl os-upgrade #{host.short_name} --apply` exécute ces correctifs."
        return EXIT_OK
      end
    end

    # tk > ck : MONTÉE DE RELEASE.
    if apply
      log "montée de release #{cur_major}.#{cur_minor} → #{target} : --apply REFUSÉ (multi-étapes + reboots + fusions interactives)."
    end
    print_release_runbook(host, cur_raw, target)
    EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_FAILED
  end

  # Applique les correctifs (cas sûr, non-interactif). Reboot laissé à l'opérateur.
  private def self.apply_patches(shell, host : Beryl::Config::ResolvedHost) : Int32
    if host.protected?
      log "#{host.fqdn} : protégé (protected: true) → --apply REFUSÉ."
      return EXIT_OK
    end
    log "#{host.fqdn} : freebsd-update fetch install (correctifs)…"
    res = shell.exec("freebsd-update --not-running-from-cron fetch install", raise_on_error: false)
    puts res.stdout.strip unless res.stdout.strip.empty?
    unless res.success?
      STDERR.puts "beryl : freebsd-update a échoué — #{res.stderr.strip.lines.last?}"
      return EXIT_FAILED
    end
    log "#{host.fqdn} : correctifs appliqués. Rebootez si un nouveau noyau a été installé (`shutdown -r now`)."
    EXIT_OK
  end

  # Runbook d'une montée de release (NON automatisé : reboots + interactif).
  private def self.print_release_runbook(host : Beryl::Config::ResolvedHost, current : String, target : String) : Nil
    h = host.short_name
    puts ""
    puts "Montée de RELEASE #{current} → #{target}-RELEASE sur #{host.fqdn}"
    puts "─" * 64
    puts "⚠️  Multi-étapes AVEC REBOOTS + fusions de config interactives — à faire"
    puts "    à la main (ou supervisé), PAS en masse. Sauvegarde/snapshot d'abord."
    puts ""
    puts "  freebsd-update -r #{target}-RELEASE upgrade   # télécharge + fusionne /etc (interactif)"
    puts "  freebsd-update install                        # 1/ installe le nouveau noyau"
    puts "  shutdown -r now                               # reboot sur le nouveau noyau"
    puts "  freebsd-update install                        # 2/ installe le nouveau userland"
    puts "  pkg upgrade -f                                # recompile les paquets pour le nouvel ABI"
    puts "  shutdown -r now                               # reboot"
    puts "  freebsd-update install                        # 3/ finalisation"
    puts ""
    puts "Doc : https://docs.freebsd.org/en/books/handbook/cutting-edge/#freebsdupdate-upgrade"
    puts "(Un `beryl os-upgrade` par étapes, qui survit aux reboots, reste à faire.)"
  end

  # Parse « 15.0-RELEASE-p10 » → {major, minor, patch?}. nil si illisible.
  def self.parse_version(s : String) : {Int32, Int32, Int32?}?
    m = s.match(/(\d+)\.(\d+)(?:-RELEASE)?(?:-p(\d+))?/)
    return nil unless m
    {m[1].to_i, m[2].to_i, m[3]?.try(&.to_i)}
  end

  private def self.log(msg : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl os-upgrade] #{msg}"
  end
end
