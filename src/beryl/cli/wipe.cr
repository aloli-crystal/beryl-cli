require "option_parser"
require "../inventory"
require "../ssh"

# Sous-commande `beryl wipe <host> --disk=PATH` : efface proprement le
# disque sur un hôte actuellement en rescue Linux.
#
# Cette commande EST destructrice. Elle exige une confirmation explicite
# (taper `OUI` ou `YES` en toutes lettres) sauf si `--force` est passé
# (pour l'automatisation, à manier avec extrême précaution).
#
# Usage typique : après un bootstrap qui a échoué, quand le garde-fou
# `NOGO` du prochain bootstrap refuse de toucher un disque qui porte
# déjà une install BSD. `beryl wipe` permet d'effacer sans passer par
# un reinstall complet du rescue via le panel de l'hébergeur.
module Beryl::CLI::Wipe
  EXIT_OK            = 0
  EXIT_USAGE         = 1
  EXIT_CANCELLED     = 2
  EXIT_UNEXPECTED    = 3
  EXIT_SSH_FAILED    = 4
  EXIT_NOT_IN_RESCUE = 5

  def self.run(
    inventory_path : String,
    args : Array(String),
    confirm_io : IO = STDIN,
  ) : Int32
    target_disk = nil
    force = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl wipe <host> --disk PATH [--force]\n\n" \
                 "Efface un disque sur un hôte en rescue Linux.\n" \
                 "Demande confirmation (taper OUI ou YES) sauf si --force."
      p.on("--disk=PATH", "Disque à effacer (REQUIS, ex. /dev/sda)") { |v| target_disk = v }
      p.on("--force", "N'affiche pas la confirmation interactive (DANGEREUX : à utiliser en script uniquement)") { force = true }
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
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl wipe <host> --disk PATH"
      return EXIT_USAGE
    end
    disk = target_disk
    unless disk
      STDERR.puts "beryl : --disk est requis (ex. --disk=/dev/sda)"
      return EXIT_USAGE
    end

    inventory = Beryl::Inventory.load(inventory_path)
    host = inventory.find(host_name)

    rescue_conn = Beryl::SSH::Connection.new(
      host: host.name,
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

    # Vérifie qu'on est bien sur un rescue Linux (pas une install qu'on
    # wiperait par inadvertance). Si le uname remonte FreeBSD ou rien,
    # on refuse.
    uname = rescue_conn.exec("uname -s", raise_on_error: false).stdout.strip
    unless uname == "Linux"
      STDERR.puts "beryl : #{host.name} n'est pas sur un rescue Linux (uname -s = #{uname.inspect})."
      STDERR.puts "        Lancez d'abord `beryl rescue #{host.name}` avant `beryl wipe`."
      return EXIT_NOT_IN_RESCUE
    end

    # Affiche l'état actuel du disque pour que l'opérateur voie ce
    # qu'il s'apprête à détruire.
    puts
    puts "================================================================"
    puts "ATTENTION : beryl wipe va DÉTRUIRE toutes les données sur"
    puts "  hôte  : #{host.name}"
    puts "  disque : #{disk}"
    puts "================================================================"
    puts
    puts "État actuel du disque :"
    result = rescue_conn.exec("lsblk #{Process.quote(disk)}", raise_on_error: false)
    puts result.stdout
    puts

    pool_result = rescue_conn.exec(
      "zpool import -d #{Process.quote(disk)} 2>/dev/null | grep -E 'pool:|state:' | head -5",
      raise_on_error: false,
    )
    unless pool_result.stdout.strip.empty?
      puts "Pool(s) ZFS détecté(s) :"
      puts pool_result.stdout
      puts
    end

    unless force
      print "Tapez OUI ou YES en toutes lettres pour confirmer : "
      STDOUT.flush
      answer = confirm_io.gets.try(&.strip) || ""
      unless answer == "OUI" || answer == "YES"
        STDERR.puts "beryl : annulé (réponse : #{answer.inspect})."
        return EXIT_CANCELLED
      end
    end

    puts
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] destruction des pools ZFS + labels + GPT + zéros sur #{disk}"
    rescue_conn.exec(wipe_script(disk))

    # Affiche l'état après pour confirmer que c'est vide
    puts
    puts "État du disque après wipe :"
    puts rescue_conn.exec("lsblk #{Process.quote(disk)}").stdout
    after_pool = rescue_conn.exec("zpool import 2>&1", raise_on_error: false).stdout.strip
    puts after_pool.empty? ? "Aucun pool ZFS importable." : after_pool

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] terminé"
    EXIT_OK
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
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

  # Script shell exécuté sur le rescue. Destruction en cascade : export
  # des pools importables, labelclear (au cas où des labels traînent sans
  # pool actif), sgdisk --zap-all pour raser GPT+backup GPT, puis `dd` de
  # 10 Mo de zéros pour écrase MBR + signatures résiduelles.
  def self.wipe_script(disk : String) : String
    <<-BASH
    set -u
    quoted_disk=#{Process.quote(disk)}
    disk_name=$(basename $quoted_disk)
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
