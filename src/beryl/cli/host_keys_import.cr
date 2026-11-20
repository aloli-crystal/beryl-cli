require "option_parser"
require "./option_errors"
require "./scope"
require "./config_git"
require "./info"
require "./ssh_config"
require "../config"
require "../host_key"

# `beryl host-keys <portée> [--apply]` — inscrit la clé d'hôte ed25519 des
# serveurs DÉJÀ installés dans le `known_hosts` de leur société
# (`<société>/known_hosts`), comme le fait `beryl bootstrap` pour un serveur
# neuf ; puis regénère `~/.ssh/beryl--<société>.conf`.
#
# Source : la clé publique lue sur le serveur (`/etc/ssh/ssh_host_ed25519_key.pub`,
# par la connexion de beryl), RECOUPÉE avec celle de votre `~/.ssh/known_hosts`
# si vous l'aviez déjà acceptée : deux clés différentes → serveur refusé (clé
# changée ou interception), jamais d'inscription. Sans entrée locale, la clé
# est inscrite et son empreinte affichée, à comparer. Une entrée déjà présente
# dans le fichier de la société avec une AUTRE clé est refusée aussi.
#
# Essai à blanc par défaut ; `--apply` écrit, commite et regénère la config ssh.
module Beryl::CLI::HostKeysImport
  extend self

  EXIT_OK     =  0
  EXIT_FAILED =  1
  EXIT_USAGE  = 64

  REMOTE_PUB = "#{Beryl::HostKey::REMOTE_PATH}.pub"

  def run(config_root : String, argv : Array(String)) : Int32
    dry_run = true
    known_hosts = File.join(Path.home.to_s, ".ssh", "known_hosts")
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl host-keys <portée> [--apply]\n\n" \
                 "Inscrit la clé d'hôte ed25519 des serveurs installés dans <société>/known_hosts\n" \
                 "(dépôt de config), que ~/.ssh/#{Beryl::SshConfig::FILE_PREFIX}<société>.conf désigne : plus de\n" \
                 "question « continue connecting? » au premier ssh. Clé lue sur le serveur et recoupée\n" \
                 "avec ~/.ssh/known_hosts (différente → refusée). Portée : serveur, groupe, domaine,\n" \
                 "société ou liste `a,b`.\n"
      p.on("--apply", "Écrit, commite et regénère la config ssh (sinon : essai à blanc)") { dry_run = false }
      p.on("--known-hosts=PATH", "known_hosts de recoupement (défaut : ~/.ssh/known_hosts)") { |v| known_hosts = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(argv)

    scope, _ = Beryl::CLI::Scope.args("host-keys", positional) || return EXIT_USAGE
    unless scope
      STDERR.puts "beryl host-keys : portée manquante (serveur, groupe, domaine, société ou liste)."
      return EXIT_USAGE
    end
    root = Beryl::Config::Root.load(config_root)
    hosts = Beryl::CLI::Scope.hosts("host-keys", root, scope, "aucun serveur installé") { |h| h.installed? } || return EXIT_USAGE

    failed = 0
    # Fichier de société → contenu à écrire.
    pending = {} of String => String
    accounts = Set(String).new
    hosts.sort_by(&.fqdn).each do |host|
      path = Beryl::HostKey.path(host.account.path)
      current = pending[path]? || (File.exists?(path) ? File.read(path) : "")
      kind, detail = check(host, current, known_hosts)
      case kind
      when :ok
        key, message = detail.split("\t", 2)
        pending[path] = Beryl::HostKey.with_entry(current, host.fqdn, key)
        accounts << host.account_name
        log host, "#{dry_run ? "DRY-RUN : à inscrire" : "inscrite"} — #{message}"
      when :same
        log host, "déjà inscrite (#{detail})"
      else
        log host, "REFUSÉE — #{detail}"
        failed += 1
      end
    end

    unless dry_run
      pending.each do |path, content|
        File.write(path, content)
        Beryl::CLI::ConfigGit.commit([path], "host-keys : clés d'hôte inscrites", false)
      end
      Beryl::CLI::SshConfig.run(config_root, [accounts.to_a.sort.join(","), "--apply"]) unless accounts.empty?
    end
    STDERR.puts "beryl host-keys : #{failed} serveur(s) refusé(s) ou injoignable(s)." if failed > 0
    STDERR.puts "beryl host-keys : essai à blanc ; --apply pour écrire." if dry_run && !accounts.empty?
    failed > 0 ? EXIT_FAILED : EXIT_OK
  end

  # {:ok, "<clé>\t<message>"}, {:same, empreinte} ou {:refused, motif}.
  private def check(host : Beryl::Config::ResolvedHost, company : String, known_hosts : String) : {Symbol, String}
    result = host.connection.exec("cat #{REMOTE_PUB}", raise_on_error: false)
    unless result.success?
      return {:refused, "injoignable ou #{REMOTE_PUB} illisible (exit=#{result.exit_code} #{result.stderr.strip[0, 120]?.inspect})"}
    end
    remote = result.stdout.strip
    return {:refused, "#{REMOTE_PUB} n'est pas une clé ed25519"} unless remote.starts_with?("ssh-ed25519 ")
    rkey = remote.split[1]
    fp = Beryl::HostKey.fingerprint(remote)

    if listed = entry(company, host.fqdn)
      return {:same, fp} if listed == rkey
      return {:refused, "le known_hosts de la société porte une AUTRE clé pour #{host.fqdn} (serveur réinstallé hors bootstrap ?) — retirez sa ligne puis relancez"}
    end
    local = local_keys(host.fqdn, known_hosts)
    if local.empty?
      {:ok, "#{remote}\tpremière rencontre, empreinte #{fp} (à comparer à `ssh-keygen -lf #{REMOTE_PUB}` sur le serveur)"}
    elsif local.includes?(rkey)
      {:ok, "#{remote}\tconfirmée par #{known_hosts} (#{fp})"}
    else
      {:refused, "la clé lue sur le serveur (#{fp}) DIFFÈRE de celle de #{known_hosts} : clé changée ou interception — vérifiez avant tout"}
    end
  end

  # Clé ed25519 (base64) de `fqdn` dans le contenu d'un known_hosts, ou nil. Pur.
  def entry(content : String, fqdn : String) : String?
    content.each_line do |line|
      f = line.split
      return f[2] if f.size >= 3 && f[0].split(',').includes?(fqdn) && f[1] == "ssh-ed25519"
    end
  end

  # Clés ed25519 de `name` dans un known_hosts (entrées hachées comprises).
  private def local_keys(name : String, path : String) : Array(String)
    return [] of String unless File.exists?(path)
    buf = IO::Memory.new
    Process.run("ssh-keygen", ["-F", name, "-f", path], output: buf, error: Process::Redirect::Close)
    buf.to_s.each_line.compact_map do |l|
      f = l.split
      f[2] if f.size >= 3 && !l.starts_with?('#') && f[1] == "ssh-ed25519"
    end.to_a
  end

  private def log(host : Beryl::Config::ResolvedHost, message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] #{Beryl.log_tag("beryl host-keys")} #{host.fqdn} : #{message}"
  end
end
