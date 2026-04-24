require "option_parser"
require "ovh-api/ovh_api"
require "../config"
require "../providers"
require "ssh"
require "./credentials"
require "./dns_setup"
require "./provider_shortcut"

# Sous-commande `beryl scan <host>` : se connecte au rescue Linux,
# détecte les disques, propose un YAML pour le fichier host.
#
# Forme typique :
#   beryl scan ns3156789.ip-51-83-6.eu --domain=aloli.net --dns --write
#
# Avec `--dns` : pose les records DNS (CNAME vers le FQDN OVH),
# le reverse DNS IPv4/IPv6 et renomme le serveur côté panel OVH.
# Avec `--write` : écrit ~/.beryl/<domaine>/<nom>.yml (nom court
# demandé interactivement ou via --hostname).
module Beryl::CLI::Scan
  EXIT_OK           =  0
  EXIT_USAGE        =  1
  EXIT_SSH_FAILED   =  2
  EXIT_UNEXPECTED   =  3
  EXIT_BAD_CREDS    =  4
  EXIT_API_ERROR    =  7
  EXIT_NO_DISKS     = 15
  EXIT_ABORTED      = 16
  EXIT_INSUFFICIENT = 17

  # Un disque physique détecté sur la cible (lsblk -b -d).
  struct Disk
    getter name : String
    getter size_bytes : Int64
    getter model : String
    getter is_ssd : Bool
    getter transport : String

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

  class Aborted < Exception
  end

  class MissingDediboxServerId < Exception
    def initialize
      super("provider=dedibox mais server_id inconnu (ni --server-id, ni dans le merge)")
    end
  end

  def self.run(config_root : String, args : Array(String)) : Int32
    write_auto = false
    write_path : String? = nil
    disks_flag : String? = nil
    raid_flag : String? = nil
    hostname_flag : String? = nil
    zone_flag : String? = nil
    provider_override : String? = nil
    server_id_flag : String? = nil
    dns_setup = false
    dry_run = false
    account_hint : String? = nil
    domain_hint : String? = nil
    non_interactive = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl scan <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: ovh, scaleway, dedibox)") { |v| provider_override = v }
      p.on("-I ID", "--server-id=ID", "ID serveur côté hébergeur (ex: Dedibox entier, Scaleway UUID). Inutile pour OVH (le FQDN est le service_name)") { |v| server_id_flag = v }
      p.on("-n", "--dry-run", "Affiche ce qui serait fait sans écrire ni appeler d'API") { dry_run = true }
      p.on("-w", "--write", "Écrit ~/.beryl/<domaine>/<nom>.yml") { write_auto = true }
      p.on("-W PATH", "--write-to=PATH", "Écrit dans le chemin explicite") { |v| write_path = File.expand_path(v, home: true) }
      p.on("-k LIST", "--disks=LIST", "Disques à inclure (ex: sda,sdb), non-interactif") { |v| disks_flag = v }
      p.on("-r N", "--raid=N", "Niveau RAID (0|1|5|6|7|10)") { |v| raid_flag = v }
      p.on("-H NAME", "--hostname=NAME", "Nom court à poser (défaut : nom court du FQDN)") { |v| hostname_flag = v }
      p.on("-z ZONE", "--zone=ZONE", "Zone DNS pour --dns (défaut : le domaine)") { |v| zone_flag = v }
      p.on("-D", "--dns", "Pose records DNS + reverse + rename OVH") { dns_setup = true }
      p.on("-N", "--non-interactive", "Refuse toute invite") { non_interactive = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl scan <host>"
      return EXIT_USAGE
    end
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)

    # Raccourci UX : `beryl scan aloli/<ID> --provider=<name>`. Même
    # logique que `beryl rescue` — voir src/beryl/cli/provider_shortcut.cr.
    #
    # On mémorise la zone Scaleway découverte par le shortcut pour
    # l'écrire dans le YAML : sinon le fichier sortirait avec
    # `scaleway.server_id` mais sans `scaleway.zone`, et tout appel
    # ultérieur retomberait sur la zone par défaut du shard
    # (fr-par-2) → 404 si le serveur est ailleurs.
    scaleway_zone_override : String? = nil
    if (po = provider_override) && (acct = account_hint)
      root.env_file.apply_all_to_env(acct, overwrite: true)
      resolved = Beryl::CLI::ProviderShortcut.resolve(
        host_name, po,
        dedibox_factory: -> { Beryl::CLI::Credentials.dedibox_client },
        scaleway_factory: -> { Beryl::CLI::Credentials.scaleway_client },
      )
      if resolved
        log "provider=#{po} id=#{host_name} → IP #{resolved[:ip]}" \
            "#{resolved[:zone] ? " (zone #{resolved[:zone]})" : ""} (résolu via API)"
        host_name = resolved[:ip]
        server_id_flag ||= resolved[:server_id]
        scaleway_zone_override = resolved[:zone]
      end
    end

    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
    host.apply_all_credentials_to_env!

    # Provider Dedibox : on a BESOIN d'un server_id (entier) pour
    # écrire le YAML complet. S'il n'est ni en flag ni dans le merge,
    # on prompte interactivement. En --non-interactive, on refuse.
    effective_provider = provider_override || host.provider
    if effective_provider == "dedibox" && server_id_flag.nil? && host.dedibox_server_id.nil?
      if non_interactive
        STDERR.puts "beryl : provider=dedibox mais server_id inconnu (ni --server-id, ni dans le merge). " \
                    "Refus en --non-interactive."
        return EXIT_USAGE
      end
      answer = ask("ID serveur Dedibox (entier, ex: 186260) : ", default: "").strip
      if answer.empty? || answer.to_i?.nil?
        STDERR.puts "beryl : ID serveur Dedibox invalide (attendu : entier), reçu : #{answer.inspect}"
        return EXIT_USAGE
      end
      server_id_flag = answer
    end

    # --dns : faire le rename DNS + reverse AVANT le scan disques.
    # En dry-run, run_dns_setup respecte le flag et n'appelle aucune API.
    dns_plan : Beryl::CLI::DnsSetup::Plan? = nil
    if dns_setup
      case effective_provider
      when "ovh"
        dns_plan = run_dns_setup(host, hostname_flag, zone_flag, non_interactive, dry_run: dry_run)
      when "dedibox"
        sid = server_id_flag || host.dedibox_server_id || raise MissingDediboxServerId.new
        dns_plan = run_dns_setup_dedibox(host, hostname_flag, zone_flag, non_interactive, dry_run, sid)
      else
        STDERR.puts "beryl : --dns n'est pas câblé pour provider=#{effective_provider.inspect} " \
                    "(supportés : ovh, dedibox). Le scan continue sans DNS."
      end
    end

    # Scan disques : UNIQUEMENT hors dry-run. Le dry-run doit rester
    # purement informatif, aucune connexion SSH (donc pas de prompt
    # fingerprint, pas de host_key_verification qui plante si l'OS
    # n'est pas celui attendu, etc.). Philippe 22 avril 2026 terrain :
    # « Et cela plante, à quoi sert le dry-run ? »
    disks = [] of Disk
    unless dry_run
      conn = host.connection
      # On affiche la clé privée qui sera tentée : quand SSH échoue
      # en « Permission denied (publickey) », l'opérateur doit pouvoir
      # vérifier d'un coup d'œil que la clé publique correspondante
      # est bien déposée côté provider (projet Scaleway, clé SSH OVH,
      # slot IAM Dedibox…).
      key = host.identity_file || "(aucune, résolution échouera)"
      log "connexion SSH à #{Beryl.format_ssh_target(host)} (user=#{conn.user}, port=#{conn.port}, key=#{key})..."
      disks = read_disks(conn)
      if disks.empty?
        STDERR.puts "beryl : aucun disque physique détecté sur #{host.fqdn}"
        return EXIT_NO_DISKS
      end
      STDERR.puts
      STDERR.puts "Disques détectés sur #{host.fqdn} :"
      STDERR.puts disks_table(disks)
      STDERR.puts
    end

    short = if dns_plan
              dns_plan.short_name
            elsif hostname_flag
              hostname_flag.not_nil!
            else
              default_hostname(host.fqdn)
            end

    # En dry-run, on s'arrête ici : on a affiché ce qu'on ferait
    # (plan DNS si --dns), on annonce ce qui se passerait côté disques
    # + YAML, mais on ne simule aucun contenu. `--dry-run` EXPLIQUE,
    # il ne FAIT rien (pas de SSH, pas de YAML).
    if dry_run
      target = resolve_write_target(write_path, write_auto, config_root, host.account_name, host.domain_name, short)
      effective_provider = provider_override || host.provider
      STDERR.puts
      STDERR.puts "DRY-RUN : actions `beryl scan` prévues :"
      STDERR.puts "  - SSH vers #{Beryl.format_ssh_target(host)} pour `lsblk` (lecture disques)"
      STDERR.puts "  - Provider résolu : #{effective_provider || "(non résolu)"}"
      STDERR.puts "  - Hostname cible : #{short}.#{host.domain_name}"
      STDERR.puts "  - RAID : #{raid_flag || "demandé interactivement"}"
      if target
        STDERR.puts "  - Écriture YAML dans : #{target}"
      else
        STDERR.puts "  - YAML affiché à l'écran (pas de --write / --write-to)"
      end
      STDERR.puts "DRY-RUN : aucune action exécutée."
      # Afficher la commande à relancer avec --hostname=<short> pour
      # éviter le prompt interactif au 2e lancement.
      extras = [] of String
      unless args.any? { |a| a.starts_with?("--hostname") || a == "-H" }
        extras << "--hostname=#{short}"
      end
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("scan", args, extras, replace_host: {raw, "#{host.account_name}/#{host.fqdn}"})}"
      return EXIT_OK
    end

    chosen = pick_disks(disks, disks_flag, non_interactive)
    raid = pick_raid(chosen.size, raid_flag, non_interactive)

    yaml = render_yaml(host, short, chosen, raid, provider_override: provider_override, server_id_override: server_id_flag, scaleway_zone_override: scaleway_zone_override)
    target = resolve_write_target(write_path, write_auto, config_root, host.account_name, host.domain_name, short)

    if target
      if File.exists?(target)
        if non_interactive
          STDERR.puts "beryl : #{target} existe (refus en --non-interactive)"
          return EXIT_USAGE
        end
        ans = ask("#{target} existe déjà. Écraser ? [o/N] : ", default: "N")
        unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
          STDERR.puts "beryl : abandon, fichier conservé"
          return EXIT_ABORTED
        end
      end
      Dir.mkdir_p(File.dirname(target))
      File.write(target, yaml)
      log "YAML écrit dans #{target}"
      log "Prochaine étape : beryl bootstrap #{host.account_name}/#{short}.#{host.domain_name}"
    else
      STDERR.puts "--- YAML suggéré (placez dans #{config_root}/#{host.account_name}/#{host.domain_name}/#{short}.yml) ---"
      print yaml
      STDERR.puts "--- fin ---"
      STDERR.puts
      STDERR.puts "Pour écrire ce YAML automatiquement à l'emplacement indiqué :"
      STDERR.puts "  #{rerun_with_write(args, short, raw, "#{host.account_name}/#{host.fqdn}")}"
    end
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
    STDERR.puts "beryl : SSH échoué sur le rescue — #{ex.message}"
    if ex.message.try(&.includes?("Permission denied"))
      STDERR.puts
      STDERR.puts "  Diagnostic : la clé privée n'est pas autorisée par le rescue."
      STDERR.puts "  Vérifiez que la clé publique correspondante est déposée côté provider :"
      STDERR.puts "    - Scaleway : https://console.scaleway.com → IAM → SSH keys (org-wide)"
      STDERR.puts "    - OVH      : https://www.ovh.com → Serveurs → Clés SSH (puis `ovh.ssh_key_name`)"
      STDERR.puts "    - Dedibox  : injection IAM automatique en rescue — vérifier que beryl a fait le promote 4/4"
    end
    EXIT_SSH_FAILED
  rescue ex : Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  rescue ex : OvhApi::AuthenticationError
    # 403 "This call has not been granted" : la consumer key n'a pas
    # le bon access rule pour cette route. On liste les droits requis
    # par beryl pour que l'utilisateur régénère sa clé avec le bon
    # scope. Pas de workaround, pas de WARN silencieux.
    STDERR.puts "beryl : OVH refuse l'appel API — #{ex.message}"
    STDERR.puts
    STDERR.puts "Votre consumer key OVH n'a pas les droits nécessaires."
    STDERR.puts "Régénérez-la à https://eu.api.ovh.com/createToken/ en cochant :"
    Beryl::Providers::Ovh.new.required_access_rules.each do |rule|
      STDERR.printf("  %-6s %s\n", rule[:verb], rule[:path])
    end
    STDERR.puts
    STDERR.puts "Puis mettez à jour `~/.beryl/.env.yml` ou relancez `beryl init`."
    EXIT_BAD_CREDS
  rescue ex : OvhApi::Error
    STDERR.puts "beryl : erreur API OVH — #{ex.message}"
    EXIT_API_ERROR
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  def self.read_disks(conn : SSH::Connection) : Array(Disk)
    result = conn.exec("lsblk -b -d -n -o NAME,SIZE,MODEL,ROTA,TRAN,VENDOR 2>/dev/null | cat")
    parse_lsblk(result.stdout)
  end

  def self.parse_lsblk(output : String) : Array(Disk)
    disks = [] of Disk
    output.each_line do |raw|
      line = raw.strip
      next if line.empty?
      tokens = line.split(/\s+/)
      next if tokens.size < 3
      name = tokens[0]
      next if name.starts_with?("zram") || name.starts_with?("loop") || name.starts_with?("sr")
      size = tokens[1].to_i64?
      next unless size
      next if size < 1_000_000_000

      rota = nil
      rota_idx = nil
      (tokens.size - 1).downto(2) do |i|
        if tokens[i] == "0" || tokens[i] == "1"
          rota_idx = i
          break
        end
      end
      model_parts = [] of String
      tran = ""
      vendor = ""
      if rota_idx
        rota = tokens[rota_idx] == "0"
        model_parts = tokens[2...rota_idx]
        after = tokens[(rota_idx + 1)..]
        tran = after[0]? || ""
        vendor = after[1..]?.try(&.join(" ")) || ""
      else
        model_parts = tokens[2..]
      end
      model = model_parts.join(" ").strip
      model = "#{vendor} #{model}".strip unless vendor.empty?
      is_ssd = rota.nil? ? false : rota
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

  def self.disks_table(disks : Array(Disk)) : String
    disks.map_with_index do |d, i|
      "  ##{(i + 1).to_s.rjust(2)}  #{d.name.ljust(8)}  #{d.human_size.rjust(10)}  #{d.kind.ljust(9)}  #{d.transport.ljust(6)}  #{d.model}"
    end.join('\n')
  end

  private def self.pick_disks(all : Array(Disk), flag : String?, non_interactive : Bool) : Array(Disk)
    return resolve_disk_selection(all, flag) if flag
    raise "--non-interactive requiert --disks=LIST" if non_interactive
    ans = ask("Disques à utiliser ? (1,2 | sda,sdb | 'all') [all] : ", default: "all")
    resolve_disk_selection(all, ans)
  end

  def self.resolve_disk_selection(all : Array(Disk), answer : String) : Array(Disk)
    answer = answer.strip
    raise Aborted.new if answer.empty?
    return all if answer.downcase == "all"
    result = [] of Disk
    answer.split(",").map(&.strip).reject(&.empty?).each do |token|
      if token =~ /^\d+$/
        idx = token.to_i - 1
        raise "index disque invalide : #{token}" unless (0...all.size).includes?(idx)
        result << all[idx]
      else
        disk = all.find { |d| d.name == token } || raise "disque inconnu : #{token}"
        result << disk
      end
    end
    raise Aborted.new if result.empty?
    result
  end

  # Prompt du niveau RAID sous forme numérique (convention parlante
  # voulue par Philippe : 0, 1, 5, 6, 7, 10 plutôt que
  # stripe/mirror/raidz…).
  private def self.pick_raid(count : Int32, flag : String?, non_interactive : Bool) : Int32
    default = raid_default_for(count)
    if flag
      n = flag.to_i? || raise "raid invalide : #{flag} (attendu : un nombre)"
      raise "niveau RAID #{n} non supporté" unless Beryl::Config::Zpool.known?(n)
      return n
    end
    return default if non_interactive
    ans = ask("Niveau RAID [0=stripe 1=mirror 5=raidz 6=raidz2 7=raidz3] (défaut: #{default}) : ", default: default.to_s)
    n = ans.to_i? || raise "raid invalide : #{ans}"
    raise "niveau RAID #{n} non supporté (valeurs : 0, 1, 5, 6, 7, 10)" unless Beryl::Config::Zpool.known?(n)
    n
  end

  # Défaut raisonnable selon le nombre de disques :
  #   1 disque  → 0 (stripe, pas le choix)
  #   2 disques → 1 (mirror, sécurité sans perte d'espace surprise)
  #   3+ disques → 0 (stripe, convention Aloli :
  #                backups bétonnés > redondance disque)
  def self.raid_default_for(count : Int32) : Int32
    case count
    when 1 then 0
    when 2 then 1
    else        0
    end
  end

  # Rend le YAML d'un host. Le fichier ne contient QUE ce qui est
  # spécifique (provider/service_name/hostname/disques/raid). Le
  # reste vient du merge (_default.yml, <domaine>.yml).
  #
  # Niveau RAID en notation numérique (0=stripe, 1=mirror, 5=raidz,
  # 6=raidz2, 7=raidz3, 10=mirror_stripe) — traduit en mode ZFS par
  # `Beryl::Config::Zpool.zfs_mode` au moment du bootstrap.
  def self.render_yaml(
    host : Beryl::Config::ResolvedHost,
    short : String,
    disks : Array(Disk),
    raid : Int32,
    provider_override : String? = nil,
    server_id_override : String? = nil,
    scaleway_zone_override : String? = nil,
  ) : String
    String.build do |io|
      io << "# Généré par `beryl scan` le " << Beryl.format_timestamp(Time.local) << '\n'
      io << "# Mergé avec _default.yml + " << host.domain.source_path << '\n'
      io << "# Relisez avant `beryl bootstrap " << short << "." << host.domain_name << "`.\n\n"
      # Résolution du provider : --provider CLI gagne, sinon celui du merge.
      # Le provider effectif est toujours écrit dans le fichier host :
      # ça fige l'état au moment du scan (plus lisible qu'un fichier
      # host qui hérite silencieusement) et évite les surprises si le
      # défaut du domaine change plus tard.
      effective_provider = provider_override || host.provider
      if effective_provider
        io << "provider: " << effective_provider << '\n'
        case effective_provider
        when "ovh"
          if sn = host.ovh_service_name
            io << "ovh:\n  service_name: " << sn << '\n'
          end
        when "scaleway"
          sid = server_id_override || host.scaleway_server_id
          if sid
            io << "scaleway:\n  server_id: " << sid << '\n'
            # Priorité à la zone découverte par le shortcut : c'est
            # la source autoritaire (l'API a confirmé que ce server_id
            # vit dans cette zone), plus fiable que le YAML parent.
            if zone = scaleway_zone_override || host.scaleway_zone
              io << "  zone: " << zone << '\n'
            end
          end
        when "dedibox"
          sid = server_id_override || host.dedibox_server_id
          if sid
            io << "dedibox:\n  server_id: " << sid << '\n'
          end
        end
      end
      io << "\nfreebsd:\n"
      io << "  hostname: " << short << '\n'
      io << "  zfs:\n"
      io << "    zroot:              # nom du pool côté ZFS (`zpool list`)\n"
      io << "      boot: true        # c'est le pool système (exactement un)\n"
      io << "      raid: " << raid << "             # 0=stripe 1=mirror 5=raidz 6=raidz2 7=raidz3 10=mirror_stripe\n"
      io << "      disks:\n"
      disks.each { |d| io << "        - " << d.dev_path << "  # " << d.human_size << " " << d.kind << " " << d.model << '\n' }
    end
  end

  def self.default_hostname(fqdn : String) : String
    fqdn.split('.').first
  end

  def self.resolve_write_target(explicit : String?, auto : Bool, config_root : String, account_name : String, domain_name : String, short : String) : String?
    return explicit if explicit
    return nil unless auto
    File.join(config_root, account_name, domain_name, "#{short}.yml")
  end

  # Construit la commande à proposer quand beryl scan affiche un YAML
  # en mode suggestion (pas de --write) : même args, mais en ajoutant
  # `--write` et, si l'opérateur n'a pas passé `--hostname`, le short
  # résolu interactivement pour éviter le re-prompt.
  def self.rerun_with_write(
    args : Array(String),
    short : String,
    raw_host : String? = nil,
    normalized_host : String? = nil,
  ) : String
    extras = [] of String
    unless args.any? { |a| a.starts_with?("--hostname") || a == "-H" }
      extras << "--hostname=#{short}"
    end
    unless args.any? { |a|
             a == "--write" || a == "-w" ||
             a.starts_with?("--write-to") || a == "-W"
           }
      extras << "--write"
    end
    replace = if raw_host && normalized_host
                {raw_host, normalized_host}
              else
                nil
              end
    Beryl.rerun_hint("scan", args, extras, replace_host: replace)
  end

  # Flux --dns : prompt nom + zone, calcule le plan, applique.
  def self.run_dns_setup(
    host : Beryl::Config::ResolvedHost,
    hostname_flag : String?,
    zone_flag : String?,
    non_interactive : Bool,
    dry_run : Bool = false,
  ) : Beryl::CLI::DnsSetup::Plan
    service_name = host.ovh_service_name || raise "--dns nécessite un host OVH avec service_name (got provider=#{host.provider.inspect})"
    short = hostname_flag || (non_interactive ? raise("--dns + --non-interactive requiert --hostname=NAME") : ask("Nom court du serveur (ex: loulou) : ", default: ""))
    raise Aborted.new if short.empty?
    zone = zone_flag || host.domain_name
    client = Beryl::CLI::Credentials.ovh_client
    plan = Beryl::CLI::DnsSetup.build_plan(client, service_name, short, zone)
    STDERR.puts
    STDERR.puts plan.describe
    STDERR.puts
    if dry_run
      log "DRY-RUN : plan DNS affiché, aucun appel API effectué"
      return plan
    end
    unless non_interactive
      ans = ask("Exécuter ces actions ? [o/N] : ", default: "N")
      raise Aborted.new unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
    end
    logger = Proc(String, Nil).new { |m| log(m); nil }
    Beryl::CLI::DnsSetup.apply!(client, plan, logger)
    log "nommage DNS + OVH posé : #{plan.fqdn} ↔ #{service_name}"
    plan
  end

  # Variante Dedibox de `run_dns_setup`. Différences :
  #   - IPs + current_hostname viennent de l'API Dedibox
  #     (`GET /server/{id}`), pas OVH.
  #   - records A/AAAA posés via le DNS provider de la zone
  #     (typiquement OVH côté Aloli si la zone aloli.net y est
  #     hébergée). On réutilise `DnsSetup.ensure_record` /
  #     `refresh_zone`.
  #   - rename console : `DediboxApi::Client.servers.update_hostname`
  #     (API validée live 24 avril 2026).
  #   - reverse DNS : **skip**, l'API Dedibox ne l'expose pas.
  #     Warning explicite pour que l'opérateur le pose manuellement
  #     dans https://console.online.net.
  def self.run_dns_setup_dedibox(
    host : Beryl::Config::ResolvedHost,
    hostname_flag : String?,
    zone_flag : String?,
    non_interactive : Bool,
    dry_run : Bool,
    server_id_str : String,
  ) : Beryl::CLI::DnsSetup::Plan
    server_id = server_id_str.to_i? || raise "dedibox.server_id doit être un entier : #{server_id_str.inspect}"
    short = hostname_flag || (non_interactive ? raise("--dns + --non-interactive requiert --hostname=NAME") : ask("Nom court du serveur (ex: cookie) : ", default: ""))
    raise Aborted.new if short.empty?
    zone = zone_flag || host.domain_name

    dedibox = Beryl::CLI::Credentials.dedibox_client
    info = dedibox.servers.info(server_id)
    ipv4 = info.public_ip || raise "aucune IP publique sur serveur Dedibox #{server_id}"
    # Dedibox IPv6 : pas encore remonté dans le struct Server
    # (présent dans info.raw["ip"][i] si type=public et v6). À étendre
    # au besoin — pour l'instant on pose seulement v4.
    ipv6 = info.ips.find { |ip| ip.public? && ip.address.includes?(':') }.try(&.address)
    current_hostname = info.hostname
    fqdn = "#{short}.#{zone}"

    plan = Beryl::CLI::DnsSetup::Plan.new(
      service_name: server_id.to_s,
      fqdn: fqdn,
      short_name: short,
      zone: zone,
      ipv4: ipv4,
      ipv6: ipv6,
      current_display_name: current_hostname,
    )
    STDERR.puts
    STDERR.puts "Actions DNS + Dedibox prévues pour serveur #{server_id} :"
    STDERR.puts "  1. Créer (ou vérifier) A     #{short}.#{zone}  →  #{ipv4}"
    if v6 = ipv6
      STDERR.puts "  2. Créer (ou vérifier) AAAA  #{short}.#{zone}  →  #{v6}"
    else
      STDERR.puts "  2. AAAA : aucune IPv6 publique détectée côté Dedibox, ignoré"
    end
    STDERR.puts "  3. Rafraîchir la zone #{zone}"
    if current_hostname == short
      STDERR.puts "  4. hostname console Dedibox déjà à #{short}, rien à faire"
    else
      STDERR.puts "  4. Renommer console Dedibox : #{current_hostname.empty? ? "(aucun)" : current_hostname}  →  #{short}"
    end
    STDERR.puts "  5. Reverse DNS : NON câblé (l'API Dedibox ne l'expose pas)."
    STDERR.puts "     → à poser manuellement dans https://console.online.net"
    STDERR.puts "       (Serveur → IP failover / Reverse DNS) pour #{ipv4}#{ipv6 ? " et #{ipv6}" : ""}."
    STDERR.puts

    if dry_run
      log "DRY-RUN : plan DNS Dedibox affiché, aucun appel API effectué"
      return plan
    end
    unless non_interactive
      ans = ask("Exécuter ces actions ? [o/N] : ", default: "N")
      raise Aborted.new unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
    end

    # Records DNS via le DNS provider (OVH côté Aloli aujourd'hui).
    # Beryl instancie un client OVH pour poser les records A/AAAA
    # dans la zone aloli.net. Si la zone était ailleurs (Gandi…),
    # il faudrait une abstraction DnsProvider — pas encore câblée.
    ovh = Beryl::CLI::Credentials.ovh_client
    logger = Proc(String, Nil).new { |m| log(m); nil }
    Beryl::CLI::DnsSetup.ensure_record(ovh, zone, "A", short, ipv4, logger)
    if v6 = ipv6
      Beryl::CLI::DnsSetup.ensure_record(ovh, zone, "AAAA", short, v6, logger)
    end
    Beryl::CLI::DnsSetup.refresh_zone(ovh, zone, logger)

    # Rename côté console Dedibox (via PUT /server/{id}).
    if current_hostname != short
      log "renomme hostname console Dedibox : #{server_id} → #{short}"
      dedibox.servers.update_hostname(server_id, short)
    end

    log "nommage DNS + Dedibox posé : #{fqdn} ↔ serveur #{server_id} (reverse DNS à poser manuellement)"
    plan
  end

  private def self.ask(prompt : String, default : String) : String
    STDERR.print prompt
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    ans = line.chomp.strip
    ans.empty? ? default : ans
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl scan] #{message}"
  end
end
