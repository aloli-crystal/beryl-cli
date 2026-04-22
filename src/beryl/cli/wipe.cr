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
    target_disk = nil
    force = false
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl wipe <host> --disk PATH [options]"
      p.on("-k PATH", "--disk=PATH", "Disque à effacer (REQUIS, ex. /dev/sda)") { |v| target_disk = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-f", "--force", "Pas de confirmation (DANGER, scripts uniquement)") { force = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    host_name = positional.first?
    unless host_name
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl wipe <host> --disk PATH"
      return EXIT_USAGE
    end
    disk = target_disk
    unless disk
      STDERR.puts "beryl : --disk est requis (ex. --disk=/dev/sda)"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, domain_hint: domain_hint)
    root.env_file.apply_to_env(host.domain_name)

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
    puts "  hôte  : #{Beryl.format_ssh_target(host)}"
    puts "  disque : #{disk}"
    puts "================================================================"
    puts
    puts "État actuel du disque :"
    puts rescue_conn.exec("lsblk #{Process.quote(disk)}", raise_on_error: false).stdout
    puts

    pool_out = rescue_conn.exec(
      "zpool import -d #{Process.quote(disk)} 2>/dev/null | grep -E 'pool:|state:' | head -5",
      raise_on_error: false,
    ).stdout
    unless pool_out.strip.empty?
      puts "Pool(s) ZFS détecté(s) :"
      puts pool_out
      puts
    end

    unless force
      print "Tapez OUI ou YES en toutes lettres pour confirmer : "
      STDOUT.flush
      answer = confirm_io.gets.try(&.strip) || ""
      unless answer == "OUI" || answer == "YES"
        STDERR.puts "beryl : annulé (réponse : #{answer.inspect})"
        return EXIT_CANCELLED
      end
    end

    puts
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] destruction sur #{disk}"
    rescue_conn.exec(wipe_script(disk))

    puts
    puts "État du disque après wipe :"
    puts rescue_conn.exec("lsblk #{Process.quote(disk)}").stdout
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
    <<-BASH
    set -u
    quoted_disk=#{Process.quote(disk)}
    for p in $(zpool import 2>/dev/null | awk '/^ *pool:/{print $2}'); do
      echo "destroy zpool $p"
      zpool destroy "$p" 2>/dev/null || zpool export -f "$p" 2>/dev/null || true
    done
    zpool labelclear -f $quoted_disk 2>/dev/null || true
    for n in 1 2 3 4 5 6 7 8 9; do
      zpool labelclear -f ${quoted_disk}${n} 2>/dev/null || true
    done
    sgdisk --zap-all $quoted_disk 2>&1 | tail -3
    dd if=/dev/zero of=$quoted_disk bs=1M count=10 conv=notrunc 2>&1 | tail -1
    BASH
  end
end
