require "./beryl/version"
require "./beryl/i18n"
require "./beryl/ssh"
require "./beryl/config"
require "./beryl/bootstrap"
require "./beryl/providers"

module Beryl
  # Largeur cible en caractères pour aligner le compteur `[NNNs]` en fin
  # de ligne sur toutes les sous-commandes (rescue, bootstrap, …). Le
  # padding se fait par `String#size` pour éviter que `printf %-Ns`
  # (octets UTF-8) fausse l'alignement des tirets cadratins.
  STEP_LINE_WIDTH = 117

  # Horodatage sensible à la locale, utilisé par les logs de toutes les
  # sous-commandes. On détecte uniquement le français (LANG/LC_TIME qui
  # commence par `fr`) et on retombe sur l'ISO 8601 sinon : deux formats
  # suffisent pour l'usage de beryl, pas de dépendance à un moteur i18n.
  #
  # * `fr` → `20/04/2026 21h35m12`
  # * autre → `2026-04-20 21:35:12`
  def self.format_timestamp(t : Time) : String
    if french_locale?
      t.to_s("%d/%m/%Y %Hh%Mm%S")
    else
      t.to_s("%Y-%m-%d %H:%M:%S")
    end
  end

  private def self.french_locale? : Bool
    {"LC_ALL", "LC_TIME", "LANG"}.each do |var|
      v = ENV[var]?
      next if v.nil? || v.empty?
      return v.starts_with?("fr")
    end
    false
  end

  # Pade une ligne de log jusqu'à `width` caractères (par défaut
  # `STEP_LINE_WIDTH`) pour aligner le compteur `[NNNs]` à droite.
  # Utilise `String#size` (caractères) et non `String#bytesize`, sinon
  # les tirets cadratins UTF-8 faussent l'alignement.
  def self.pad_to(line : String, width : Int32 = STEP_LINE_WIDTH) : String
    needed = width - line.size
    needed > 0 ? " " * needed : ""
  end

  # Nettoie ~/.ssh/known_hosts de toute entrée pour `host` (et la
  # variante `[host]:port` si port != 22). Silencieux si l'entrée
  # n'existe pas.
  def self.clean_known_hosts(host : String, port : Int32 = 22) : Nil
    Process.run("ssh-keygen", ["-R", host],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    if port != 22
      Process.run("ssh-keygen", ["-R", "[#{host}]:#{port}"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    end
  end

  # Nettoie ~/.ssh/known_hosts pour les DEUX noms d'un host résolu :
  # son FQDN logique et son nom côté hébergeur (quand ils diffèrent).
  # Évite un futur « REMOTE HOST IDENTIFICATION HAS CHANGED » quel que
  # soit le nom que l'opérateur utilise ensuite.
  def self.clean_known_hosts_for(host : Beryl::Config::ResolvedHost) : Nil
    clean_known_hosts(host.fqdn, host.port)
    clean_known_hosts(host.ssh_host, host.port) if host.ssh_host_is_provider_name?
  end

  # Formate une cible SSH pour les logs de façon uniforme :
  # `rails01.aloli.net` seul quand le nom SSH == FQDN,
  # `rails01.aloli.net (= ns1234.ip-... côté ovh)` sinon.
  def self.format_ssh_target(host : Beryl::Config::ResolvedHost) : String
    if host.ssh_host_is_provider_name?
      "#{host.fqdn} (= #{host.ssh_host} côté #{host.provider})"
    else
      host.fqdn
    end
  end

  # Tente d'ouvrir une URL dans le navigateur par défaut de
  # l'utilisateur. Utilise `open` sur macOS, `xdg-open` sur Linux.
  # Silencieux si ça échoue : l'URL est supposée être déjà affichée
  # ailleurs (log stderr), l'utilisateur peut copier-coller.
  def self.open_in_browser(url : String) : Nil
    opener = {% if flag?(:darwin) %}
               "open"
             {% else %}
               "xdg-open"
             {% end %}
    Process.run(opener, [url],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
  rescue
    # Silencieux : beryl a déjà affiché l'URL dans stderr.
  end

  # Construit la commande shell à afficher à la fin d'un `--dry-run`
  # pour que l'utilisateur voie exactement quoi relancer (copy-paste
  # friendly). Retire les flags `--dry-run` / `-n` des args originaux
  # et concatène d'éventuels arguments additionnels (ex: `--hostname`
  # pour scan, qui a pu être résolu interactivement pendant le dry-run).
  #
  # Philippe 23 avril 2026 : option B — zéro automatisme, zéro clic
  # enchaîné, l'utilisateur lit et relance lui-même.
  def self.rerun_hint(cmd : String, args : Array(String), extras : Array(String) = [] of String) : String
    filtered = args.reject { |a| a == "--dry-run" || a == "-n" }
    (["beryl", cmd] + filtered + extras).join(" ")
  end

  # Affiche une ligne de log avec un compteur `[NNNs]` en fin de ligne,
  # rafraîchi chaque seconde par un fiber pour montrer que le process
  # est vivant pendant une opération longue. La ligne est tenue en
  # place (retour chariot `\r`) jusqu'à ce que le bloc retourne, puis
  # saute à la ligne suivante avec le temps final figé.
  #
  # Sur exception, on affiche `✗` + le temps final avant de laisser
  # l'exception remonter. Le fiber est toujours libéré (`ensure`).
  #
  # Utilisé par toutes les sous-commandes pour unifier la progression
  # visuelle :
  #   - `beryl rescue` : polling task OVH + attente SSH
  #   - `beryl boot-hd` : idem
  #   - `beryl bootstrap` : étapes 1-6 du flux mfsBSD-in-QEMU
  #
  # Exemple :
  #   Beryl.log_step("beryl rescue", "OVH : tâche #12345 en doing") do
  #     # ... long polling ...
  #   end
  def self.log_step(prefix : String, label : String, & : -> T) : T forall T
    line = "[#{format_timestamp(Time.local)}] [#{prefix}] #{label}"
    pad = pad_to(line)
    STDERR.print "#{line}#{pad}  [   0s]"
    STDERR.flush
    start = Time.instant
    done = Channel(Nil).new
    spawn do
      loop do
        select
        when done.receive?
          break
        when timeout(1.second)
          elapsed = (Time.instant - start).total_seconds.to_i
          STDERR.printf("\r%s%s  [%4ds]", line, pad, elapsed)
          STDERR.flush
        end
      end
    end
    success = false
    begin
      result = yield
      success = true
      elapsed = (Time.instant - start).total_seconds.to_i
      STDERR.printf("\r%s%s  [%4ds]\n", line, pad, elapsed)
      result
    ensure
      done.send(nil)
      unless success
        elapsed = (Time.instant - start).total_seconds.to_i
        STDERR.printf("\r%s%s  [%4ds] ✗\n", line, pad, elapsed)
      end
    end
  end
end
