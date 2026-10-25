require "session-log"
require "../xdg"

# Journal de session : par défaut, toute commande beryl qui agit sur le parc
# écrit sa sortie (et ce qui s'affiche dans le terminal : questions,
# réponses, sortie des commandes distantes) dans un fichier de
# `<état>/logs/` (`~/.local/state/beryl/logs/`, cf. `Beryl::Xdg.state_dir`).
# `--no-log`, n'importe où sur la ligne, désactive le journal.
#
# Mécanique (shard `session-log`, extrait d'ici) : beryl se RELANCE lui-même,
# le parent ne fait qu'enregistrer — sous `script(1)` dans un terminal (vrai
# terminal gardé à l'enfant), par recopie écran + fichier sinon. Restent ICI
# les règles propres à beryl : quoi journaliser (`wanted?`), le libellé
# (`label`), la portée dans le nom du fichier et le dossier d'état XDG.
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

  FLAG       = ::SessionLog::FLAG
  ENV_ACTIVE = "BERYL_SESSION_LOG"
  KEEP_DAYS  = 90

  # Sous-commandes (noms longs) jamais journalisées.
  SKIP = {"add-domain", "add-provider", "env", "fmt", "help", "init", "list-hosts", "show", "version"}

  # Retire `--no-log` d'argv (où qu'il soit). Renvoie {argv nettoyé, journal
  # refusé ?}. Pur.
  def strip_flag(argv : Array(String)) : {Array(String), Bool}
    ::SessionLog.strip_flag(argv, FLAG)
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

  # Réglages du shard pour beryl : nom, version, dossier, variable héritée
  # (`BERYL_SESSION_LOG`, lue aussi par `Beryl.log_step`), rétention.
  def config(base : String = dir) : ::SessionLog::Config
    ::SessionLog::Config.new("beryl", Beryl::VERSION, base, env_var: ENV_ACTIVE, keep_days: KEEP_DAYS)
  end

  # Sous-commandes en essai à blanc par défaut (`--apply` pour agir).
  DRY_RUN_BY_DEFAULT = {"apply", "boot-hd", "bootstrap", "dns", "dns-alias", "dns-record", "headscale-authkey",
                        "lock", "monitoring", "os-upgrade", "pg-upgrade", "reboot", "rescue", "scaleway-reinstall", "scan",
                        "tang-enroll", "unlock", "upgrade", "vrack", "wipe"}

  # Libellé de la commande dans le nom du journal : `upgrade-dry-run` pour un
  # essai à blanc, `upgrade` quand elle agit (`--apply` ; `-W`/`--write-to`
  # pour scan, qui l'implique), `upgrade-status` pour `--status` (lecture
  # de l'état d'une tâche). Les commandes sans `--apply` gardent leur nom. Pur.
  def label(subcommand : String, sub_args : Array(String)) : String
    return "#{subcommand}-status" if sub_args.includes?("--status")
    return subcommand unless DRY_RUN_BY_DEFAULT.includes?(subcommand)
    # `monitoring` sans on/off : lecture de l'état, pas un essai à blanc.
    return subcommand if subcommand == "monitoring" && !sub_args.any? { |a| a == "on" || a == "off" }
    # `vrack` : seuls --via/--public/--bastion suivent la règle du dry-run.
    return subcommand if subcommand == "vrack" && !sub_args.any? { |a| a.starts_with?("--via") || a == "--public" || a == "--bastion" }
    acts = sub_args.any? { |a| a == "--apply" || a == "-W" || a.starts_with?("--write-to") }
    acts ? subcommand : "#{subcommand}-dry-run"
  end

  # `<dossier>/2026-10-20--23-40-28--upgrade-dry-run--aloli.net.log` : date,
  # heure, libellé de la commande, puis la portée (premier argument qui n'est
  # pas une option), réduite aux caractères sûrs dans un nom de fichier. Pur.
  def path(subcommand : String, sub_args : Array(String), now : Time, base : String = dir) : String
    ::SessionLog.path(base, label(subcommand, sub_args), sub_args.find { |a| !a.starts_with?("-") }, now)
  end

  # Relance beryl (`argv` complet, options globales comprises) sous journal
  # et renvoie son code de sortie ; le chemin du journal est rappelé sur
  # stderr à la fin (shard `session-log`).
  def run(argv : Array(String), log : String) : Int32
    ::SessionLog.run(config(File.dirname(log)), argv, log)
  end
end
