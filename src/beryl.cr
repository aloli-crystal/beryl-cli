require "ssh"
require "./beryl/version"
require "./beryl/xdg"
require "./beryl/i18n"
require "./beryl/config"
require "./beryl/bootstrap"
require "./beryl/providers"
require "./beryl/encryption"

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

  # Formate une cible SSH pour les logs de façon uniforme. Trois cas :
  #
  # * Pas de divergence entre fqdn et ssh_host :
  #     `rails01.aloli.net`
  #
  # * Provider hébergeur qui impose un nom différent (typiquement OVH
  #   `ovh.service_name`). On annonce le couple « FQDN logique côté
  #   provider » :
  #     `rails01.aloli.net (= ns1234.ip-51-83-6.eu côté ovh)`
  #
  # * Override `ssh_host:` explicite côté YAML — l'opérateur a posé
  #   une valeur (test local, VPN, alias DNS interne). Pas de
  #   mention de provider, qui serait sémantiquement faux pour
  #   `provider: local` ou un provider sans notion de nom
  #   hébergeur :
  #     `clientvm.test (via 127.0.0.1)`
  def self.format_ssh_target(host : Beryl::Config::ResolvedHost) : String
    if host.ssh_host_is_provider_name?
      "#{host.fqdn} (= #{host.ssh_host} côté #{host.provider})"
    elsif host.ssh_host_explicit? && host.ssh_host != host.fqdn
      "#{host.fqdn} (via #{host.ssh_host})"
    else
      host.fqdn
    end
  end

  # Construit la commande shell à afficher à la fin d'un `--dry-run`
  # pour que l'utilisateur voie exactement quoi relancer (copy-paste
  # friendly). Retire les flags `--dry-run` / `-n` des args originaux
  # et concatène d'éventuels arguments additionnels (ex: `--hostname`
  # pour scan, qui a pu être résolu interactivement pendant le dry-run).
  #
  # Philippe 23 avril 2026 : option B — zéro automatisme, zéro clic
  # enchaîné, l'utilisateur lit et relance lui-même.
  def self.rerun_hint(
    cmd : String,
    args : Array(String),
    extras : Array(String) = [] of String,
    replace_host : {String, String}? = nil,
  ) : String
    filtered = args.reject { |a| a == "--dry-run" || a == "-n" }
    # Remplace le positional host par sa forme path-like complète
    # `<société>/<fqdn>` — utile pour que la suggestion fonctionne
    # même depuis un autre contexte (autre société avec collision de
    # nom, inventaire multi-tenants, etc.).
    if replace = replace_host
      original, normalized = replace
      filtered = filtered.map { |a| a == original ? normalized : a }
    end
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
    ack = Channel(Nil).new
    # Ticker : update le compteur chaque seconde jusqu'à recevoir
    # `done`. Envoie ensuite `ack` pour que l'appelant sache qu'on
    # a fini d'écrire sur STDERR (évite la race du printf final vs
    # le dernier tick, qui provoquait un chevauchement visuel
    # entre deux log_step successifs).
    spawn do
      loop do
        select
        when done.receive?
          ack.send(nil)
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
      done.send(nil)
      ack.receive
      elapsed = (Time.instant - start).total_seconds.to_i
      STDERR.printf("\r%s%s  [%4ds]\n", line, pad, elapsed)
      STDERR.flush
      result
    ensure
      unless success
        # yield a levé. Stopper proprement le ticker d'abord puis
        # afficher la ligne finale avec ✗. Double send protégé par
        # un channel non-bufferisé : si le success branch a déjà
        # envoyé `done`, on arrive ici sans refaire l'opération.
        begin
          done.send(nil)
          ack.receive
        rescue Channel::ClosedError
          # déjà envoyé
        end
        elapsed = (Time.instant - start).total_seconds.to_i
        STDERR.printf("\r%s%s  [%4ds] ✗\n", line, pad, elapsed)
        STDERR.flush
      end
    end
  end
end
