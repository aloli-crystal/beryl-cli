require "option_parser"
require "../config"
require "ssh"
require "./account_utils"

# Sous-commande `beryl apply <host>` : synchronise la config effective
# du host (résultat du merge _default + domaine + groupe + host) avec
# ce qui tourne réellement sur le serveur FreeBSD déjà bootstrappé.
#
# Sémantique DÉCLARATIVE : le YAML est la source de vérité.
# - Packages manquants → `pkg install -y`
# - Clés SSH manquantes dans authorized_keys → ajoutées
# - Clés SSH en trop dans authorized_keys → supprimées
# - Sudoers → fichier `/usr/local/etc/sudoers.d/beryl` réécrit
#
# Pas de suppression de packages ni de users pour cette version
# (risque de casser un service qui tourne). La création de nouveaux
# users n'est pas faite non plus : cycle bootstrap-only pour l'instant.
module Beryl::CLI::Apply
  EXIT_OK         =  0
  EXIT_USAGE      =  1
  EXIT_UNEXPECTED =  3
  EXIT_SSH_FAILED =  4
  EXIT_NO_FREEBSD = 10

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = false
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl apply <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche ce qui changerait sans l'appliquer") { dry_run = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl apply <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    # Apply est FreeBSD-only dans ce build. L'architecture ADR-014
    # prévoit des `Os::Debian`, `Os::Ubuntu`, etc. — pas câblés ici.
    unless host.os == "freebsd"
      STDERR.puts "beryl : apply n'est implémenté que pour os: freebsd (host : #{host.os})."
      return EXIT_USAGE
    end

    conn = host.connection
    log "cible : #{Beryl.format_ssh_target(host)} (user SSH : #{conn.user})"

    uname = conn.exec("uname -s", raise_on_error: false).stdout.strip
    unless uname == "FreeBSD"
      STDERR.puts "beryl : #{host.fqdn} n'est pas sur FreeBSD (uname -s = #{uname.inspect})"
      return EXIT_NO_FREEBSD
    end

    # Lire les valeurs à appliquer
    packages = host.freebsd_string_array("packages")
    sudoers = host.freebsd_string_array("sudoers")
    users = parse_users(host)

    apply_packages(conn, packages, dry_run) unless packages.empty?
    apply_sudoers(conn, sudoers, dry_run) unless sudoers.empty?
    apply_user_keys(conn, users, dry_run)

    log "apply terminé pour #{host.fqdn}#{dry_run ? " (dry-run)" : ""}"
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
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Extrait les users du merge effectif avec leur liste de clés
  # finale (déjà injectée avec la clé domaine par Merger).
  private def self.parse_users(host : Beryl::Config::ResolvedHost) : Array(NamedTuple(name: String, keys: Array(String)))
    users_any = host.freebsd_hash[YAML::Any.new("users")]?
    return [] of NamedTuple(name: String, keys: Array(String)) unless users_any
    list = users_any.as_a? || [] of YAML::Any
    list.compact_map do |u|
      h = u.as_h?
      next nil unless h
      name = h[YAML::Any.new("name")]?.try(&.as_s?)
      next nil unless name
      keys_any = h[YAML::Any.new("ssh_keys")]?
      keys = keys_any.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      {name: name, keys: keys}
    end
  end

  private def self.apply_packages(conn : SSH::Connection, packages : Array(String), dry_run : Bool) : Nil
    installed = conn.exec("pkg info -q 2>/dev/null | awk '{print $1}' | sed 's/-[0-9].*$//' | sort -u", raise_on_error: false).stdout.lines.map(&.strip).reject(&.empty?).to_set
    missing = packages.reject { |p| installed.includes?(p) }
    if missing.empty?
      log "packages : déjà tous installés"
      return
    end
    log "packages manquants : #{missing.join(", ")}"
    return if dry_run
    conn.exec("pkg install -y #{missing.map { |p| Process.quote(p) }.join(" ")}")
  end

  private def self.apply_sudoers(conn : SSH::Connection, rules : Array(String), dry_run : Bool) : Nil
    content = rules.join("\n") + "\n"
    target = "/usr/local/etc/sudoers.d/beryl"
    current = conn.exec("cat #{target} 2>/dev/null", raise_on_error: false).stdout
    if current == content
      log "sudoers : à jour"
      return
    end
    log "sudoers : mise à jour de #{target} (#{rules.size} règle(s))"
    return if dry_run
    # write_file ne sait pas sudo — on utilise sudo tee pour écrire
    # en écrasant, puis chmod 0440 (requis par sudo visudo).
    quoted_content = Process.quote(content)
    conn.exec("echo #{quoted_content} | sudo tee #{target} > /dev/null && sudo chmod 0440 #{target}")
  end

  # Synchronisation déclarative des authorized_keys.
  # État désiré = exactement les clés listées dans freebsd.users[].ssh_keys
  # (la clé domaine a déjà été injectée par Merger).
  private def self.apply_user_keys(
    conn : SSH::Connection,
    users : Array(NamedTuple(name: String, keys: Array(String))),
    dry_run : Bool,
  ) : Nil
    users.each do |u|
      home = conn.exec("getent passwd #{Process.quote(u[:name])} | cut -d: -f6", raise_on_error: false).stdout.strip
      if home.empty?
        log "user `#{u[:name]}` absent sur le serveur (skip — utilisez bootstrap pour créer les users)"
        next
      end
      current_raw = conn.exec("cat #{home}/.ssh/authorized_keys 2>/dev/null", raise_on_error: false).stdout
      current = current_raw.lines.map(&.strip).reject { |l| l.empty? || l.starts_with?('#') }
      desired = u[:keys]
      to_add = desired - current
      to_remove = current - desired
      if to_add.empty? && to_remove.empty?
        log "#{u[:name]} : #{desired.size} clé(s), déjà sync"
        next
      end
      log "#{u[:name]} : +#{to_add.size} / -#{to_remove.size} clé(s)"
      return if dry_run
      content = desired.join("\n") + "\n"
      conn.exec("mkdir -p #{home}/.ssh && chmod 700 #{home}/.ssh && chown #{Process.quote(u[:name])} #{home}/.ssh")
      conn.write_file("#{home}/.ssh/authorized_keys", content, mode: "0600")
      conn.exec("chown #{Process.quote(u[:name])} #{home}/.ssh/authorized_keys")
    end
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl apply] #{message}"
  end
end
