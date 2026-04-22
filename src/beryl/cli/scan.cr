require "option_parser"
require "../inventory"
require "../ssh"

# Sous-commande `beryl scan <host>` : se connecte à un serveur en rescue
# Linux, détecte les disques physiques, propose interactivement leur
# usage (inclusion/exclusion + mode RAID ZFS) et génère un squelette
# YAML prêt à déposer dans `hosts/<host>.yml`.
#
# Objectif : éviter les typos de `/dev/sdX` et les « combien de disques
# a ce serveur déjà ? » avant un `beryl bootstrap`. La sortie est un
# fichier YAML minimal pour le bloc `freebsd:` + quelques champs du
# host (provider, groups).
#
# Usage :
#
#   beryl rescue rails01.aloli.fr          # met en rescue
#   beryl scan rails01.aloli.fr            # affiche + génère sur stdout
#   beryl scan rails01.aloli.fr --write hosts/rails01.aloli.fr.yml
#
# Non-interactif (pour scripts) :
#
#   beryl scan rails01.aloli.fr --disks=sda,sdb --raid=mirror --groups=rails-servers
#
# La commande n'écrit JAMAIS sur la cible : lecture seule. Elle génère
# juste un YAML local.
module Beryl::CLI::Scan
  EXIT_OK         =  0
  EXIT_USAGE      =  1
  EXIT_SSH_FAILED =  2
  EXIT_UNEXPECTED =  3
  EXIT_NO_DISKS   = 15
  EXIT_ABORTED    = 16

  # Un disque physique détecté sur la cible. Rempli depuis `lsblk -b -d`.
  struct Disk
    getter name : String # ex. "sda"
    getter size_bytes : Int64
    getter model : String
    getter is_ssd : Bool      # ROTA=0 → SSD/NVMe, ROTA=1 → HDD rotatif
    getter transport : String # "sata", "nvme", "sas"…

    def initialize(@name, @size_bytes, @model, @is_ssd, @transport)
    end

    def dev_path : String
      "/dev/#{@name}"
    end

    def human_size : String
      case @size_bytes
      when .>= 1_000_000_000_000 then "%.2f TB" % (@size_bytes / 1_000_000_000_000.0)
      when .>= 1_000_000_000     then "%.2f GB" % (@size_bytes / 1_000_000_000.0)
      when .>= 1_000_000         then "%.2f MB" % (@size_bytes / 1_000_000.0)
      else                            "#{@size_bytes} B"
      end
    end

    def kind : String
      @is_ssd ? "SSD/NVMe" : "HDD"
    end
  end

  def self.run(inventory_path : String, args : Array(String)) : Int32
    positional = [] of String
    write_path : String? = nil # chemin explicite si --write=FILE
    write_auto = false         # vrai si --write sans argument
    disks_flag : String? = nil
    raid_flag : String? = nil
    groups_flag : String? = nil
    hostname_flag : String? = nil
    non_interactive = false

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl scan <host> [options]\n\n" \
                 "Se connecte au rescue, liste les disques, propose un YAML d'inventaire.\n" \
                 "Sans --write : affiche le YAML sur stdout.\n" \
                 "Avec --write seul : écrit dans hosts/<nom>.yml (mode arborescent).\n" \
                 "Avec --write=FILE : écrit dans le chemin demandé."
      # `--write` sans argument = auto-mode hosts/<name>.yml.
      # `--write=FILE` = chemin explicite.
      p.on("--write", "Écrit automatiquement dans hosts/<nom>.yml") { write_auto = true }
      p.on("--write=FILE", "Écrit dans le fichier au chemin donné") { |v| write_path = File.expand_path(v, home: true) }
      p.on("--disks=LIST", "Disques à inclure (liste séparée par virgules, ex: sda,sdb). Non-interactif.") { |v| disks_flag = v }
      p.on("--raid=MODE", "Mode ZFS (stripe|mirror|raidz|raidz2|raidz3). Non-interactif.") { |v| raid_flag = v }
      p.on("--groups=LIST", "Liste de groupes à déclarer (ex: aloli-admin,rails-servers)") { |v| groups_flag = v }
      p.on("--hostname=NAME", "Hostname cible (défaut : nom court de l'hôte)") { |v| hostname_flag = v }
      p.on("--non-interactive", "Refuse toute invite. Les flags --disks et --raid doivent être fournis.") { non_interactive = true }
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
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl scan <host>"
      return EXIT_USAGE
    end

    inventory = Beryl::Inventory.load(inventory_path)
    host = inventory.find(host_name)
    conn = host.rescue_connection

    # Log explicite du nom effectif utilisé pour la connexion. Si le
    # host est OVH, on passe par le FQDN OVH (qui résout toujours)
    # plutôt que par le nom custom qui peut ne pas encore être dans
    # le DNS — c'est la correspondance « nom personnalisé = nom système ».
    if conn.host == host.name
      log "connexion SSH à #{host.name} (user=#{conn.user}, port=#{conn.port})..."
    else
      log "connexion SSH à #{host.name} (= #{conn.host} côté OVH, user=#{conn.user}, port=#{conn.port})..."
    end
    disks = read_disks(conn)
    if disks.empty?
      STDERR.puts "beryl : aucun disque physique détecté sur #{host.name}."
      return EXIT_NO_DISKS
    end

    STDERR.puts
    STDERR.puts "Disques détectés sur #{host.name} :"
    STDERR.puts disks_table(disks)
    STDERR.puts

    chosen_disks = pick_disks(disks, disks_flag, non_interactive)
    raid = pick_raid(chosen_disks.size, raid_flag, non_interactive)
    hnf = hostname_flag
    hostname = hnf ? hnf : default_hostname(host.name)
    gf = groups_flag
    groups_str = gf ? gf : (non_interactive ? "" : ask("Groupes à hériter (séparés par virgules, vide = aucun) [aloli-admin,rails-servers] : ", default: ""))
    groups = groups_str.split(",").map(&.strip).reject(&.empty?)

    yaml = render_yaml(host, hostname, chosen_disks, raid, groups)

    target = resolve_write_target(write_path, write_auto, inventory_path, host.name)
    if target
      # Garde-fou : si le fichier existe déjà, on demande confirmation
      # (ou on refuse si --non-interactive). Évite d'écraser un host
      # existant que l'opérateur aurait personnalisé à la main.
      if File.exists?(target)
        if non_interactive
          STDERR.puts "beryl : #{target} existe déjà (refus en --non-interactive, ajoutez --force si besoin)."
          return EXIT_USAGE
        end
        answer = ask("#{target} existe déjà. Écraser ? [o/N] : ", default: "N")
        unless answer.downcase.starts_with?("o") || answer.downcase.starts_with?("y")
          STDERR.puts "beryl : abandon, fichier conservé."
          return EXIT_ABORTED
        end
      end
      Dir.mkdir_p(File.dirname(target))
      File.write(target, yaml)
      log "YAML écrit dans #{target}"
      log "Relisez et éditez à la main si besoin, puis lancez : beryl bootstrap #{host.name}"
    else
      STDERR.puts "--- YAML suggéré (copiez dans hosts/#{host.name}.yml) ---"
      print yaml
      STDERR.puts "--- fin ---"
    end
    EXIT_OK
  rescue ex : Beryl::Inventory::NotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::SSH::CommandFailed
    STDERR.puts "beryl : SSH échoué sur le rescue — #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex : Aborted
    STDERR.puts "beryl : abandon demandé par l'utilisateur."
    EXIT_ABORTED
  rescue ex : File::NotFoundError
    STDERR.puts "beryl : inventaire introuvable : #{inventory_path}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  class Aborted < Exception
  end

  # Récupère la liste des disques via `lsblk -b -d -n -o NAME,SIZE,MODEL,ROTA,TRAN,VENDOR`.
  # Les flags :
  #   -b : tailles en octets (pour un parse propre sans suffixes)
  #   -d : pas de descendants (pas de partitions, juste les disques parents)
  #   -n : pas d'entête
  #   -o : colonnes demandées
  def self.read_disks(conn : Beryl::SSH::Connection) : Array(Disk)
    result = conn.exec("lsblk -b -d -n -o NAME,SIZE,MODEL,ROTA,TRAN,VENDOR 2>/dev/null | cat")
    parse_lsblk(result.stdout)
  end

  # Parse la sortie `lsblk -b -d -n -o NAME,SIZE,MODEL,ROTA,TRAN,VENDOR`.
  # Ignore les lignes vides, les RAM disks (`zram*`, `loop*`) et les
  # périphériques sans taille plausible (< 1 Go, sinon on pique des
  # clés USB / lecteurs CD au passage).
  def self.parse_lsblk(output : String) : Array(Disk)
    disks = [] of Disk
    output.each_line do |raw|
      line = raw.strip
      next if line.empty?
      # Split sur whitespace : NAME peut contenir des chiffres mais pas
      # d'espaces, SIZE est un int, ROTA est 0 ou 1, TRAN est un mot
      # court. MODEL peut contenir des espaces → on le récupère en milieu.
      fields = line.split(/\s+/, limit: 6)
      next if fields.size < 4
      name = fields[0]
      next if name.starts_with?("zram") || name.starts_with?("loop") || name.starts_with?("sr")
      size = fields[1].to_i64?
      next unless size
      next if size < 1_000_000_000 # < 1 Go : pas un disque sérieux

      # ROTA / TRAN sont tantôt en positions fixes, tantôt manquants. On
      # balaye depuis la fin pour être robuste.
      rota = nil
      tran = ""
      vendor = ""
      model_parts = [] of String
      # Reparse avec séparation plus brute sur les 2/3 derniers champs.
      # Heuristique : le dernier champ est le VENDOR (ou vide), avant
      # c'est TRAN (sata, nvme, sas...), avant c'est ROTA (0/1), le
      # reste au milieu est le MODEL.
      tokens = line.split(/\s+/)
      if tokens.size >= 4
        # On cherche le token ROTA : un "0" ou "1" isolé. Souvent à
        # l'avant-dernier ou antépénultième.
        rota_idx = nil
        (tokens.size - 1).downto(2) do |i|
          if tokens[i] == "0" || tokens[i] == "1"
            rota_idx = i
            break
          end
        end
        if rota_idx
          rota = tokens[rota_idx] == "0"
          model_parts = tokens[2...rota_idx]
          after = tokens[(rota_idx + 1)..]
          tran = after[0]? || ""
          vendor = after[1..]?.try(&.join(" ")) || ""
        else
          # Pas de ROTA trouvé : modèle = tout ce qui reste après NAME/SIZE
          model_parts = tokens[2..]
        end
      end
      model = model_parts.join(" ").strip
      model = "#{vendor} #{model}".strip unless vendor.empty?
      is_ssd = rota.nil? ? false : rota # ROTA=0 → SSD

      disks << Disk.new(
        name: name,
        size_bytes: size,
        model: model.empty? ? "(inconnu)" : model,
        is_ssd: is_ssd,
        transport: tran,
      )
    end
    disks
  end

  # Tableau texte des disques pour affichage stderr.
  def self.disks_table(disks : Array(Disk)) : String
    rows = disks.map_with_index do |d, i|
      "  ##{(i + 1).to_s.rjust(2)}  #{d.name.ljust(6)}  #{d.human_size.rjust(10)}  #{d.kind.ljust(9)}  #{d.transport.ljust(6)}  #{d.model}"
    end
    rows.join('\n')
  end

  # Sélection des disques : soit via --disks=sda,sdb (ou indices),
  # soit prompt interactif. Retourne la liste des Disk choisis.
  private def self.pick_disks(
    all : Array(Disk),
    flag : String?,
    non_interactive : Bool,
  ) : Array(Disk)
    if flag
      return resolve_disk_selection(all, flag)
    end
    if non_interactive
      raise "--non-interactive requiert --disks=LIST"
    end
    answer = ask(
      "Disques à utiliser pour le pool ZFS ? (liste : 1,2 | sda,sdb | 'all') [all] : ",
      default: "all",
    )
    resolve_disk_selection(all, answer)
  end

  # Résout une sélection "1,2", "sda,sdb" ou "all" en Array(Disk).
  # Accepte mélange d'indices et de noms. Lève une Aborted si entrée
  # vide et qu'aucune sélection raisonnable ne s'applique.
  def self.resolve_disk_selection(all : Array(Disk), answer : String) : Array(Disk)
    answer = answer.strip
    raise Aborted.new if answer.empty?
    return all if answer.downcase == "all"

    wanted = answer.split(",").map(&.strip).reject(&.empty?)
    result = [] of Disk
    wanted.each do |token|
      if token =~ /^\d+$/
        idx = token.to_i - 1
        raise "index disque invalide : #{token}" unless (0...all.size).includes?(idx)
        result << all[idx]
      else
        disk = all.find { |d| d.name == token }
        raise "disque inconnu : #{token}" unless disk
        result << disk
      end
    end
    raise Aborted.new if result.empty?
    result
  end

  # Validation + prompt du mode RAID en fonction du nombre de disques.
  private def self.pick_raid(count : Int32, flag : String?, non_interactive : Bool) : String
    default = raid_default_for(count)
    if flag
      unless Beryl::Bootstrap::QemuInRescue::VALID_RAID.includes?(flag)
        raise "raid invalide : #{flag} (attendu : #{Beryl::Bootstrap::QemuInRescue::VALID_RAID.join(", ")})"
      end
      return flag
    end
    if non_interactive
      return default
    end
    answer = ask(
      "Mode RAID ZFS [stripe|mirror|raidz|raidz2|raidz3] (défaut: #{default}) : ",
      default: default,
    )
    unless Beryl::Bootstrap::QemuInRescue::VALID_RAID.includes?(answer)
      raise "raid invalide : #{answer}"
    end
    answer
  end

  # Défaut de RAID en fonction du nombre de disques :
  #  1 disque           → stripe (trivial)
  #  2 disques          → mirror (sécurité sans perte d'espace surprise)
  #  3+ disques         → stripe (feedback_raid_strategy_rails : backups
  #                       bétonnés > redondance disque côté Aloli)
  def self.raid_default_for(count : Int32) : String
    case count
    when 1 then "stripe"
    when 2 then "mirror"
    else        "stripe"
    end
  end

  # Génère le YAML à poser dans hosts/<host>.yml.
  def self.render_yaml(
    host : Beryl::Host,
    hostname : String,
    disks : Array(Disk),
    raid : String,
    groups : Array(String),
  ) : String
    String.build do |io|
      io << "# Généré par `beryl scan " << host.name << "` le "
      io << Beryl.format_timestamp(Time.local) << '\n'
      io << "# Relisez chaque champ avant `beryl bootstrap`. Les clés SSH,\n"
      io << "# le pool_name, le swap et le timezone ne sont PAS détectés\n"
      io << "# automatiquement (règle Aloli : pas de défaut silencieux).\n\n"
      if host.provider
        io << "provider: " << host.provider << '\n'
        # Restitue le bloc provider déjà connu dans l'inventaire pour
        # préserver service_name/ssh_key_name — c'est ce qui permet à
        # `beryl rescue` et `beryl bootstrap` de piloter l'API.
        if host.provider == "ovh" && host.ovh_service_name
          io << "ovh:\n"
          io << "  service_name: " << host.ovh_service_name << '\n'
          if key = host.ovh_ssh_key_name
            io << "  ssh_key_name: " << key << '\n'
          end
        elsif host.provider == "scaleway" && host.scaleway_server_id
          io << "scaleway:\n"
          if zone = host.scaleway_zone
            io << "  zone: " << zone << '\n'
          end
          io << "  server_id: " << host.scaleway_server_id << '\n'
        end
      end
      unless groups.empty?
        io << "\ngroups:\n"
        groups.each { |g| io << "  - " << g << '\n' }
      end
      io << "\nfreebsd:\n"
      io << "  hostname: " << hostname << '\n'
      io << "  disks:\n"
      disks.each { |d| io << "    - " << d.dev_path << "  # " << d.human_size << " " << d.kind << " " << d.model << '\n' }
      io << "  raid: " << raid << '\n'
      io << "  # timezone, pool_name, swap_gb, users, packages, sudoers\n"
      io << "  # arrivent idéalement depuis un groupe (groups/*.yml).\n"
    end
  end

  # Nom court d'un hôte (première partie avant le premier `.`).
  def self.default_hostname(fqdn : String) : String
    fqdn.split('.').first
  end

  # Résout le chemin où écrire le YAML en fonction des flags :
  #  - `--write=FILE` : chemin explicite fourni par l'opérateur
  #  - `--write` seul : hosts/<name>.yml dans le dossier inventaire
  #    (si c'est un dossier) ou dans ./hosts/<name>.yml (si inventory.yml)
  #  - aucun flag : nil (affichage stdout)
  def self.resolve_write_target(
    explicit_path : String?,
    auto_mode : Bool,
    inventory_path : String,
    host_name : String,
  ) : String?
    return explicit_path if explicit_path
    return nil unless auto_mode

    # Mode auto : cible `hosts/<name>.yml`. Si l'inventaire est un
    # dossier, on écrit dedans. Sinon (fichier unique `inventory.yml`),
    # on écrit à côté, dans ./hosts/<name>.yml — ce qui amorce
    # proprement le passage au mode arborescent.
    base_dir = if File.directory?(inventory_path)
                 inventory_path
               else
                 dir = File.dirname(inventory_path)
                 dir.empty? ? "." : dir
               end
    File.join(base_dir, "hosts", "#{host_name}.yml")
  end

  # Prompt stdin → chaîne ou valeur par défaut si entrée vide.
  private def self.ask(prompt : String, default : String) : String
    STDERR.print prompt
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    answer = line.chomp.strip
    answer.empty? ? default : answer
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl scan] #{message}"
  end
end
