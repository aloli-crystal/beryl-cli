require "option_parser"
require "../config"
require "../ssh"

# Sous-commande `beryl wipe <host> --disk PATH` : efface un disque sur
# un hôte actuellement en rescue Linux. Commande destructrice, exige
# une confirmation explicite (`OUI` ou `YES`) sauf `--force`.
module Beryl::CLI::Wipe
  EXIT_OK            = 0
  EXIT_USAGE         = 1
  EXIT_CANCELLED     = 2
  EXIT_UNEXPECTED    = 3
  EXIT_SSH_FAILED    = 4
  EXIT_NOT_IN_RESCUE = 5

  def self.run(config_root : String, args : Array(String), confirm_io : IO = STDIN) : Int32
    target_disks = [] of String
    all_declared = false
    force = false
    dry_run = false
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl wipe <host> (--disk PATH... | --all-declared) [options]"
      p.on("-k PATH", "--disk=PATH", "Disque à effacer (répétable, ex. --disk=/dev/sda --disk=/dev/sdb)") { |v| target_disks << v }
      p.on("-a", "--all-declared", "Efface tous les disques déclarés dans freebsd.zfs.*") { all_declared = true }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche les commandes sans les exécuter") { dry_run = true }
      p.on("-f", "--force", "Pas de confirmation (DANGER, scripts uniquement)") { force = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl wipe <host> (--disk PATH... | --all-declared)"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    # Fusion --disk et --all-declared : union sans doublon, ordre
    # déterministe (les --disk explicites d'abord, puis les déclarés
    # qui n'y sont pas encore).
    if all_declared
      declared = host.all_declared_disks
      if declared.empty?
        STDERR.puts "beryl : --all-declared : aucun disque déclaré dans freebsd.zfs.* pour #{host.fqdn}"
        STDERR.puts "        (soit vous ajoutez les pools dans le YAML, soit vous listez les disques avec --disk)"
        return EXIT_USAGE
      end
      declared.each do |d|
        target_disks << d unless target_disks.includes?(d)
      end
    end

    if target_disks.empty?
      STDERR.puts "beryl : aucun disque à effacer. Passez --disk=/dev/XXX (répétable) ou --all-declared."
      return EXIT_USAGE
    end

    rescue_conn = Beryl::SSH::Connection.new(
      host: host.ssh_host,
      user: host.user,
      port: host.port,
      identity_file: host.identity_file,
      options: {
        "StrictHostKeyChecking" => "no",
        "UserKnownHostsFile"    => "/dev/null",
        "LogLevel"              => "ERROR",
        "BatchMode"             => "yes",
      },
    )

    uname = rescue_conn.exec("uname -s", raise_on_error: false).stdout.strip
    unless uname == "Linux"
      STDERR.puts "beryl : #{Beryl.format_ssh_target(host)} n'est pas sur un rescue Linux (uname -s = #{uname.inspect})"
      STDERR.puts "        Lancez d'abord `beryl rescue #{host.fqdn}`"
      return EXIT_NOT_IN_RESCUE
    end

    puts
    puts "================================================================"
    puts "ATTENTION : beryl wipe va DÉTRUIRE toutes les données sur"
    puts "  hôte    : #{Beryl.format_ssh_target(host)}"
    puts "  disques :"
    target_disks.each { |d| puts "    - #{d}" }
    puts "================================================================"
    puts

    target_disks.each do |disk|
      puts "État actuel de #{disk} :"
      puts rescue_conn.exec("lsblk #{Process.quote(disk)}", raise_on_error: false).stdout
      pool_out = rescue_conn.exec(
        "zpool import -d #{Process.quote(disk)} 2>/dev/null | grep -E 'pool:|state:' | head -5",
        raise_on_error: false,
      ).stdout
      unless pool_out.strip.empty?
        puts "Pool(s) ZFS détecté(s) sur #{disk} :"
        puts pool_out
      end
      puts
    end

    if dry_run
      puts
      puts "DRY-RUN : aucune destruction. Script qui serait exécuté via SSH :"
      puts "─" * 60
      puts wipe_script_multi(target_disks)
      puts "─" * 60
      puts "Pour exécuter : #{Beryl.rerun_hint("wipe", args)}"
      return EXIT_OK
    end

    unless force
      print "Tapez OUI ou YES en toutes lettres pour confirmer l'effacement des #{target_disks.size} disque(s) : "
      STDOUT.flush
      answer = confirm_io.gets.try(&.strip) || ""
      unless answer == "OUI" || answer == "YES"
        STDERR.puts "beryl : annulé (réponse : #{answer.inspect})"
        return EXIT_CANCELLED
      end
    end

    puts
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] destruction sur #{target_disks.join(", ")}"
    rescue_conn.exec(wipe_script_multi(target_disks))

    puts
    target_disks.each do |disk|
      puts "État de #{disk} après wipe :"
      puts rescue_conn.exec("lsblk #{Process.quote(disk)}").stdout
    end
    after_pool = rescue_conn.exec("zpool import 2>&1", raise_on_error: false).stdout.strip
    puts after_pool.empty? ? "Aucun pool ZFS importable." : after_pool

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] terminé"
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
  rescue ex : Beryl::SSH::CommandFailed
    STDERR.puts "beryl : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  def self.wipe_script(disk : String) : String
    wipe_script_multi([disk])
  end

  # Script shell qui détruit les pools ZFS importables (une seule fois,
  # avant les boucles disque) puis efface chaque disque passé en
  # argument. Le `zpool destroy`/`export` se fait globalement parce
  # qu'un même pool peut couvrir plusieurs disques : essayer de
  # l'attaquer disque par disque rate ou duplique les opérations.
  def self.wipe_script_multi(disks : Array(String)) : String
    raise ArgumentError.new("wipe_script_multi : disks vide") if disks.empty?
    per_disk = disks.map do |disk|
      quoted = Process.quote(disk)
      <<-BASH
      echo "--- wipe #{disk} ---"
      zpool labelclear -f #{quoted} 2>/dev/null || true
      for n in 1 2 3 4 5 6 7 8 9; do
        zpool labelclear -f #{quoted}${n} 2>/dev/null || true
      done
      sgdisk --zap-all #{quoted} 2>&1 | tail -3
      dd if=/dev/zero of=#{quoted} bs=1M count=10 conv=notrunc 2>&1 | tail -1
      BASH
    end.join("\n")
    <<-BASH
    set -u
    # Détruit d'abord tous les pools ZFS importables (un pool peut
    # recouvrir plusieurs disques, on ne peut pas le faire par disque).
    for p in $(zpool import 2>/dev/null | awk '/^ *pool:/{print $2}'); do
      echo "destroy zpool $p"
      zpool destroy "$p" 2>/dev/null || zpool export -f "$p" 2>/dev/null || true
    done
    #{per_disk}
    BASH
  end
end
