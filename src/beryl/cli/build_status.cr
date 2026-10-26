require "option_parser"
require "./scope"
require "./option_errors"
require "../apply"
require "../build_report"
require "./account_utils"
require "./ssh_probe"

# `beryl build-status <hôte>` — état LISIBLE des builds de paquets d'un
# builder poudriere géré par la primitive `poudriere-build` : en cours /
# succès / échec / jamais construit, compteurs, paquets en construction,
# ÉCHECS en tête (avec le journal poudriere de chaque paquet), paquets
# construits triés par durée, dernier build réussi et commits des overlays.
#
# LECTURE SEULE, une connexion SSH par lecture : un script composé
# (`Beryl::BuildReport.remote_script`) rassemble dates des fichiers,
# `.overlays`, lignes utiles du journal et `poudriere status`. Escalade sudo
# comme `apply` (les fichiers du dépôt appartiennent à root).
#
# Remplace la commande tapée à la main :
#
#     ssh admin@pkg.example.net sudo sh -c "'cd /usr/local/poudriere/data/packages && ls -l .beryl-build-15.*; …'"
#
# Codes de sortie : 0 succès / en cours / jamais construit, 1 dernier build
# en échec, 2 SSH ou usage.
module Beryl::CLI::BuildStatus
  EXIT_OK     = 0
  EXIT_FAILED = 1
  EXIT_USAGE  = 2

  # Intervalle de rafraîchissement de `--follow`.
  FOLLOW_INTERVAL = 30.seconds

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    major : String? = nil
    pkgdir = Beryl::Apply::PoudriereBuild::DEFAULT_PKGDIR
    all = false
    follow = false
    json = false
    sort = "duration"
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl build-status <hôte> [--major N] [--all] [--sort duration|name] [--follow] [--json]\n" \
                 "        État des builds de paquets poudriere (primitive poudriere-build) d'un builder.\n" \
                 "        Lecture seule. Ex. : beryl build-status pkg.example.net --follow\n" \
                 "        Sortie : 0 succès / en cours, 1 dernier build en échec, 2 SSH / usage."
      p.on("--major=N", "Majeur FreeBSD (défaut : tous ceux trouvés, .beryl-build-*)") { |v| major = v }
      p.on("--all", "Liste complète des paquets (défaut : les #{Beryl::BuildReport::TOP} plus longs)") { all = true }
      p.on("--sort=ORDRE", "Tri des paquets construits : duration (défaut, plus longs d'abord) ou name") { |v| sort = v }
      p.on("--follow", "Rafraîchit toutes les #{FOLLOW_INTERVAL.total_seconds.to_i} s jusqu'à la fin du build, puis sort (0 succès, 1 échec)") { follow = true }
      p.on("--json", "Sortie machine (JSON)") { json = true }
      p.on("--pkgdir=DIR", "Répertoire des paquets (défaut : #{Beryl::Apply::PoudriereBuild::DEFAULT_PKGDIR})") { |v| pkgdir = v }
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    # Copie AVANT l'analyse : `parse` retire les options reconnues de `args`
    # (`--apply`…), que le rejeu par serveur doit garder.
    all_args = args.dup
    Beryl::CLI.handle_option_errors(parser).parse(args)
    # Plusieurs serveurs (liste, groupe, domaine, société) : rejouée pour chacun.
    if code = Beryl::CLI::Scope.fan_out("build-status", config_root, all_args, positional) { |a| run(config_root, a) }
      return code
    end

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl build-status <hôte>"
      return EXIT_USAGE
    end
    if (m = major) && !m.matches?(/\A\d+\z/)
      STDERR.puts "beryl : --major attend un numéro de version majeure (ex. 15), reçu #{m.inspect}."
      return EXIT_USAGE
    end
    unless {"duration", "name"}.includes?(sort)
      STDERR.puts "beryl : --sort attend duration ou name, reçu #{sort.inspect}."
      return EXIT_USAGE
    end

    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]
    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(parsed[:host], account_hint: account_hint, domain_hint: domain_hint)
    log "lecture des builds sur #{Beryl.format_ssh_target(host)}"

    user, probe = Beryl::CLI::SshProbe.reachable(host, "echo ok")
    unless user
      STDERR.puts "beryl : #{host.fqdn} injoignable en SSH (users tentés : #{host.connect_users.join(", ")}) — " \
                  "#{Beryl::CLI::SshProbe.compact_error(probe.stderr, probe.exit_code)}"
      return EXIT_USAGE
    end
    shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(host.connection(user)))

    loop do
      # --json --follow : progression en texte sur stderr, JSON final seul sur stdout.
      code, reports = show(shell, host.fqdn, pkgdir, major, all, sort, json && !follow, json && follow ? STDERR : STDOUT)
      return code if code == EXIT_USAGE
      unless follow && reports.any?(&.running?)
        puts Beryl::BuildReport.to_json(host.fqdn, pkgdir, reports) if json && follow
        return code
      end
      log "build en cours — prochaine lecture dans #{FOLLOW_INTERVAL.total_seconds.to_i} s (Ctrl-C pour quitter)"
      sleep FOLLOW_INTERVAL
    end
  rescue ex : OptionParser::Exception
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : SSH a échoué — #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_USAGE
  end

  # Une lecture + affichage (texte, ou JSON si `json`). Renvoie le code de
  # sortie et les rapports (pour `--follow`). Testable avec un `FakeShell`.
  def self.show(shell : Beryl::Apply::Shell, label : String, pkgdir : String, major : String?,
                all : Bool, sort : String, json : Bool, io : IO) : {Int32, Array(Beryl::BuildReport::Report)}
    res = shell.exec(Beryl::BuildReport.remote_script(pkgdir, major), raise_on_error: false)
    remote = Beryl::BuildReport.parse_remote(res.stdout)
    if !res.success? && res.stdout.strip.empty?
      STDERR.puts "beryl : lecture impossible sur #{label} (exit #{res.exit_code}) : #{res.stderr.strip.lines.first? || "pas de message"}"
      return {EXIT_USAGE, [] of Beryl::BuildReport::Report}
    end
    if remote.pkgdir_missing
      STDERR.puts "beryl : #{pkgdir} absent sur #{label} (pas un builder poudriere ? voir --pkgdir)."
      return {EXIT_USAGE, [] of Beryl::BuildReport::Report}
    end
    reports = Beryl::BuildReport.reports(remote, major, pkgdir)
    if json
      io.puts Beryl::BuildReport.to_json(label, pkgdir, reports)
    else
      io.print Beryl::BuildReport.render(label, pkgdir, reports, all, sort)
    end
    {Beryl::BuildReport.exit_code(reports), reports}
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl build-status] #{message}"
  end
end
