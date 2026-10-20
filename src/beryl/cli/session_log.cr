require "../xdg"

# Journal de session : par défaut, toute commande beryl qui agit sur le parc
# écrit sa sortie (et ce qui s'affiche dans le terminal : questions,
# réponses, sortie des commandes distantes) dans un fichier de
# `<état>/logs/` (`~/.local/state/beryl/logs/`, cf. `Beryl::Xdg.state_dir`).
# `--no-log`, n'importe où sur la ligne, désactive le journal.
#
# Mécanique : beryl se RELANCE lui-même, le parent ne fait qu'enregistrer.
# * Terminal interactif : sous `script(1)`, qui garde un vrai terminal à
#   l'enfant (questions, couleurs, `tty?`, ssh -t intacts) et enregistre la
#   session dans le fichier.
# * Sortie redirigée (tube, cron, appli) : l'enfant écrit dans deux tubes
#   que le parent recopie à la fois à l'écran et dans le fichier.
# L'enfant reçoit `BERYL_SESSION_LOG` (chemin du journal) : il ne se relance
# pas une seconde fois, et ses propres enfants (tâches détachées) non plus.
#
# Jamais journalisées : l'aide, la lecture locale de la config, et surtout
# les commandes où l'on SAISIT des secrets (coffre, clés d'API) — un
# journal ne doit pas devenir une copie du coffre. Fichiers 0600 dans un
# dossier 0700 ; journaux de plus de `KEEP_DAYS` jours effacés à chaque
# nouvelle session journalisée.
module Beryl::CLI::SessionLog
  extend self

  FLAG       = "--no-log"
  ENV_ACTIVE = "BERYL_SESSION_LOG"
  KEEP_DAYS  = 90

  # Sous-commandes (noms longs) jamais journalisées.
  SKIP = {"add-domain", "add-provider", "env", "fmt", "help", "init", "list-hosts", "show", "version"}

  # Retire `--no-log` d'argv (où qu'il soit). Renvoie {argv nettoyé, journal
  # refusé ?}. Pur.
  def strip_flag(argv : Array(String)) : {Array(String), Bool}
    {argv.reject(FLAG), argv.includes?(FLAG)}
  end

  # La commande doit-elle être journalisée ? `active` : déjà sous journal
  # (variable `BERYL_SESSION_LOG` héritée). Pur.
  def wanted?(subcommand : String?, sub_args : Array(String), no_log : Bool, active : Bool) : Bool
    return false if no_log || active
    return false if subcommand.nil? || SKIP.includes?(subcommand)
    # Aide d'une sous-commande ; orchestrateur d'une tâche détachée (qui a
    # déjà son journal de tâche).
    !sub_args.any? { |a| a == "-h" || a == "--help" || a.starts_with?("--job") }
  end

  def dir : String
    File.join(Beryl::Xdg.state_dir, "logs")
  end

  # Sous-commandes en essai à blanc par défaut (`--apply` pour agir).
  DRY_RUN_BY_DEFAULT = {"apply", "boot-hd", "bootstrap", "dns", "dns-alias", "dns-record", "headscale-authkey",
                        "lock", "os-upgrade", "pg-upgrade", "reboot", "rescue", "scaleway-reinstall", "scan",
                        "tang-enroll", "unlock", "upgrade", "wipe"}

  # Libellé de la commande dans le nom du journal : `upgrade-dry-run` pour un
  # essai à blanc, `upgrade` quand elle agit (`--apply` ; `-W`/`--write-to`
  # pour scan, qui l'implique), `upgrade-status` pour `--status` (lecture
  # de l'état d'une tâche). Les commandes sans `--apply` gardent leur nom. Pur.
  def label(subcommand : String, sub_args : Array(String)) : String
    return "#{subcommand}-status" if sub_args.includes?("--status")
    return subcommand unless DRY_RUN_BY_DEFAULT.includes?(subcommand)
    acts = sub_args.any? { |a| a == "--apply" || a == "-W" || a.starts_with?("--write-to") }
    acts ? subcommand : "#{subcommand}-dry-run"
  end

  # `<dossier>/2026-10-20--23-40-28--upgrade-dry-run--aloli.net.log` : date,
  # heure, libellé de la commande, puis la portée (premier argument qui n'est
  # pas une option), réduite aux caractères sûrs dans un nom de fichier. Pur.
  def path(subcommand : String, sub_args : Array(String), now : Time, base : String = dir) : String
    name = "#{now.to_s("%Y-%m-%d--%H-%M-%S")}--#{label(subcommand, sub_args)}"
    if scope = sub_args.find { |a| !a.starts_with?("-") }
      safe = scope.gsub(/[^A-Za-z0-9._-]/, "_")[0, 80]
      name = "#{name}--#{safe}" unless safe.empty?
    end
    File.join(base, "#{name}.log")
  end

  # Arguments de `script(1)` : enregistre (en ajout, l'en-tête est déjà
  # écrit) la commande `cmd` dans `log`. BSD et macOS : `script -q -a -F log
  # cmd…` (`-F` : écrit au fil de l'eau, `tail -f` possible ; code de sortie =
  # celui de la commande). Linux (util-linux) : commande en une chaîne `-c`,
  # `-e` pour rendre son code de sortie. Pur.
  def script_args(log : String, cmd : Array(String), linux : Bool = {{ flag?(:linux) }}) : Array(String)
    if linux
      ["-q", "-a", "-e", "-c", cmd.map { |a| Process.quote(a) }.join(" "), log]
    else
      ["-q", "-a", "-F", log] + cmd
    end
  end

  # Relance beryl (`argv` complet, options globales comprises) sous journal
  # et renvoie son code de sortie. Le chemin du journal est rappelé sur
  # stderr à la fin.
  def run(argv : Array(String), log : String) : Int32
    Dir.mkdir_p(File.dirname(log))
    File.chmod(File.dirname(log), 0o700)
    prune(File.dirname(log))
    File.write(log, "# beryl #{Beryl::VERSION} — #{Time.local.to_s("%Y-%m-%d %H:%M:%S %:z")}\n# beryl #{argv.join(" ")}\n\n", perm: 0o600)

    exe = Process.executable_path || PROGRAM_NAME
    env = {ENV_ACTIVE => log}
    script = Process.find_executable("script")
    code =
      if script && STDIN.tty? && STDOUT.tty?
        Process.run(script, script_args(log, [exe] + argv), env: env,
          input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).exit_code
      else
        run_teed(exe, argv, env, log)
      end
    STDERR.puts "journal : #{log}"
    code
  end

  # Sortie redirigée : stdout et stderr de l'enfant recopiés à l'écran ET
  # dans le journal, morceau par morceau (une question sans fin de ligne
  # s'affiche tout de suite).
  private def run_teed(exe : String, argv : Array(String), env : Hash(String, String), log : String) : Int32
    File.open(log, "a") do |file|
      file.sync = true
      process = Process.new(exe, argv, env: env, input: Process::Redirect::Inherit,
        output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
      done = Channel(Nil).new
      {% for pair in [{"output", "STDOUT"}, {"error", "STDERR"}] %}
        spawn do
          buf = Bytes.new(4096)
          while (n = process.{{ pair[0].id }}.read(buf)) > 0
            {{ pair[1].id }}.write(buf[0, n])
            {{ pair[1].id }}.flush
            file.write(buf[0, n])
          end
          done.send(nil)
        end
      {% end %}
      2.times { done.receive }
      process.wait.exit_code
    end
  end

  # Efface les journaux de plus de KEEP_DAYS jours. Jamais bloquant.
  private def prune(base : String) : Nil
    limit = Time.utc - KEEP_DAYS.days
    Dir.glob(File.join(base, "*.log")).each do |f|
      File.delete(f) if File.info(f).modification_time < limit
    end
  rescue
  end
end
