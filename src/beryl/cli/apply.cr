require "option_parser"
require "../inventory"
require "../ssh"

# Sous-commande `beryl apply <host>` : synchronise la configuration
# FreeBSD (packages, users, sudoers) d'un serveur déjà bootstrappé, en
# lisant le bloc `freebsd:` de l'inventaire.
#
# C'est l'étape qui vient APRÈS `beryl bootstrap`. Le bootstrap pose la
# base minimale (admin, sudo, zsh, sudoers wheel NOPASSWD) pour que
# `apply` puisse se connecter en admin + sudo et continuer le travail :
# installer ruby, crystal, mariadb, postgresql, etc., créer des users
# applicatifs (deploy), poser des règles sudoers spécifiques.
#
# Idempotent : `pkg install` n'installe que ce qui manque, `pw useradd`
# skippe un user existant, les règles sudoers sont écrites en
# remplacement. Relancer `apply` après un reboot ou une modif YAML
# n'abîme rien.
#
# Scope initial (itération 1, 22 avril 2026) :
#   - packages    : pkg install -y <liste> (hors chroot, on est en OS nominal)
#   - users       : pw useradd si absent, injection ssh_keys (override
#                   complet si présent dans YAML)
#   - sudoers     : réécriture de /usr/local/etc/sudoers.d/beryl à chaque fois
#
# Hors scope à ce stade (futures itérations) :
#   - pkg upgrade (beryl apply --upgrade) pour bump ruby/passenger, etc.
#   - services enable/start (sshd_enable, mariadb_enable, …)
#   - fichiers de conf applicatifs (/usr/local/etc/...)
#   - gestion fine de l'ordre de création (groupes primaires, dépendances).
module Beryl::CLI::Apply
  EXIT_OK            =  0
  EXIT_USAGE         =  1
  EXIT_SSH_FAILED    =  2
  EXIT_UNEXPECTED    =  3
  EXIT_MISSING_YAML  =  8
  EXIT_SUDO_REFUSED  = 11
  EXIT_PKG_FAILED    = 12
  EXIT_USER_FAILED   = 13
  EXIT_NOTHING_TO_DO = 14

  # Chemin du fichier sudoers.d écrit par beryl sur la cible. Nom fixe
  # (pas `sudoers` générique) pour qu'un admin puisse coexister avec des
  # règles manuelles sans collision.
  SUDOERS_FILE_ON_TARGET = "/usr/local/etc/sudoers.d/beryl"

  def self.run(inventory_path : String, args : Array(String)) : Int32
    positional = [] of String
    do_packages = true
    do_users = true
    do_sudoers = true
    dry_run = false

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl apply <host> [options]\n\n" \
                 "Synchronise packages, users, sudoers du bloc `freebsd:` vers la cible.\n" \
                 "Idempotent : peut être relancé autant de fois que nécessaire."
      p.on("--skip-packages", "Ne pas installer les packages freebsd.packages") { do_packages = false }
      p.on("--skip-users", "Ne pas synchroniser les users freebsd.users") { do_users = false }
      p.on("--skip-sudoers", "Ne pas réécrire /usr/local/etc/sudoers.d/beryl") { do_sudoers = false }
      p.on("--dry-run", "Affiche les actions sans les exécuter") { dry_run = true }
      p.on("-h", "--help", "Aide") do
        puts p
        exit 0
      end
      p.unknown_args do |rest, _|
        positional = rest
      end
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl apply <host>"
      return EXIT_USAGE
    end

    inventory = Beryl::Inventory.load(inventory_path)
    host = inventory.find(host_name)

    fcfg = host.freebsd_config
    unless fcfg
      STDERR.puts "beryl : pas de bloc `freebsd:` pour #{host.name} dans l'inventaire."
      STDERR.puts "       Ajoutez au moins `freebsd: { packages: [...], users: [...] }`."
      return EXIT_MISSING_YAML
    end

    conn = host.connection
    log "cible : #{host.name} (user SSH : #{conn.user})"

    ran_something = false
    exit_code = EXIT_OK

    if do_packages && !fcfg.packages.empty?
      ran_something = true
      log_step("pkg install #{fcfg.packages.join(" ")}") do
        apply_packages(conn, fcfg.packages, dry_run: dry_run)
      end
    elsif do_packages
      log "packages : rien à installer (freebsd.packages vide)"
    end

    if do_users && !fcfg.users.empty?
      ran_something = true
      log_step("sync users (#{fcfg.users.map(&.name).join(", ")})") do
        apply_users(conn, fcfg.users, dry_run: dry_run)
      end
    elsif do_users
      log "users : rien à synchroniser (freebsd.users vide)"
    end

    if do_sudoers && !fcfg.sudoers.empty?
      ran_something = true
      log_step("écriture #{SUDOERS_FILE_ON_TARGET} (#{fcfg.sudoers.size} règle(s))") do
        apply_sudoers(conn, fcfg.sudoers, dry_run: dry_run)
      end
    elsif do_sudoers
      log "sudoers : rien à écrire (freebsd.sudoers vide)"
    end

    unless ran_something
      log "rien à faire : packages, users et sudoers sont tous vides ou skippés."
      return EXIT_NOTHING_TO_DO
    end

    log "apply terminé pour #{host.name}#{dry_run ? " (dry-run)" : ""}"
    exit_code
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : SudoRefused
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SUDO_REFUSED
  rescue ex : PkgInstallFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_PKG_FAILED
  rescue ex : UserSyncFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USER_FAILED
  rescue ex : Beryl::SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex : File::NotFoundError
    STDERR.puts "beryl : inventaire introuvable : #{inventory_path}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  class SudoRefused < Exception
  end

  class PkgInstallFailed < Exception
  end

  class UserSyncFailed < Exception
  end

  # `pkg install -y <pkgs>` sur la cible. Passe par `sudo -n` pour que la
  # tentative d'interaction de sudo plante tôt si NOPASSWD n'est pas en
  # place (plutôt que de hanger silencieusement sur une invite).
  private def self.apply_packages(
    conn : Beryl::SSH::Connection,
    packages : Array(String),
    dry_run : Bool,
  ) : Nil
    cmd = "sudo -n env ASSUME_ALWAYS_YES=yes pkg install -y #{packages.map { |p| Process.quote(p) }.join(" ")}"
    if dry_run
      log "  [dry-run] $ #{cmd}"
      return
    end
    ensure_sudo_nopasswd(conn)
    result = conn.exec(cmd, raise_on_error: false)
    unless result.success?
      raise PkgInstallFailed.new("pkg install échoué (exit #{result.exit_code}) : #{result.stderr.strip}")
    end
  end

  # Synchronise chaque user YAML :
  # - Crée le user s'il n'existe pas (pw useradd), sinon le laisse
  # - Écrit ~user/.ssh/authorized_keys avec les clés déclarées (override
  #   complet, pas d'append : l'opérateur voit clairement ce qui est posé)
  #
  # Permissions : pw + mkdir + chown tournent via `sudo -n`.
  private def self.apply_users(
    conn : Beryl::SSH::Connection,
    users : Array(Beryl::UserSpecYaml),
    dry_run : Bool,
  ) : Nil
    ensure_sudo_nopasswd(conn) unless dry_run
    users.each do |u|
      if u.ssh_keys.empty?
        raise UserSyncFailed.new("user #{u.name} : ssh_keys vide (Aloli interdit les défauts silencieux)")
      end
      apply_one_user(conn, u, dry_run: dry_run)
    end
  end

  private def self.apply_one_user(
    conn : Beryl::SSH::Connection,
    u : Beryl::UserSpecYaml,
    dry_run : Bool,
  ) : Nil
    primary = u.primary_group || "www"
    shell = u.shell || "/bin/csh"
    secondary = u.secondary_groups

    pw_cmd = String.build do |io|
      io << "sudo -n pw useradd -n " << Process.quote(u.name)
      io << " -m -d " << Process.quote("/home/#{u.name}")
      io << " -g " << Process.quote(primary)
      io << " -G " << Process.quote(secondary.join(",")) unless secondary.empty?
      io << " -s " << Process.quote(shell)
    end
    # pw useradd renvoie 65 (EX_DATAERR) si le user existe déjà : on ignore.
    create_cmd = "id -u #{Process.quote(u.name)} >/dev/null 2>&1 || (#{pw_cmd})"

    # authorized_keys : écriture atomique via tee, avec permissions strictes
    # attendues par sshd (0700 sur ~/.ssh, 0600 sur authorized_keys).
    keys_content = u.ssh_keys.join("\n") + "\n"
    home = "/home/#{u.name}"
    ssh_dir = "#{home}/.ssh"
    authorized = "#{ssh_dir}/authorized_keys"

    setup_ssh = [
      "sudo -n install -d -m 700 -o #{Process.quote(u.name)} -g #{Process.quote(primary)} #{Process.quote(ssh_dir)}",
      "printf %s #{Process.quote(keys_content)} | sudo -n tee #{Process.quote(authorized)} >/dev/null",
      "sudo -n chown #{Process.quote(u.name)}:#{Process.quote(primary)} #{Process.quote(authorized)}",
      "sudo -n chmod 600 #{Process.quote(authorized)}",
    ].join(" && ")

    full_cmd = "#{create_cmd} && #{setup_ssh}"

    if dry_run
      log "  [dry-run] $ #{full_cmd}"
      return
    end

    result = conn.exec(full_cmd, raise_on_error: false)
    unless result.success?
      raise UserSyncFailed.new("sync user #{u.name} échoué (exit #{result.exit_code}) : #{result.stderr.strip}")
    end
  end

  # Écrit (en remplacement) `/usr/local/etc/sudoers.d/beryl` avec les
  # règles déclarées, mode 0440 comme attendu par sudo. Vérifie la
  # syntaxe avec `visudo -cf` avant d'écraser le fichier final, pour
  # éviter de se couper l'accès sudo sur une typo.
  private def self.apply_sudoers(
    conn : Beryl::SSH::Connection,
    sudoers : Array(String),
    dry_run : Bool,
  ) : Nil
    content = sudoers.join("\n") + "\n"
    tmp = "/tmp/beryl-sudoers.$$"
    quoted_final = Process.quote(SUDOERS_FILE_ON_TARGET)

    write_tmp = "printf %s #{Process.quote(content)} > #{Process.quote(tmp)}"
    validate = "sudo -n visudo -cf #{Process.quote(tmp)}"
    install = "sudo -n install -m 0440 -o root -g wheel #{Process.quote(tmp)} #{quoted_final} && rm -f #{Process.quote(tmp)}"

    full_cmd = [write_tmp, validate, install].join(" && ")
    if dry_run
      log "  [dry-run] $ #{full_cmd}"
      return
    end
    ensure_sudo_nopasswd(conn)
    conn.exec(full_cmd)
  end

  # Vérifie qu'on a bien sudo sans mot de passe. Plante tôt avec un
  # message clair sinon : la plupart des commandes qui suivent
  # trainerait un invite bloquant.
  private def self.ensure_sudo_nopasswd(conn : Beryl::SSH::Connection) : Nil
    result = conn.exec("sudo -n true", raise_on_error: false)
    return if result.success?
    raise SudoRefused.new(
      "sudo sans mot de passe refusé sur #{conn.host} (user #{conn.user}). " \
      "Vérifiez que %wheel NOPASSWD est bien posé dans /usr/local/etc/sudoers.d/"
    )
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl apply] #{message}"
  end

  # Même pattern que Rescue.log_step / BootHd.log_step : tick [NNNs]
  # pendant l'exécution, fige le compteur quand le bloc termine.
  private def self.log_step(label : String, & : -> T) : T forall T
    line = "[#{Beryl.format_timestamp(Time.local)}] [beryl apply] #{label}"
    pad = Beryl.pad_to(line)
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
