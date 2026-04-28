require "option_parser"
require "ssh"
require "../config"
require "../encryption"
require "./account_utils"

# Sous-commande `beryl tang-enroll <host>` : bascule un host configuré
# en `mode: tang` (dans le YAML) du chiffrement local (Option C, clé
# sur poste opérateur) vers Tang (Option D, auto-unlock au boot).
#
# Pré-requis :
#
# * Le host a été bootstrapé : ses pools data sont chiffrés en
#   ZFS native avec `keyformat=hex`. La clé locale
#   `~/.beryl/<société>/<domaine>/<host>.key` existe.
# * Le binaire `crystal-clevis-zfs` est installé sur le serveur
#   (à `/usr/local/sbin/crystal-clevis-zfs`).
# * Le YAML host déclare `encryption.mode: tang` avec au moins une
#   URL Tang (cf. `boot-and-mount-plan.adoc`).
# * Le serveur peut joindre les Tangs (réseau).
# * La clé est *actuellement chargée* sur le serveur (lancez
#   `beryl unlock` d'abord si nécessaire) — `zfs change-key`
#   demande la clé courante en mémoire.
#
# Flow par pool en `mode: tang` :
#
#   1. Pré-check : pool chiffré, clé chargée (keystatus=available).
#   2. Pousse la clé locale via stdin SSH dans un tmpfs
#      (`/var/run/beryl-tang-key.<rand>`, mode 0600).
#   3. `zfs set keylocation=file:///var/run/beryl-tang-key.<rand>` —
#      change UNIQUEMENT la propriété, pas la clé.
#   4. `crystal-clevis-zfs bind --use-existing-key --dataset <pool>
#      -t URL1 [-t URL2 ...] [--threshold K]` — le shard lit la clé
#      via la `keylocation`, l'enrôle via Tang, écrit le JWE.
#   5. `rm /var/run/beryl-tang-key.<rand>` — la clé sur disque ne
#      doit pas survivre au tang-enroll (même en cas d'erreur).
#   6. `zfs set keylocation=prompt` — restaure la prop d'origine.
#
# Après tang-enroll, la commande met à jour `/etc/rc.conf` du
# serveur pour activer le déverrouillage automatique au boot
# (`crystal_clevis_zfs_enable=YES` + ajout du dataset à la liste
# `crystal_clevis_zfs_datasets`).
#
# Idempotent : relancer sur un host déjà enrôlé est un no-op (le
# shard détecte que la clé est déjà enrôlée via le JWE existant ;
# `sysrc` est idempotent).
#
# Voir `boot-and-mount-plan.adoc` § « Variantes de provisionnement »
# pour le contexte général, et `crystal-clevis-zfs/README.adoc`
# pour la commande sous-jacente.
module Beryl::CLI::TangEnroll
  EXIT_OK                  =  0
  EXIT_USAGE               =  1
  EXIT_SSH_FAILED          =  2
  EXIT_UNEXPECTED          =  3
  EXIT_KEY_MISSING         =  4
  EXIT_NO_TANG_POOLS       =  5
  EXIT_TANG_BINARY_MISSING =  6
  EXIT_KEY_NOT_LOADED      =  7
  EXIT_BIND_FAILED         =  8
  EXIT_RC_CONF_FAILED      =  9
  EXIT_PRECHECK_FAILED     = 10

  # Chemin attendu du binaire `crystal-clevis-zfs` côté serveur.
  TANG_BINARY = "/usr/local/sbin/crystal-clevis-zfs"

  # Préfixe du tmpfs où la clé est posée temporairement pendant
  # l'enrôlement. Le suffixe aléatoire évite les collisions et le
  # squat. /var/run est un tmpfs sur FreeBSD — la clé ne touche
  # jamais le disque persistant.
  TMPFS_KEY_PREFIX = "/var/run/beryl-tang-key"

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    dry_run = false
    skip_rc_conf = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl tang-enroll <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche les actions sans les exécuter") { dry_run = true }
      p.on("-R", "--skip-rc-conf", "Ne touche pas à /etc/rc.conf (utile pour debug)") { skip_rc_conf = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl tang-enroll <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

    # Sélection des pools en mode tang dans le YAML.
    tang_pools = host.data_zpools.select do |p|
      p.encryption.try(&.tang?) || false
    end

    if tang_pools.empty?
      STDERR.puts "beryl : aucun pool data avec `encryption.mode: tang` déclaré pour #{host.fqdn}"
      STDERR.puts "        Les pools data trouvés et leur mode :"
      host.data_zpools.each do |p|
        m = p.encryption.try(&.mode.to_s) || "(pas chiffré)"
        STDERR.puts "          - #{p.name} : #{m}"
      end
      return EXIT_NO_TANG_POOLS
    end

    # Validation YAML de chaque pool (URLs présentes, threshold cohérent…).
    tang_pools.each do |p|
      begin
        p.validate!
      rescue ex : Beryl::Config::InvalidEncryptionConfig | Beryl::Config::Zpool::UnknownRaidLevel | Beryl::Config::Zpool::InvalidDiskCount
        STDERR.puts "beryl : config invalide pour #{p.name} — #{ex.message}"
        return EXIT_USAGE
      end
    end

    # Lecture de la clé locale. tang-enroll consomme TOUJOURS la clé
    # locale : c'est le matériel cryptographique qui sera enrôlé via
    # Tang. Sans elle, on ne peut pas faire le bind.
    key_path = Beryl::Encryption.key_path(
      config_root, host.account_name, host.domain_name, host.short_name
    )
    unless Beryl::Encryption.exists?(key_path)
      STDERR.puts "beryl : clé absente : #{key_path}"
      STDERR.puts "        Cette clé doit avoir été générée par `beryl bootstrap` et est"
      STDERR.puts "        nécessaire pour enrôler les pools en mode tang."
      return EXIT_KEY_MISSING
    end
    key_hex : String
    begin
      key_hex = Beryl::Encryption.read(key_path)
    rescue ex : Beryl::Encryption::InvalidKey
      STDERR.puts "beryl : #{ex.message}"
      return EXIT_KEY_MISSING
    end

    target = Beryl.format_ssh_target(host)
    summary = tang_pools.map do |p|
      enc = p.encryption.not_nil!
      "#{p.name}(tang×#{enc.tang_urls.size}/#{enc.threshold})"
    end.join(", ")
    log "TE tang-enroll #{target} : #{tang_pools.size} pool(s) à enrôler (#{summary})"

    if dry_run
      log "TE DRY-RUN : SSH root@#{host.ssh_host}:#{host.port}"
      tang_pools.each do |pool|
        enc = pool.encryption.not_nil!
        tang_args = enc.tang_urls.map { |u| "-t #{u}" }.join(" ")
        log "TE DRY-RUN :   pré-check : pool #{pool.name} chiffré + clé chargée"
        log "TE DRY-RUN :   pousser clé via stdin SSH → #{TMPFS_KEY_PREFIX}.<rand>"
        log "TE DRY-RUN :   zfs set keylocation=file://#{TMPFS_KEY_PREFIX}.<rand> #{pool.name}"
        log "TE DRY-RUN :   #{TANG_BINARY} bind --use-existing-key --dataset #{pool.name} #{tang_args}" \
            "#{enc.threshold > 1 ? " --threshold #{enc.threshold}" : ""}"
        log "TE DRY-RUN :   rm #{TMPFS_KEY_PREFIX}.<rand>"
        log "TE DRY-RUN :   zfs set keylocation=prompt #{pool.name}"
      end
      unless skip_rc_conf
        log "TE DRY-RUN :   sysrc crystal_clevis_zfs_enable=YES"
        log "TE DRY-RUN :   sysrc crystal_clevis_zfs_datasets=\"#{tang_pools.map(&.name).join(" ")}\""
      end
      return EXIT_OK
    end

    conn = host.connection

    # Pre-flight côté serveur.
    log "TE pré-check serveur"
    probe = conn.exec("test -x #{Process.quote(TANG_BINARY)}", raise_on_error: false)
    unless probe.success?
      STDERR.puts "beryl : binaire #{TANG_BINARY} absent ou non exécutable sur #{target}"
      STDERR.puts "        Installez-le manuellement à partir du repo `crystal-clevis-zfs`,"
      STDERR.puts "        ou via la recette beryl `crystal-clevis-zfs-install` (à venir)."
      return EXIT_TANG_BINARY_MISSING
    end

    failures = 0
    enrolled_names = [] of String
    tang_pools.each do |pool|
      begin
        enroll_one(conn, pool, key_hex)
        enrolled_names << pool.name
      rescue ex : KeyNotLoaded
        STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl tang-enroll] " \
                    "TE ÉCHEC pool #{pool.name} : #{ex.message}"
        STDERR.puts "        Lancez `beryl unlock #{host.account_name}/#{host.fqdn}` puis ré-essayez."
        failures += 1
      rescue ex
        STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl tang-enroll] " \
                    "TE ÉCHEC pool #{pool.name} : #{ex.class}: #{ex.message}"
        failures += 1
      end
    end

    if failures > 0
      STDERR.puts "beryl : #{failures}/#{tang_pools.size} pool(s) non enrôlé(s)"
      return EXIT_BIND_FAILED
    end

    # Mise à jour /etc/rc.conf pour le déverrouillage automatique au
    # boot. On ajoute les pools enrôlés à la liste existante (idempotent)
    # plutôt que de l'écraser, au cas où l'opérateur aurait déjà des
    # entrées manuelles.
    unless skip_rc_conf
      begin
        update_rc_conf(conn, enrolled_names)
      rescue ex
        STDERR.puts "beryl : enrôlement OK mais update /etc/rc.conf a échoué — #{ex.message}"
        STDERR.puts "        Ajoutez à la main :"
        STDERR.puts "          crystal_clevis_zfs_enable=\"YES\""
        STDERR.puts "          crystal_clevis_zfs_datasets=\"#{enrolled_names.join(" ")}\""
        return EXIT_RC_CONF_FAILED
      end
    end

    log "TE tang-enroll #{target} : terminé (#{enrolled_names.size} pool(s) enrôlé(s) ; auto-unlock au boot activé)"
    log "TE testez en : `beryl reboot #{host.account_name}/#{host.fqdn}` (puis `beryl status` pour vérifier)"
    EXIT_OK
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : SSH a échoué — #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Levée si la clé du dataset n'est pas chargée côté serveur (=
  # `zfs change-key` ne pourrait pas vérifier la clé courante).
  class KeyNotLoaded < Exception
  end

  # Enrôle un pool en mode tang. Le `ensure` garantit que le tmpfs
  # est nettoyé même en cas d'erreur — la clé sur disque (en RAM) ne
  # doit pas survivre.
  private def self.enroll_one(conn : SSH::Connection, pool : Beryl::Config::Pool, key_hex : String) : Nil
    pool_name = pool.name
    enc = pool.encryption.not_nil!

    # 1. Pré-check : pool existe, est chiffré, clé chargée.
    encrypted = conn.exec(
      "zfs get -H -o value encryption #{Process.quote(pool_name)} 2>/dev/null",
      raise_on_error: false,
    )
    unless encrypted.success? && !encrypted.stdout.strip.in?("off", "-")
      raise "le pool #{pool_name} n'est pas chiffré sur le serveur " \
            "(`zfs get encryption` retourne #{encrypted.stdout.strip.inspect})"
    end

    keystatus = conn.exec(
      "zfs get -H -o value keystatus #{Process.quote(pool_name)} 2>/dev/null",
      raise_on_error: false,
    )
    status = keystatus.success? ? keystatus.stdout.strip : "unknown"
    unless status == "available"
      raise KeyNotLoaded.new("clé non chargée pour #{pool_name} (keystatus=#{status})")
    end

    # 2. Crée le tmpfs avec la clé. /var/run est un tmpfs sur FreeBSD
    # (jamais sur disque persistant). Suffixe aléatoire pour éviter
    # collisions et squat.
    suffix = Random::Secure.hex(8)
    tmpkey = "#{TMPFS_KEY_PREFIX}.#{suffix}"
    log "TE   pousse clé locale dans tmpfs #{tmpkey}"
    push_key_to_tmpfs(conn, tmpkey, key_hex)

    begin
      # 3. Change la propriété keylocation (sans changer la clé !).
      # `zfs set keylocation=...` est différent de `zfs change-key` :
      # change-key génère une NOUVELLE clé (catastrophique ici).
      log "TE   zfs set keylocation=file://#{tmpkey} #{pool_name}"
      result = conn.exec(
        "zfs set keylocation=file://#{tmpkey} #{Process.quote(pool_name)}",
        raise_on_error: false,
      )
      unless result.success?
        raise "zfs set keylocation a échoué : exit=#{result.exit_code} stderr=#{result.stderr.strip.inspect}"
      end

      # 4. Bind via Tang. Le shard lit la keylocation, ouvre le
      # fichier, l'enrôle, écrit le JWE dans /var/db/crystal-clevis-zfs/.
      tang_args = enc.tang_urls.map { |u| "-t #{Process.quote(u)}" }.join(" ")
      threshold_arg = enc.threshold > 1 ? "--threshold #{enc.threshold}" : ""
      bind_cmd = "#{Process.quote(TANG_BINARY)} bind --use-existing-key " \
                 "--dataset #{Process.quote(pool_name)} #{tang_args} #{threshold_arg}"
      log "TE   #{TANG_BINARY} bind --use-existing-key --dataset #{pool_name} (#{enc.tang_urls.size} Tang, threshold #{enc.threshold})"
      bind_result = conn.exec(bind_cmd, raise_on_error: false)
      unless bind_result.success?
        raise "crystal-clevis-zfs bind a échoué : " \
              "exit=#{bind_result.exit_code} stderr=#{bind_result.stderr.strip.inspect}"
      end
      stdout_strip = bind_result.stdout.strip
      log "TE   #{stdout_strip}" unless stdout_strip.empty?
    ensure
      # 5. Cleanup tmpfs INCONDITIONNEL (même si bind a planté).
      # La clé ne doit pas survivre à tang-enroll.
      conn.exec("rm -f #{Process.quote(tmpkey)}", raise_on_error: false)

      # 6. Restaurer keylocation=prompt. Sans ça, le serveur tenterait
      # de relire la clé depuis le tmpfs supprimé au prochain unlock.
      conn.exec(
        "zfs set keylocation=prompt #{Process.quote(pool_name)}",
        raise_on_error: false,
      )
    end
  end

  # Pousse `key_hex` (64 chars hex) dans `path` côté serveur, mode
  # 0600. Utilise stdin SSH — la clé n'apparaît jamais dans la ligne
  # de commande (visible dans `ps`).
  #
  # Ajoute un newline final au contenu : le shard `crystal-clevis-zfs`
  # fait un `.strip` à la lecture, donc l'un comme l'autre marche,
  # mais le newline est plus standard côté Unix.
  private def self.push_key_to_tmpfs(conn : SSH::Connection, path : String, key_hex : String) : Nil
    # `umask 0177` garantit mode 0600 par défaut sur le fichier créé.
    cmd = "umask 0177 && cat > #{Process.quote(path)}"
    result = conn.exec(cmd, stdin: key_hex + "\n", raise_on_error: false)
    unless result.success?
      raise "push de la clé dans #{path} a échoué : " \
            "exit=#{result.exit_code} stderr=#{result.stderr.strip.inspect}"
    end
  end

  # Met à jour `/etc/rc.conf` du serveur pour activer le
  # déverrouillage automatique au boot. Utilise `sysrc` (idempotent
  # par construction) plutôt que d'éditer le fichier à la main.
  #
  # Stratégie pour `crystal_clevis_zfs_datasets` : si la variable
  # existe déjà, on prend l'union des datasets existants + les
  # nouveaux. Permet une montée en charge progressive sans écraser
  # un travail manuel précédent.
  private def self.update_rc_conf(conn : SSH::Connection, enrolled_names : Array(String)) : Nil
    log "TE   sysrc crystal_clevis_zfs_enable=YES"
    enable = conn.exec("sysrc crystal_clevis_zfs_enable=YES", raise_on_error: false)
    unless enable.success?
      raise "sysrc crystal_clevis_zfs_enable=YES a échoué : exit=#{enable.exit_code} stderr=#{enable.stderr.strip.inspect}"
    end

    # Lecture de la valeur actuelle (vide si la variable n'existe pas).
    current = conn.exec("sysrc -n crystal_clevis_zfs_datasets 2>/dev/null", raise_on_error: false)
    existing = if current.success?
                 current.stdout.strip.split(/\s+/).reject(&.empty?)
               else
                 [] of String
               end
    union = (existing + enrolled_names).uniq
    new_value = union.join(" ")
    log "TE   sysrc crystal_clevis_zfs_datasets=#{new_value.inspect}"
    set = conn.exec(
      "sysrc crystal_clevis_zfs_datasets=#{Process.quote(new_value)}",
      raise_on_error: false,
    )
    unless set.success?
      raise "sysrc crystal_clevis_zfs_datasets a échoué : exit=#{set.exit_code} stderr=#{set.stderr.strip.inspect}"
    end
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl tang-enroll] #{message}"
  end
end
