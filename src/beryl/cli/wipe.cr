require "option_parser"
require "../config"
require "ssh"
require "./account_utils"

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
    passes = 0
    hardware = false
    parallel = true
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl wipe <host> (--disk PATH... | --all-declared) [options]"
      p.on("-k PATH", "--disk=PATH", "Disque à effacer (répétable, ex. --disk=/dev/sda --disk=/dev/sdb)") { |v| target_disks << v }
      p.on("-A", "--all-declared", "Efface tous les disques déclarés dans freebsd.zfs.*") { all_declared = true }
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche les commandes sans les exécuter") { dry_run = true }
      p.on("-p N", "--passes=N", "Effacement SÉCURISÉ : réécrit tout le disque N fois (défaut 0 = métadonnées seules, rapide)") do |v|
        n = v.to_i?
        unless n && n >= 0
          STDERR.puts "beryl : --passes attend un entier >= 0 (reçu #{v.inspect})"
          exit EXIT_USAGE
        end
        passes = n
      end
      p.on("-S", "--secure-erase", "Effacement MATÉRIEL adapté au support : nvme format (NVMe), blkdiscard/TRIM (SSD), shred (HDD)") { hardware = true }
      p.on("--sequential", "Effacer les disques l'un après l'autre (défaut : en parallèle, un sous-shell par disque)") { parallel = false }
      p.on("-f", "--force", "Pas de confirmation (DANGER, scripts uniquement)") { force = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl wipe <host> (--disk PATH... | --all-declared)"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    # Résolution des disques à wipe, par ordre de priorité :
    #   1. --disk=PATH explicites (répétables) → union sans doublon
    #   2. Si rien en flag : les disques déclarés dans
    #      freebsd.zfs.* du YAML host. C'est le défaut raisonnable
    #      — le YAML est la source de vérité, et un opérateur qui
    #      lance `beryl wipe HOST` sans flag veut naturellement
    #      wiper les disques qu'il a déclarés pour cet host.
    # `--all-declared` reste accepté pour compat (historiquement
    # explicite), mais a le même effet que le défaut quand le YAML
    # en a. Si le YAML n'a rien ET pas de --disk : erreur franche.
    declared = host.all_declared_disks
    if target_disks.empty?
      if declared.empty?
        STDERR.puts "beryl : aucun disque à effacer."
        STDERR.puts "        Soit passez --disk=/dev/XXX (répétable),"
        STDERR.puts "        soit déclarez les pools ZFS dans #{host.node.source_path}"
        STDERR.puts "        (bloc `freebsd.zfs.*` avec `disks: [...]`)."
        return EXIT_USAGE
      end
      declared.each { |d| target_disks << d }
    elsif all_declared
      # --disk ET --all-declared : union des deux.
      declared.each do |d|
        target_disks << d unless target_disks.includes?(d)
      end
    end

    # Connexion d'infrastructure centralisée : root + IP publique (jamais
    # le vRack), options rescue-safe. Cf. ResolvedHost#rescue_connection.
    rescue_host = host.rescue_ssh_host
    rescue_conn = host.rescue_connection

    probe = rescue_conn.exec("uname -s", raise_on_error: false)
    uname = probe.stdout.strip
    unless uname == "Linux"
      STDERR.puts "beryl : #{Beryl.format_ssh_target(host)} n'est pas sur un rescue Linux (uname -s = #{uname.inspect})"
      # Un uname vide n'est PAS forcément « pas de rescue » : c'est souvent
      # une connexion SSH qui a échoué (auth, mauvaise IP, host key). On
      # remonte le code de sortie + stderr de ssh au lieu de les avaler.
      if uname.empty?
        ssh_err = probe.stderr.strip
        STDERR.puts "        ssh root@#{rescue_host}:#{host.port} (clé #{host.identity_file || "agent"}) → exit #{probe.exit_code}"
        STDERR.puts "        ssh : #{ssh_err}" unless ssh_err.empty?
        STDERR.puts "        Pistes : 255 = SSH KO (auth/clé/host injoignable). La clé du rescue"
        STDERR.puts "                 doit être celle passée à `beryl rescue` (authorized_keys root du rescue)."
        STDERR.puts "                 Vérifiez aussi que #{rescue_host} pointe bien sur l'IP publique du rescue."
      end
      STDERR.puts "        Lancez d'abord `beryl rescue #{host.fqdn}`"
      return EXIT_NOT_IN_RESCUE
    end

    puts
    puts "================================================================"
    puts "ATTENTION : beryl wipe va DÉTRUIRE toutes les données sur"
    puts "  hôte    : #{Beryl.format_ssh_target(host)}"
    puts "  disques :"
    target_disks.each { |d| puts "    - #{d}" }
    if hardware
      puts "  mode    : effacement MATÉRIEL — nvme format / blkdiscard (TRIM) /"
      puts "            shred selon le support détecté sur chaque disque"
    elsif passes > 0
      puts "  mode    : effacement SÉCURISÉ — #{passes} passe(s) d'écriture sur"
      puts "            l'intégralité de chaque disque (peut durer des heures)"
    else
      puts "  mode    : rapide (métadonnées seules : labels ZFS + GPT + tête)"
    end
    if parallel && target_disks.size > 1
      puts "  exécut. : en parallèle (#{target_disks.size} disques simultanément)"
    end
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
      mode_label = hardware ? "matériel (adapté au support)" : (passes > 0 ? "sécurisé — #{passes} passe(s) d'écriture" : "rapide — métadonnées seules")
      exec_label = (parallel && target_disks.size > 1) ? ", en parallèle" : ""
      puts "DRY-RUN : aucune destruction. Plan d'effacement (#{mode_label}#{exec_label}) :"
      puts "  • pools ZFS importables → zpool destroy/export (global, avant les disques)"
      target_disks.each { |disk| puts "  • #{disk} → #{erase_plan(disk, passes, hardware)}" }
      puts "  • puis, par disque → sgdisk --zap-all + 10 Mo de zéros en tête (GPT propre)"
      puts "Pour exécuter : #{Beryl.rerun_hint("wipe", args, replace_host: {raw.not_nil!, "#{host.account_name}/#{host.fqdn}"})}"
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
    mode = hardware ? "matériel" : (passes > 0 ? "sécurisé #{passes} passe(s)" : "rapide (métadonnées)")
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] 6 destruction (#{mode}) sur #{target_disks.join(", ")}"
    # Exécution DÉTACHÉE (setsid) + suivi par polling : un wipe sécurisé de
    # plusieurs To dure des heures ; s'il pendait au bout de la session SSH,
    # la moindre coupure (réseau, veille du laptop) le tuerait à mi-course.
    # Détaché, il survit à la coupure et beryl se reconnecte pour suivre.
    unless detached_exec(rescue_conn, wipe_script_multi(target_disks, passes, hardware, parallel))
      STDERR.puts "beryl : le script de wipe a signalé une erreur (voir la sortie ci-dessus)"
      return EXIT_SSH_FAILED
    end

    puts
    target_disks.each do |disk|
      puts "État de #{disk} après wipe :"
      puts rescue_conn.exec("lsblk #{Process.quote(disk)}").stdout
    end
    after_pool = rescue_conn.exec("zpool import 2>&1", raise_on_error: false).stdout.strip
    puts after_pool.empty? ? "Aucun pool ZFS importable." : after_pool

    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl wipe] 6 terminé"
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

  def self.wipe_script(disk : String, passes : Int32 = 0, hardware : Bool = false) : String
    wipe_script_multi([disk], passes, hardware)
  end

  # Résumé lisible de la stratégie d'effacement d'un disque (pour le
  # dry-run). En mode matériel sur un support non-NVMe, le choix exact
  # (blkdiscard vs shred) se fait à l'exécution selon `rotational`, donc
  # on annonce les deux issues.
  def self.erase_plan(disk : String, passes : Int32, hardware : Bool) : String
    if hardware
      if disk.starts_with?("/dev/nvme")
        "effacement matériel NVMe (nvme format --ses=1)"
      else
        n = passes > 0 ? passes : 1
        "effacement matériel : blkdiscard/TRIM si SSD, sinon shred #{n} passe(s) — choisi sur le rescue"
      end
    elsif passes > 0
      "réécriture intégrale #{passes} passe(s) (shred)"
    else
      "métadonnées seules (labels ZFS)"
    end
  end

  DETACH_SH   = "/tmp/beryl-wipe.sh"
  DETACH_LOG  = "/tmp/beryl-wipe.log"
  DETACH_RC   = "/tmp/beryl-wipe.rc"
  DETACH_MARK = "__BERYL_RC__"

  # Commande qui lance le script wipe en session DÉTACHÉE (`setsid`) : le
  # travail survit à une coupure SSH (un shred de plusieurs To dépasse
  # largement la durée de vie d'une session). Sortie redirigée dans un log,
  # code de sortie écrit dans un fichier `.rc` à la fin. Tous les fds sont
  # détachés du canal SSH (`</dev/null >/dev/null`) pour que l'appel rende
  # la main immédiatement.
  def self.detach_launch_cmd : String
    "rm -f #{DETACH_RC} #{DETACH_LOG}; " \
    "setsid sh -c 'sh #{DETACH_SH} > #{DETACH_LOG} 2>&1; echo $? > #{DETACH_RC}' " \
    "</dev/null >/dev/null 2>&1 & echo lancé"
  end

  # Commande de suivi : renvoie les octets du log au-delà de `offset`, puis
  # un marqueur et le contenu du `.rc` (vide tant que le wipe tourne). Un
  # appel court et indépendant → reconnexion-tolérant.
  def self.detach_poll_cmd(offset : Int32) : String
    "tail -c +#{offset + 1} #{DETACH_LOG} 2>/dev/null; " \
    "printf '#{DETACH_MARK}'; cat #{DETACH_RC} 2>/dev/null"
  end

  # Lance `script` sur le rescue en DÉTACHÉ puis suit sa progression par
  # petits appels SSH successifs. Si un appel échoue (coupure réseau), le
  # wipe CONTINUE côté rescue (détaché) et beryl réessaie. Renvoie true si
  # le script s'est terminé avec le code 0.
  def self.detached_exec(conn : SSH::Connection, script : String, poll : Time::Span = 8.seconds) : Bool
    conn.write_file(DETACH_SH, script)
    conn.exec(detach_launch_cmd, raise_on_error: false)
    offset = 0
    loop do
      probe = conn.exec(detach_poll_cmd(offset), raise_on_error: false)
      unless probe.success?
        STDERR.puts "beryl : connexion au rescue perdue — le wipe CONTINUE (détaché), reprise dans #{poll.total_seconds.to_i}s…"
        sleep poll
        next
      end
      out = probe.stdout
      idx = out.rindex(DETACH_MARK) || out.size
      chunk = out[0...idx]
      print chunk
      STDOUT.flush
      offset += chunk.bytesize
      rc_str = idx < out.size ? out[(idx + DETACH_MARK.size)..].strip : ""
      return rc_str == "0" unless rc_str.empty?
      sleep poll
    end
  end

  # Script shell qui détruit les pools ZFS importables (une seule fois,
  # avant les boucles disque) puis efface chaque disque passé en
  # argument. Le `zpool destroy`/`export` se fait globalement parce
  # qu'un même pool peut couvrir plusieurs disques : essayer de
  # l'attaquer disque par disque rate ou duplique les opérations.
  #
  # Trois niveaux d'effacement (du plus rapide au plus sûr) :
  #
  # * défaut (`passes` 0, `hardware` false) : métadonnées seules
  #   (labels ZFS + GPT + 10 Mo de tête). Rapide, données récupérables.
  # * `passes` >= 1 : réécrit l'intégralité du disque N fois via `shred`
  #   (fallback `dd if=/dev/urandom`). Lent (taille × passes).
  # * `hardware` true : effacement *matériel* adapté au support détecté
  #   sur le rescue — `nvme format` (NVMe), `blkdiscard` TRIM (SSD), et
  #   repli `shred` (HDD rotatif, sans support matériel). Quasi instantané
  #   sur SSD/NVMe. `passes` sert alors de nombre de passes du repli HDD
  #   (défaut 1).
  #
  # `parallel` : avec plusieurs disques, lance un sous-shell par disque
  # (devices indépendants → gain de temps réel, surtout pour les HDD en
  # shred). La destruction des pools ZFS reste AVANT et séquentielle (un
  # pool peut couvrir plusieurs disques). On attend tous les sous-shells
  # et on propage un échec si l'un d'eux a échoué.
  def self.wipe_script_multi(disks : Array(String), passes : Int32 = 0, hardware : Bool = false, parallel : Bool = false) : String
    raise ArgumentError.new("wipe_script_multi : disks vide") if disks.empty?
    raise ArgumentError.new("wipe_script_multi : passes négatif") if passes < 0
    fallback_passes = passes > 0 ? passes : 1
    bodies = disks.map do |disk|
      quoted = Process.quote(disk)
      erase =
        if hardware
          "\n" + hardware_erase_block(disk, quoted, fallback_passes)
        elsif passes > 0
          "\n" + overwrite_block(disk, quoted, passes)
        else
          ""
        end
      <<-BASH
      echo "--- wipe #{disk} ---"
      zpool labelclear -f #{quoted} 2>/dev/null || true
      for n in 1 2 3 4 5 6 7 8 9; do
        zpool labelclear -f #{quoted}${n} 2>/dev/null || true
      done#{erase}
      sgdisk --zap-all #{quoted} 2>&1 | tail -3
      dd if=/dev/zero of=#{quoted} bs=1M count=10 conv=notrunc 2>&1 | tail -1
      BASH
    end

    disk_section =
      if parallel && bodies.size > 1
        wrapped = bodies.map { |b| "(\n#{b}\n) &\n__pids=\"$__pids $!\"" }.join("\n")
        <<-BASH
        # Effacement EN PARALLÈLE : un sous-shell par disque.
        __rc=0
        __pids=""
        #{wrapped}
        for __p in $__pids; do
          wait "$__p" || __rc=1
        done
        exit $__rc
        BASH
      else
        bodies.join("\n")
      end

    <<-BASH
    set -u
    # Détruit d'abord tous les pools ZFS importables (un pool peut
    # recouvrir plusieurs disques, on ne peut pas le faire par disque).
    for p in $(zpool import 2>/dev/null | awk '/^ *pool:/{print $2}'); do
      echo "destroy zpool $p"
      zpool destroy "$p" 2>/dev/null || zpool export -f "$p" 2>/dev/null || true
    done
    #{disk_section}
    BASH
  end

  # Réécriture logique intégrale du disque : `shred -n passes`, avec
  # repli `dd if=/dev/urandom` en boucle si shred est absent du rescue.
  private def self.overwrite_block(disk : String, quoted : String, passes : Int32) : String
    <<-SH
    echo "effacement sécurisé : #{passes} passe(s) sur #{disk} (peut être très long)"
    if command -v shred >/dev/null 2>&1; then
      shred -v -f -n #{passes} #{quoted}
    else
      i=1
      while [ "$i" -le #{passes} ]; do
        echo "passe $i/#{passes} (dd urandom) sur #{disk}"
        dd if=/dev/urandom of=#{quoted} bs=4M conv=notrunc status=progress 2>&1 | tail -1 || true
        i=$((i + 1))
      done
    fi
    SH
  end

  # Effacement *matériel*, choisi à l'exécution selon le support réel :
  #   NVMe              → `nvme format --ses=1` (efface la zone user)
  #   SSD (rotational 0) → `blkdiscard` (TRIM intégral)
  #   HDD rotatif        → pas de secure-erase matériel sûr → repli `shred`
  # Chaque commande matérielle retombe sur `shred -n fallback_passes` si
  # elle échoue (outil absent, disque gelé/frozen, contrôleur récalcitrant).
  private def self.hardware_erase_block(disk : String, quoted : String, fallback_passes : Int32) : String
    <<-SH
    echo "secure-erase matériel de #{disk}"
    __b=$(basename #{quoted})
    if echo #{quoted} | grep -q '^/dev/nvme'; then
      echo "  support NVMe → nvme format --ses=1"
      nvme format #{quoted} --ses=1 --force \\
        || nvme format #{quoted} -s 1 \\
        || { echo "  nvme format KO → repli shred"; shred -v -f -n #{fallback_passes} #{quoted}; }
    elif [ -e "/sys/block/$__b/queue/rotational" ] && [ "$(cat /sys/block/$__b/queue/rotational)" = "0" ]; then
      echo "  support SSD (non rotatif) → blkdiscard (TRIM)"
      blkdiscard -f #{quoted} \\
        || { echo "  blkdiscard KO → repli shred"; shred -v -f -n #{fallback_passes} #{quoted}; }
    else
      echo "  support HDD rotatif : pas de secure-erase matériel → shred #{fallback_passes} passe(s)"
      shred -v -f -n #{fallback_passes} #{quoted}
    fi
    SH
  end
end
