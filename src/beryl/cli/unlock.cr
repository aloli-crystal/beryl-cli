require "option_parser"
require "ssh"
require "../config"
require "../encryption"
require "./account_utils"

# Sous-commande `beryl unlock <host>` (étape H4 du chiffrement) :
# importe et déchiffre les pools data chiffrés d'un host après un
# reboot.
#
# Routage par mode (depuis T3 — 28 avril 2026) :
#
# * *mode ssh_unlock* (Option C, défaut historique) — la clé locale
#   `~/.config/beryl/<société>/<domaine>/<host>.key` voyage via stdin SSH
#   jusqu'à `zfs load-key`. Aucune dépendance Tang.
#
# * *mode tang* (Option D) — délègue à `crystal-clevis-zfs unlock`
#   sur le serveur. Le binaire interroge Tang en interne, dérive la
#   clé, la pousse à `zfs load-key`. Pas de clé locale nécessaire.
#
# Flow général :
#
#   1. Pour chaque pool data déclaré chiffré :
#      a. `zpool import -N <pool>` si pas déjà importé.
#      b. Selon le mode :
#         - *ssh_unlock* : `zfs load-key <pool>` avec clé locale via stdin.
#         - *tang* : `crystal-clevis-zfs unlock --no-mount --dataset <pool>`.
#      c. `zfs mount -a -l` (côté beryl, garde le contrôle du mount).
#   2. Idempotent : si le pool est déjà importé et la clé chargée,
#      log « déjà déverrouillé » et passe au suivant.
#
# Voir `zpool-encryption-architecture.adoc` § « Le modèle SSH unlock »
# pour le contexte complet.
module Beryl::CLI::Unlock
  EXIT_OK                  = 0
  EXIT_USAGE               = 1
  EXIT_SSH_FAILED          = 2
  EXIT_UNEXPECTED          = 3
  EXIT_KEY_MISSING         = 4
  EXIT_NO_DATA_POOLS       = 5
  EXIT_UNLOCK_FAILED       = 6
  EXIT_MISSING_CONFIG      = 7
  EXIT_TANG_BINARY_MISSING = 8

  # Chemin attendu du binaire `crystal-clevis-zfs` côté serveur. Le
  # README du shard documente cet emplacement comme cible
  # d'installation. Si l'opérateur l'a mis ailleurs, la recette beryl
  # `crystal-clevis-zfs-install` pourra l'override plus tard.
  TANG_BINARY = "/usr/local/sbin/crystal-clevis-zfs"

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    dry_run = true
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl unlock <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl unlock <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

    encrypted_pools = host.data_zpools.select(&.encrypted?)
    # Datasets sensibles du zroot (profil Option I) : l'encryptionroot partagé
    # `zroot/encrypted` + ses enfants /home,/opt,/usr/local/etc. `find(&.boot)`
    # plutôt que `boot_zpool` (qui LÈVE) : un host sans pool boot (config de test
    # data-only) → enc_root nil, on ne traite alors que les pools data.
    boot_pool = host.zpools.find(&.boot)
    enc_root = boot_pool.try(&.encryption_root)
    enc_root_cfg = boot_pool.try(&.encryption)
    enc_root_tang = !enc_root.nil? && enc_root_cfg.try(&.tang?) == true
    enc_root_ssh = !enc_root.nil? && !enc_root_tang # défaut ssh_unlock si pas tang

    if encrypted_pools.empty? && enc_root.nil?
      STDERR.puts "beryl : aucun pool data ni dataset zroot chiffré (profil) déclaré pour #{host.fqdn}"
      STDERR.puts "        (pools data trouvés : #{host.data_zpools.map(&.name).join(", ")})"
      return EXIT_NO_DATA_POOLS
    end

    # Lecture de la clé locale UNIQUEMENT si au moins une unité est en
    # mode ssh_unlock. En mode tang seul, la clé vit côté serveur (via
    # Tang) — pas besoin de fichier local.
    needs_local_key = encrypted_pools.any? { |p| p.encryption.not_nil!.ssh_unlock? } || enc_root_ssh
    key_hex : String? = nil
    if needs_local_key
      key_path = Beryl::Encryption.key_path(
        config_root, host.account_name, host.domain_name, host.short_name
      )
      unless Beryl::Encryption.exists?(key_path)
        STDERR.puts "beryl : clé absente : #{key_path}"
        STDERR.puts "        Cette clé doit avoir été générée par `beryl bootstrap`."
        STDERR.puts "        Si vous l'avez perdue, les datasets chiffrés sont définitivement illisibles."
        return EXIT_KEY_MISSING
      end
      begin
        key_hex = Beryl::Encryption.read(key_path)
      rescue ex : Beryl::Encryption::InvalidKey
        STDERR.puts "beryl : #{ex.message}"
        return EXIT_KEY_MISSING
      end
    end

    target = Beryl.format_ssh_target(host)
    units = encrypted_pools.map { |p| "#{p.name}(#{mode_label(p)})" }
    units << "#{enc_root}(#{enc_root_tang ? "tang" : "ssh_unlock"})" if enc_root
    log "H4 unlock #{target} : #{units.size} unité(s) chiffrée(s) à déverrouiller (#{units.join(", ")})"

    if dry_run
      log "H4 DRY-RUN : SSH root@#{host.ssh_host}:#{host.port}"
      encrypted_pools.each do |pool|
        log "H4 DRY-RUN :   zpool import -N #{pool.name}"
        case pool.encryption.not_nil!.mode
        when Beryl::Config::EncryptionConfig::Mode::SshUnlock
          log "H4 DRY-RUN :   echo '<64-char-hex-key>' | zfs load-key #{pool.name}"
        when Beryl::Config::EncryptionConfig::Mode::Tang
          log "H4 DRY-RUN :   #{TANG_BINARY} unlock --no-mount --dataset #{pool.name}"
        end
        log "H4 DRY-RUN :   zfs mount -a -l"
      end
      if er = enc_root
        # encryptionroot zroot : pas d'import (zroot déjà importé au boot).
        if enc_root_tang
          log "H4 DRY-RUN :   #{TANG_BINARY} unlock --no-mount --dataset #{er}"
        else
          log "H4 DRY-RUN :   echo '<64-char-hex-key>' | zfs load-key #{er}"
        end
        log "H4 DRY-RUN :   zfs mount -a -l   (datasets zroot : /home, /opt, /usr/local/etc)"
      end
      return EXIT_OK
    end

    conn = host.connection

    # Pre-flight : si au moins un pool est en mode tang, vérifier que
    # le binaire `crystal-clevis-zfs` est présent côté serveur. Sinon
    # erreur claire AVANT de tenter quoi que ce soit (évite le
    # déchiffrement partiel).
    needs_tang = encrypted_pools.any? { |p| p.encryption.not_nil!.tang? } || enc_root_tang
    if needs_tang
      probe = conn.exec("test -x #{Process.quote(TANG_BINARY)}", raise_on_error: false)
      unless probe.success?
        STDERR.puts "beryl : binaire #{TANG_BINARY} absent ou non exécutable sur #{target}"
        STDERR.puts "        Il est requis pour le `mode: tang`. Installez-le via :"
        STDERR.puts "          beryl apply #{host.account_name}/#{host.fqdn}   (recette crystal-clevis-zfs-install, à venir)"
        STDERR.puts "        Ou manuellement à partir du repo `clevis-zfs`."
        return EXIT_TANG_BINARY_MISSING
      end
    end

    total = encrypted_pools.size + (enc_root ? 1 : 0)
    failures = 0
    encrypted_pools.each do |pool|
      begin
        unlock_one(conn, pool, key_hex)
      rescue ex
        STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl unlock] " \
                    "H4 ÉCHEC pool #{pool.name} : #{ex.class}: #{ex.message}"
        failures += 1
      end
    end
    if er = enc_root
      begin
        unlock_encryption_root(conn, er, enc_root_cfg, key_hex)
      rescue ex
        STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl unlock] " \
                    "H4 ÉCHEC encryptionroot #{er} : #{ex.class}: #{ex.message}"
        failures += 1
      end
    end

    if failures > 0
      STDERR.puts "beryl : #{failures}/#{total} unité(s) non déverrouillée(s)"
      return EXIT_UNLOCK_FAILED
    end

    log "H4 unlock #{target} : terminé (#{total} unité(s) en ligne)"
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

  # Étiquette compacte du mode pour les logs.
  private def self.mode_label(pool : Beryl::Config::Pool) : String
    enc = pool.encryption
    return "?" unless enc
    case enc.mode
    when Beryl::Config::EncryptionConfig::Mode::SshUnlock then "ssh"
    when Beryl::Config::EncryptionConfig::Mode::Tang      then "tang×#{enc.tang_urls.size}/#{enc.threshold}"
    else                                                       "?"
    end
  end

  # Déverrouille un pool : import, load-key (par voie selon mode), mount.
  # Idempotent : si le pool est déjà importé et la clé chargée, no-op.
  #
  # `key_hex` peut être nil si le pool est en mode tang (la clé arrive
  # via Tang côté serveur, pas via stdin SSH depuis le poste opérateur).
  private def self.unlock_one(conn : SSH::Connection, pool : Beryl::Config::Pool, key_hex : String?) : Nil
    pool_name = pool.name
    target = "#{conn.user}@#{conn.host}"
    enc = pool.encryption.not_nil!

    # 1. Import si pas déjà importé. Étape commune aux deux modes.
    listed = conn.exec("zpool list -H -o name #{Process.quote(pool_name)}", raise_on_error: false)
    already_imported = listed.success? && listed.stdout.strip == pool_name
    if already_imported
      log "H4   pool #{pool_name} déjà importé sur #{target}"
    else
      log "H4   zpool import -N #{pool_name} (sur #{target})"
      result = conn.exec("zpool import -N #{Process.quote(pool_name)}", raise_on_error: false)
      unless result.success?
        raise "zpool import #{pool_name} a échoué : exit=#{result.exit_code} stderr=#{result.stderr.strip.inspect}"
      end
    end

    # 2. Charge la clé selon le mode.
    keystatus = conn.exec("zfs get -H -o value keystatus #{Process.quote(pool_name)}", raise_on_error: false)
    status = keystatus.success? ? keystatus.stdout.strip : "unknown"
    if status == "available"
      log "H4   clé déjà chargée pour #{pool_name}"
    else
      case enc.mode
      when Beryl::Config::EncryptionConfig::Mode::SshUnlock
        load_key_via_ssh_stdin(conn, pool_name, key_hex.not_nil!)
      when Beryl::Config::EncryptionConfig::Mode::Tang
        load_key_via_tang(conn, pool_name, enc)
      end
    end

    # 3. Monte les datasets du pool. Étape commune aux deux modes —
    # `crystal-clevis-zfs unlock` est appelé avec `--no-mount` pour
    # qu'on garde le contrôle ici (cohérence avec le mode ssh_unlock,
    # diagnostic uniforme).
    log "H4   zfs mount -a -l (montage des datasets de #{pool_name})"
    mount = conn.exec("zfs mount -a -l", raise_on_error: false)
    unless mount.success?
      # `zfs mount -a` peut retourner non-zero si UN dataset échoue
      # (ex: mountpoint déjà utilisé par un dataset clair). On loggue
      # mais ne lève pas — l'opérateur regarde la sortie.
      log "H4   zfs mount -a -l a retourné exit=#{mount.exit_code} stderr=#{mount.stderr.strip.inspect[0, 200]}"
    end

    # Diagnostic : liste les datasets montés du pool pour confirmer.
    mounted = conn.exec(
      "zfs list -H -o name,mounted,mountpoint -r #{Process.quote(pool_name)}",
      raise_on_error: false,
    )
    if mounted.success?
      mounted.stdout.each_line do |line|
        log "H4     #{line.strip}"
      end
    end
  end

  # Déverrouille l'encryptionroot zroot du profil Option I (`zroot/encrypted`)
  # + ses enfants /home, /opt, /usr/local/etc. Différence avec `unlock_one` :
  # PAS de `zpool import` — le pool boot zroot est déjà importé au boot (sshd
  # tourne dessus). On charge juste la clé (par voie selon le mode) puis on monte.
  # Idempotent : si la clé est déjà chargée, on saute le load-key. csh-safe.
  #
  # `enc_cfg` est la config `encryption:` du pool boot (le mode des datasets).
  # nil ou non-tang ⇒ ssh_unlock (clé locale via stdin). `key_hex` requis alors.
  private def self.unlock_encryption_root(conn : SSH::Connection, enc_root : String, enc_cfg : Beryl::Config::EncryptionConfig?, key_hex : String?) : Nil
    target = "#{conn.user}@#{conn.host}"
    tang = enc_cfg.try(&.tang?) == true

    keystatus = conn.exec("zfs get -H -o value keystatus #{Process.quote(enc_root)}", raise_on_error: false)
    status = keystatus.success? ? keystatus.stdout.strip : "unknown"
    if status == "available"
      log "H4   clé déjà chargée pour #{enc_root} (sur #{target})"
    elsif tang
      load_key_via_tang(conn, enc_root, enc_cfg.not_nil!)
    else
      load_key_via_ssh_stdin(conn, enc_root, key_hex.not_nil!)
    end

    # Monte les enfants (/home, /opt, /usr/local/etc), maintenant déchiffrables.
    log "H4   zfs mount -a -l (datasets zroot de #{enc_root})"
    mount = conn.exec("zfs mount -a -l", raise_on_error: false)
    unless mount.success?
      log "H4   zfs mount -a -l a retourné exit=#{mount.exit_code} stderr=#{mount.stderr.strip.inspect[0, 200]}"
    end

    mounted = conn.exec(
      "zfs list -H -o name,mounted,mountpoint -r #{Process.quote(enc_root)}",
      raise_on_error: false,
    )
    if mounted.success?
      mounted.stdout.each_line do |line|
        log "H4     #{line.strip}"
      end
    end
  end

  # Mode ssh_unlock — clé locale via stdin SSH (Option C historique).
  private def self.load_key_via_ssh_stdin(conn : SSH::Connection, pool_name : String, key_hex : String) : Nil
    log "H4   zfs load-key #{pool_name} (mode ssh_unlock, clé via stdin SSH)"
    load = conn.exec("zfs load-key #{Process.quote(pool_name)}", stdin: key_hex, raise_on_error: false)
    unless load.success?
      raise "zfs load-key #{pool_name} a échoué : exit=#{load.exit_code} stderr=#{load.stderr.strip.inspect}"
    end
  end

  # Mode tang — délègue à `crystal-clevis-zfs unlock` sur le serveur.
  # Le binaire :
  #   1. lit le JWE local /var/db/crystal-clevis-zfs/<dataset_aplati>.jwe ;
  #   2. dialogue avec les Tangs configurés (single ou SSS multi-Tang) ;
  #   3. dérive la clé, la pousse à `zfs load-key` via stdin (côté shard) ;
  #   4. avec `--no-mount`, ne fait PAS le mount (beryl s'en occupe).
  #
  # La clé hex ne transite jamais par beryl en mode tang — c'est tout
  # l'intérêt du modèle (Tang reste la seule autorité de la clé).
  private def self.load_key_via_tang(conn : SSH::Connection, pool_name : String, enc : Beryl::Config::EncryptionConfig) : Nil
    urls_summary = if enc.tang_urls.size == 1
                     enc.tang_urls.first
                   else
                     "#{enc.tang_urls.size} Tangs, threshold #{enc.threshold}"
                   end
    log "H4   #{TANG_BINARY} unlock --no-mount --dataset #{pool_name} (mode tang : #{urls_summary})"
    cmd = "#{Process.quote(TANG_BINARY)} unlock --no-mount --dataset #{Process.quote(pool_name)}"
    result = conn.exec(cmd, raise_on_error: false)
    unless result.success?
      raise "crystal-clevis-zfs unlock #{pool_name} a échoué : " \
            "exit=#{result.exit_code} stderr=#{result.stderr.strip.inspect}"
    end
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl unlock] #{message}"
  end
end
