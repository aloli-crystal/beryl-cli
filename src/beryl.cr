require "./beryl/version"
require "./beryl/i18n"
require "./beryl/ssh"
require "./beryl/freebsd_config"
require "./beryl/inventory"
require "./beryl/bootstrap"
# NB : providers.cr require elle-même cli/credentials.cr qui require
# les shards ovh-api/scaleway-api. Chargé en dernier pour être sûr que
# Beryl::Host/Inventory existent avant que les providers s'enregistrent.
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
  # variante `[host]:port` si port != 22). À appeler avant toute
  # sous-commande qui change la clé d'hôte (rescue, bootstrap, boot-hd)
  # pour éviter à l'utilisateur un futur `REMOTE HOST IDENTIFICATION HAS
  # CHANGED`. Silencieux si l'entrée n'existe pas.
  def self.clean_known_hosts(host : String, port : Int32 = 22) : Nil
    Process.run("ssh-keygen", ["-R", host],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
    if port != 22
      Process.run("ssh-keygen", ["-R", "[#{host}]:#{port}"],
        output: Process::Redirect::Close, error: Process::Redirect::Close)
    end
  end

  # Nettoie ~/.ssh/known_hosts pour les DEUX noms potentiels d'un host :
  # son nom logique (ex. `rails01.aloli.fr`) et son nom côté hébergeur
  # (`ovh.service_name` pour OVH). Au fil de rescue/bootstrap/apply,
  # chaque nom peut collecter une clé d'hôte qui ne correspond plus à
  # l'OS en place. Appelé par toutes les sous-commandes qui changent
  # potentiellement la clé d'hôte.
  def self.clean_known_hosts_for(host : Beryl::Host) : Nil
    clean_known_hosts(host.name, host.port)
    clean_known_hosts(host.ssh_host, host.port) if host.ssh_host_is_provider_name?
  end

  # Formate une cible SSH pour les logs, de façon uniforme entre les
  # sous-commandes : « rails01.aloli.fr » seul si le nom logique == le
  # nom SSH, sinon « rails01.aloli.fr (= ns1234.ip-... côté ovh) » pour
  # garder la traçabilité de la correspondance nom custom / nom hébergeur.
  def self.format_ssh_target(host : Beryl::Host) : String
    if host.ssh_host_is_provider_name?
      "#{host.name} (= #{host.ssh_host} côté #{host.provider})"
    else
      host.name
    end
  end
end
