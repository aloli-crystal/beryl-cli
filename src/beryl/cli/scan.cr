require "option_parser"
require "./option_errors"
require "./fmt"
require "socket"
require "api-ovh/ovh_api"
require "api-scaleway/scaleway_api"
require "api-dedibox/dedibox_api"
require "../config"
require "../providers"
require "ssh"
require "./credentials"
require "./dns_setup"
require "./account_utils"
require "./dns_apply"
require "./provider_shortcut"
require "./config_git"
require "./raid_controller"
require "./machine_kind"

# Sous-commande `beryl scan <host>` : se connecte au rescue Linux,
# détecte les disques, propose un YAML pour le fichier host.
#
# Forme typique :
#   beryl scan ns3156789.ip-51-83-6.eu --domain=example.net --apply
#
# Après l'écriture de la fiche, PROPOSE de poser les records DNS (forward
# via le dns_provider de la zone) + le reverse IPv4/IPv6 (question, oui par
# défaut), pour ne pas l'oublier (idempotent : un nouveau scan d'un host en
# place ne change rien).
# `--no-dns` s'en passe ; `--dns` reste accepté.
# Défaut : dry-run (affiche le YAML sans rien écrire). Avec `--apply` :
# écrit ~/.config/beryl/<domaine>/<nom>.yml (nom court
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

    # Vrai si ce « disque » est en réalité un volume logique présenté par un
    # contrôleur RAID MATÉRIEL (MegaRAID/PERC/Smart Array…), qui masque les
    # disques physiques. L'OS voit alors MOINS de disques que l'inventaire
    # provider — c'est normal (redondance gérée par la carte), pas une panne.
    def hardware_raid? : Bool
      m = @model.downcase
      return true if m =~ /\bmr\d/ # MegaRAID MR9361/MR9363…
      %w[avago lsi broadcom megaraid perc smart array smartarray
        adaptec microsemi smartraid logical volume virtual disk].any? { |s| m.includes?(s) }
    end
  end

  class Aborted < Exception
  end

  class MissingDediboxServerId < Exception
    def initialize
      super("provider=dedibox mais server_id inconnu (ni --server-id, ni dans le merge)")
    end
  end

  class MissingProviderConfig < Exception
  end

  # Un pool ZFS déclaré par l'opérateur : nom ZFS, disques alloués,
  # niveau RAID numérique (0|1|5|6|7|10), et `boot: true` pour
  # exactement UN pool (le zroot, pool système — `mountpoint` nil).
  #
  # Convention beryl pour les pools data : l'opérateur tape un nom
  # court (`data`, `cache`, `backup`…), beryl en déduit :
  # - nom ZFS : `z<court>`    (ex: zdata)
  # - mountpoint : `/<court>` (ex: /data)
  #
  # Cette convention élimine le besoin de deux prompts séparés
  # (nom pool + mountpoint) et aligne le nom ZFS sur le mountpoint
  # pour un debug plus facile (`zpool list` ↔ `df -h`).
  record PoolSpec,
    name : String,
    disks : Array(Disk),
    raid : Int32,
    boot : Bool,
    mountpoint : String? = nil do
    # Constructeur « pool data » : nom court → pool `z<court>` +
    # mountpoint `/<court>`, `boot: false`.
    def self.data(short_name : String, disks : Array(Disk), raid : Int32) : PoolSpec
      new(
        name: "z#{short_name}",
        disks: disks,
        raid: raid,
        boot: false,
        mountpoint: "/#{short_name}",
      )
    end

    # Constructeur « pool boot zroot » : nom fixe, pas de mountpoint
    # (pool système, l'installeur gère le root-fs).
    def self.zroot(disks : Array(Disk), raid : Int32) : PoolSpec
      new(name: "zroot", disks: disks, raid: raid, boot: true)
    end
  end

  def self.run(config_root : String, args : Array(String)) : Int32
    write_auto = false
    write_path : String? = nil
    disks_flag : String? = nil
    raid_flag : String? = nil
    # Pools additionnels en ligne de commande (répétable). Format :
    # `NAME:DISKS:RAID` — ex : `--pool=zdata:sda,sdb,sdc,sdd:10`.
    # Le zroot reste piloté par `--disks` + `--raid` (rétrocompat).
    pool_specs = [] of String
    hostname_flag : String? = nil
    zone_flag : String? = nil
    provider_override : String? = nil
    server_id_flag : String? = nil
    dns_setup = true
    dry_run = true
    account_hint : String? = nil
    domain_hint : String? = nil
    non_interactive = false
    no_commit = false
    discover = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl scan <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: dedibox, ovh, scaleway)") { |v| provider_override = v }
      p.on("-I ID", "--server-id=ID", "ID serveur côté hébergeur (ex: Dedibox entier, Scaleway UUID). Inutile pour OVH (le FQDN est le service_name)") { |v| server_id_flag = v }
      p.on("--apply", "Applique : écrit le host.yml (chemin auto), puis propose le DNS (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false; write_auto = true }
      p.on("-W PATH", "--write-to=PATH", "Écrit dans un chemin explicite (implique --apply)") { |v| write_path = File.expand_path(v, home: true); dry_run = false }
      p.on("-k LIST", "--disks=LIST", "Disques du pool zroot (ex: sda,sdb | 'all')") { |v| disks_flag = v }
      p.on("-r N", "--raid=N", "Niveau RAID du pool zroot (0|1|5|6|7|10)") { |v| raid_flag = v }
      p.on("--pool=SPEC", "Pool additionnel NAME:DISKS:RAID (répétable, ex: zdata:sda,sdb:10)") { |v| pool_specs << v }
      p.on("-H NAME", "--hostname=NAME", "Nom court à poser (défaut : nom court du FQDN)") { |v| hostname_flag = v }
      p.on("--host=NAME", "Alias de --hostname") { |v| hostname_flag = v }
      p.on("-z ZONE", "--zone=ZONE", "Zone DNS (défaut : le domaine)") { |v| zone_flag = v }
      p.on("-D", "--dns", "Propose, après l'écriture, records DNS + reverse + rename (défaut)") { dns_setup = true }
      p.on("--no-dns", "Ne propose pas le DNS") { dns_setup = false }
      p.on("-N", "--non-interactive", "Refuse toute invite") { non_interactive = true }
      p.on("--no-commit", "N'auto-commite pas le YAML dans le dépôt git de config") { no_commit = true }
      p.on("--discover", "Découvre les serveurs OVH du compte et écrit un host.yml minimal par NOUVEAU serveur (société : positionnel ou --account). Sans SSH ni rescue.") { discover = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)

    # `--discover <société>` : découverte de parc OVH → squelettes host.yml.
    # Court-circuite le flux normal (qui exige un <host> + rescue).
    if discover
      account = account_hint || positional.first?
      unless account
        STDERR.puts "beryl : `--discover` exige une société (positionnel « <société> » ou --account=NOM)."
        return EXIT_USAGE
      end
      return discover_servers(Beryl::Config::Root.load(config_root), config_root, account, domain_hint, non_interactive, dry_run)
    end

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

    # Raccourci UX : `beryl scan acme/<ID> --provider=<name>`. Même
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
        log "#{po} : id=#{host_name} → IP #{resolved[:ip]}" \
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

    # Scan disques : UNIQUEMENT hors dry-run. Le dry-run doit rester
    # purement informatif, aucune connexion SSH (donc pas de prompt
    # fingerprint, pas de host_key_verification qui plante si l'OS
    # n'est pas celui attendu, etc.). Philippe 22 avril 2026 terrain :
    # « Et cela plante, à quoi sert le dry-run ? »
    disks = [] of Disk
    unless dry_run
      conn = host.rescue_connection
      # On affiche la clé privée qui sera tentée : quand SSH échoue
      # en « Permission denied (publickey) », l'opérateur doit pouvoir
      # vérifier d'un coup d'œil que la clé publique correspondante
      # est bien déposée côté provider (projet Scaleway, clé SSH OVH,
      # slot IAM Dedibox…).
      key = host.identity_file || "(aucune, résolution échouera)"
      log "1 connexion SSH à #{Beryl.format_ssh_target(host)} (user=#{conn.user}, port=#{conn.port}, key=#{key})..."
      disks = read_disks(conn)
      unless disks.empty?
        STDERR.puts
        STDERR.puts "Disques détectés sur #{host.fqdn} :"
        STDERR.puts disks_table(disks)
        if (warning = disk_inventory_warning_for(host, effective_provider, disks))
          STDERR.puts
          STDERR.puts warning
        end
        STDERR.puts
      end

      # RAID matériel : proposer (option 2/3) de (re)configurer la carte —
      # MÊME quand l'OS ne présente AUCUN disque (disques en « Unconfigured
      # Good » après une reconfig interrompue → un VD ou un JBOD les
      # réexpose). Reconfig + reboot auto → re-scan → `disks` reflète le
      # nouveau layout. Refus du reboot auto → nil → arrêt (reboot manuel).
      reconfigured = maybe_reconfigure_raid(conn, host, disks, non_interactive)
      return EXIT_OK unless reconfigured
      disks = reconfigured

      if disks.empty?
        STDERR.puts "beryl : aucun disque physique détecté sur #{host.fqdn}"
        return EXIT_NO_DISKS
      end
    end

    # Nom court du host : le DNS (posé après l'écriture) reprend CE nom, la
    # fiche et les records portent donc le même. (Copie locale : `hostname_flag`,
    # capturé par le parseur, ne se restreint pas à String.)
    flag_short = hostname_flag
    short = flag_short || default_hostname(host.fqdn)

    # En dry-run, on s'arrête ici : on a affiché ce qu'on ferait
    # (plan DNS si --dns), on annonce ce qui se passerait côté disques
    # + YAML, mais on ne simule aucun contenu. `--dry-run` EXPLIQUE,
    # il ne FAIT rien (pas de SSH, pas de YAML).
    if dry_run
      target = resolve_write_target(write_path, write_auto, config_root, host.account_name, host.domain_name, short,
        existing: host.virtual ? nil : host.node.source_path)
      effective_provider = provider_override || host.provider
      # Plan DNS (aucun appel d'API en dry-run).
      run_dns(host, effective_provider, short, zone_flag, true, non_interactive, server_id_flag, scaleway_zone_override) if dns_setup
      STDERR.puts
      STDERR.puts "DRY-RUN : actions `beryl scan` prévues :"
      STDERR.puts "  - SSH vers #{Beryl.format_ssh_target(host)} pour `lsblk` (lecture disques)"
      STDERR.puts "  - Provider résolu : #{effective_provider || "(non résolu)"}"
      STDERR.puts "  - Hostname cible : #{short}.#{host.domain_name}"
      STDERR.puts "  - RAID : #{raid_flag || "demandé interactivement"}"
      if target
        STDERR.puts "  - Écriture YAML dans : #{target}"
      else
        STDERR.puts "  - YAML affiché à l'écran (dry-run — --apply ou --write-to pour écrire)"
      end
      STDERR.puts "  - DNS : proposé après l'écriture (question ; forward, reverse, rename)" if dns_setup
      STDERR.puts "DRY-RUN : aucune action exécutée."
      # Afficher la commande à relancer avec --hostname=<short> pour
      # éviter le prompt interactif au 2e lancement.
      extras = [] of String
      unless args.any? { |a| a.starts_with?("--hostname") || a == "-H" }
        extras << "--hostname=#{short}"
      end
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("scan", args, extras, replace_host: {raw, Beryl::CLI::AccountUtils.host_ref(host)})}"
      return EXIT_OK
    end

    # Construction multi-pool :
    #   1. zroot (obligatoire) : soit `--disks` + `--raid`, soit prompt.
    #   2. Pools additionnels : soit `--pool=NAME:DISKS:RAID` répétés,
    #      soit boucle interactive tant qu'il reste des disques.
    remaining = disks.dup
    zroot_disks = pick_disks_for("zroot", remaining, disks_flag, non_interactive)
    zroot_raid = pick_raid_for("zroot", zroot_disks.size, raid_flag, non_interactive)
    pools = [PoolSpec.zroot(zroot_disks, zroot_raid)]
    remaining = remaining.reject { |d| zroot_disks.includes?(d) }

    if !pool_specs.empty?
      # Mode non-interactif (ou complémentaire) : parse les --pool CLI.
      # Format : SHORTNAME:DISKS:RAID → pool z<short>, mountpoint /<short>.
      pool_specs.each do |spec|
        parsed = parse_pool_spec(spec, remaining)
        pools << parsed
        remaining = remaining.reject { |d| parsed.disks.includes?(d) }
      end
    elsif !non_interactive
      # Mode interactif : tant qu'il reste des disques, propose un pool.
      # L'opérateur tape un nom court (`data`, `cache`…) et beryl en
      # déduit le pool ZFS (`zdata`) + le mountpoint (`/data`).
      # La convention est rappelée à CHAQUE itération (pas seulement
      # la première) pour qu'elle reste sous les yeux de l'opérateur.
      while !remaining.empty?
        STDERR.puts
        STDERR.puts "Pool de données ZFS additionnel :"
        STDERR.puts "  Convention beryl : le nom que vous tapez (ex: data) sera utilisé"
        STDERR.puts "  pour créer le pool ZFS `zdata` monté sur `/data`. De même pour"
        STDERR.puts "  `cache` → `zcache` sur `/cache`, `backup` → `zbackup` sur `/backup`."
        STDERR.puts
        STDERR.puts "Disques non affectés à un pool :"
        STDERR.puts disks_table(remaining)
        STDERR.puts
        declared = pools.map(&.name)
        pool_short = ask_pool_short_name(declared)
        break unless pool_short
        chosen = pick_disks_for("z#{pool_short}", remaining, nil, false)
        raid = pick_raid_for("z#{pool_short}", chosen.size, nil, false)
        pools << PoolSpec.data(pool_short, chosen, raid)
        remaining = remaining.reject { |d| chosen.includes?(d) }
      end
    end

    # Miroirs : modèles de disques alternés (RAID 10) et miroirs d'un seul
    # modèle signalés, cf. `mix_models`.
    pools = mix_models(pools, disks)

    # OVH + service_name inconnu (host scanné par FQDN/IP) → on le résout
    # via l'API (match de l'IP). INDISPENSABLE : sans service_name, le
    # bootstrap ne peut pas faire boot_from_disk → le serveur revient en
    # rescue (cf. garde-fou bootstrap).
    ovh_sn_override = nil
    ovh_commercial_override = nil
    ovh_hardware_override = nil
    if (provider_override || host.provider) == "ovh"
      ovh_sn_override = resolve_ovh_service_name(host) if host.ovh_service_name.nil?
      if effective_sn = (ovh_sn_override || host.ovh_service_name)
        ovh_commercial_override, ovh_hardware_override = fetch_ovh_specs(host, effective_sn)
      end
    end
    yaml = render_yaml(host, short, pools,
      provider_override: provider_override, server_id_override: server_id_flag,
      scaleway_zone_override: scaleway_zone_override, ovh_service_name_override: ovh_sn_override,
      ovh_commercial_override: ovh_commercial_override, ovh_hardware_override: ovh_hardware_override)
    target = resolve_write_target(write_path, write_auto, config_root, host.account_name, host.domain_name, short,
      existing: host.virtual ? nil : host.node.source_path)

    if target
      if File.exists?(target)
        # Fusion plutôt qu'écrasement : scan ne possède QUE
        # provider/service_name/hostname/disques/raid ; on préserve le
        # reste (apply_recipes, proxy_jump, ssh_host, freebsd.users…).
        merged = begin
          merge_scan_into(File.read(target), yaml)
        rescue
          nil # YAML existant illisible → on retombe sur l'écrasement explicite
        end
        if merged.nil?
          if non_interactive
            STDERR.puts "beryl : #{target} existe et n'est pas un YAML lisible (refus en --non-interactive)"
            return EXIT_USAGE
          end
          ans = ask("#{target} existe (illisible en YAML). Écraser ENTIÈREMENT ? [o/N] : ", default: "N")
          unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
            STDERR.puts "beryl : abandon, fichier conservé"
            return EXIT_ABORTED
          end
        else
          unless non_interactive
            ans = ask("#{target} existe — mettre à jour (fusion ; vos apply_recipes/proxy_jump sont préservés) ? [O/n] : ", default: "O")
            if ans.downcase.starts_with?("n")
              STDERR.puts "beryl : abandon, fichier conservé"
              return EXIT_ABORTED
            end
          end
          yaml = merged
        end
      end
      Dir.mkdir_p(File.dirname(target))
      Beryl::CLI::Fmt.write(target, yaml)
      log "2 YAML écrit dans #{target}"
      zroot_raid = pools.find(&.boot).try(&.raid) || 0
      Beryl::CLI::ConfigGit.commit(
        [target],
        "scan : #{short}.#{host.domain_name} (#{pools.sum(&.disks.size)} disques, zroot raid#{zroot_raid})",
        no_commit,
      )
      if dns_setup && dns_wanted?("#{short}.#{host.domain_name}", non_interactive)
        run_dns(host, effective_provider, short, zone_flag, false, non_interactive, server_id_flag, scaleway_zone_override)
      end
      log "Prochaine étape : beryl bootstrap #{host.account_name}/#{short}.#{host.domain_name}"
    else
      STDERR.puts "--- YAML suggéré (placez dans #{config_root}/#{host.account_name}/#{host.domain_name}/#{short}.host.yml) ---"
      print yaml
      STDERR.puts "--- fin ---"
      STDERR.puts
      STDERR.puts "Pour écrire ce YAML automatiquement à l'emplacement indiqué :"
      STDERR.puts "  #{rerun_with_write(args, short, raw, Beryl::CLI::AccountUtils.host_ref(host))}"
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
      STDERR.puts "    - Dedibox  : injection IAM automatique en rescue — vérifier que beryl a fait le promote 4/4"
      STDERR.puts "    - OVH      : https://www.ovh.com → Serveurs → Clés SSH (puis `ovh.ssh_key_name`)"
      STDERR.puts "    - Scaleway : https://console.scaleway.com → IAM → SSH keys (org-wide)"
    end
    EXIT_SSH_FAILED
  rescue Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  rescue ex : MissingDediboxServerId
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : MissingProviderConfig
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : ScalewayApi::Error
    STDERR.puts "beryl : erreur API Scaleway — #{ex.message}"
    EXIT_API_ERROR
  rescue ex : DediboxApi::ApiError
    STDERR.puts "beryl : erreur API Dedibox — #{ex.message}"
    EXIT_API_ERROR
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
    STDERR.puts "Puis mettez à jour `~/.config/beryl/.env.yml` ou relancez `beryl init`."
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

  # Croise l'inventaire disques DÉCLARÉ par le provider (API matériel) avec
  # les disques réellement vus par l'OS. Retourne un message d'alerte si
  # l'OS en voit MOINS (cas typique : disque défaillant non énuméré, qui
  # fait stagner le firmware au boot), sinon nil. Pur → testable.
  def self.disk_inventory_warning(inv : Beryl::DiskInventory, detected : Array(Disk)) : String?
    det_total = detected.size
    return unless det_total < inv.total
    det_flash = detected.count(&.is_ssd)
    det_spin = det_total - det_flash

    # RAID MATÉRIEL : un contrôleur (MegaRAID/PERC/Smart Array…) agrège les
    # disques physiques en volumes logiques → l'OS en voit moins, c'est
    # ATTENDU. On rassure au lieu d'alarmer, et beryl utilise le(s) volume(s)
    # présenté(s) (la redondance est gérée par la carte).
    if ctrl = detected.find(&.hardware_raid?)
      return String.build do |io|
        io << "ℹ RAID matériel détecté (#{ctrl.model}) : le provider déclare "
        io << "#{inv.total} disque(s) physique(s), agrégés par le contrôleur en "
        io << "#{det_total} volume(s) logique(s).\n"
        io << "   C'est NORMAL — beryl utilisera le(s) volume(s) présenté(s) "
        io << "(redondance assurée par la carte RAID). Choisissez `#{ctrl.name}` pour zroot."
      end
    end

    String.build do |io|
      io << "⚠ ATTENTION : le provider déclare #{inv.total} disque(s)"
      io << " (#{inv.flash} SSD/NVMe + #{inv.spinning} HDD)" if inv.flash + inv.spinning == inv.total
      io << ", mais l'OS n'en voit que #{det_total}"
      io << " (#{det_flash} SSD/NVMe + #{det_spin} HDD).\n"
      io << "   Un disque est peut-être DÉFAILLANT et non énuméré par l'OS — le firmware\n"
      io << "   peut alors bloquer ~60 s par tentative au boot (serveur instable / retombe\n"
      io << "   en rescue). Vérifiez `dmesg | grep -iE 'nvme|ata|pcie'` AVANT de bootstrapper."
    end
  end

  # Variante « branchée » : récupère l'inventaire OVH pour ce host et
  # délègue à `disk_inventory_warning`. nil si non-OVH, pas de service_name,
  # credentials absents, ou API indisponible — JAMAIS bloquant (un souci
  # d'API ou de droits ne doit pas casser le scan).
  private def self.disk_inventory_warning_for(host : Beryl::Config::ResolvedHost, provider_name : String?, detected : Array(Disk)) : String?
    return unless provider_name == "ovh"
    service = host.ovh_service_name
    return unless service
    host.apply_all_credentials_to_env!
    ovh = Beryl::Providers::Ovh.new
    return unless ovh.available?
    inv = ovh.hardware_disk_inventory(service)
    return unless inv
    disk_inventory_warning(inv, detected)
  rescue
    nil
  end

  # Propose la reconstruction RAID quand un contrôleur matériel est détecté.
  # Retourne `true` si une reconfiguration a EU LIEU (→ le caller s'arrête :
  # disques modifiés, reboot rescue + re-scan requis), `false` si on continue
  # le scan normalement (option « volume tel quel », non-interactif, ou pas de
  # `storcli_url`).
  # Retourne les disques À UTILISER pour la suite du scan :
  #   - les disques d'origine si pas de RAID matériel, non-interactif, pas de
  #     `storcli_url`, ou option 1 (volume tel quel) ;
  #   - les disques RE-SCANNÉS après reconfig + reboot auto (option 2/3) ;
  #   - nil si l'opérateur reconstruit mais refuse le reboot auto → le caller
  #     s'arrête (reboot manuel + relance requis).
  private def self.maybe_reconfigure_raid(conn : SSH::Connection, host : Beryl::Config::ResolvedHost, disks : Array(Disk), non_interactive : Bool) : Array(Disk)?
    return disks if non_interactive
    # Proposer la (re)config dès qu'un contrôleur RAID est PRÉSENT — même si
    # l'OS voit déjà des disques bruts (carte en JBOD) : on peut vouloir
    # RECRÉER un volume matériel. Détection : volume HW visible (rapide) OU
    # contrôleur sur le bus PCI (`lspci`, couvre le cas JBOD).
    return disks unless disks.any?(&.hardware_raid?) || Beryl::CLI::RaidController.present?(conn)

    url = host.storcli_url
    unless url
      STDERR.puts "  (reconfiguration RAID indisponible : `storcli_url` non configuré — voir _default.yml)"
      return disks
    end

    STDERR.puts
    if disks.empty?
      STDERR.puts "Contrôleur RAID présent, mais l'OS ne voit AUCUN disque"
      STDERR.puts "(disques probablement en « Unconfigured Good » après une reconfig interrompue —"
      STDERR.puts " un JBOD ou un nouveau volume va les réexposer)."
    end
    STDERR.puts "Contrôleur RAID matériel présent. Que faire des disques ?"
    STDERR.puts "  1) Utiliser tels quels (ce que l'OS voit ci-dessus)" unless disks.empty?
    STDERR.puts "  2) (Re)configurer en JBOD → ZFS gère le RAID"
    STDERR.puts "  3) (Re)créer un volume RAID matériel à un niveau choisi"
    default = disks.empty? ? "2" : "1"
    case ask("Choix [1/2/3] (défaut #{default}) : ", default: default).strip
    when "2"
      cid = prepare_storcli(conn, url)
      Beryl::CLI::RaidController.to_jbod!(conn, cid)
      after_raid_reconfig(conn, host, "JBOD (disques bruts pour ZFS)")
    when "3"
      cid = prepare_storcli(conn, url)
      # Nombre de disques = ce que voit le CONTRÔLEUR (storcli), pas l'OS :
      # robuste qu'on parte d'un volume (1 disque OS), du JBOD (N) ou de rien.
      slots = Beryl::CLI::RaidController.drive_slots(conn, cid)
      raise "aucun disque physique listé par storcli (/c#{cid}/eall/sall show)" if slots.empty?
      level = ask_until_valid("Niveau RAID matériel (0|1|5|6|10) pour #{slots.size} disque(s) : ", default: "10") do |a|
        n = validate_raid!(a)
        raise ArgumentError.new("le contrôleur ne gère pas RAID #{n} (matériel : 0, 1, 5, 6, 10)") unless [0, 1, 5, 6, 10].includes?(n)
        Beryl::CLI::RaidController.validate_drive_count!(n, slots.size)
        n
      end
      Beryl::CLI::RaidController.recreate_on!(conn, cid, slots, level)
      after_raid_reconfig(conn, host, "nouveau volume RAID#{level}")
    else
      disks # option 1 : tels quels, le scan continue avec ces disques
    end
  end

  # Récupère storcli dans le rescue + résout le contrôleur. Lève si KO.
  private def self.prepare_storcli(conn : SSH::Connection, url : String) : Int32
    STDERR.puts "  → récupération de storcli dans le rescue…"
    raise "téléchargement/exécution de storcli a échoué (storcli_url correct ? rescue avec curl ?)" unless Beryl::CLI::RaidController.fetch(conn, url)
    cid = Beryl::CLI::RaidController.controller_id(conn)
    raise "aucun contrôleur RAID vu par storcli" unless cid
    STDERR.puts "  → contrôleur /c#{cid} (opération destructive)…"
    cid
  end

  # Après reconfig : propose le reboot AUTO du rescue (le netboot OVH reste
  # en rescue). Si accepté → reboot + attente + re-scan, retourne les
  # nouveaux disques. Si refusé → instructions manuelles + nil (stop).
  private def self.after_raid_reconfig(conn : SSH::Connection, host : Beryl::Config::ResolvedHost, what : String) : Array(Disk)?
    STDERR.puts
    STDERR.puts "✅ Contrôleur reconfiguré : #{what}."
    if ask("Rebooter le rescue et reprendre le scan automatiquement ? [O/n] : ", default: "O").downcase.starts_with?("n")
      STDERR.puts "   → rebootez le rescue (manager OVH → rescue → redémarrer), puis relancez `beryl scan #{host.fqdn} --apply`."
      return
    end
    reboot_rescue_and_rescan(conn)
  end

  # Reboote le rescue et attend son retour (le netboot OVH reste en rescue),
  # puis re-lit les disques (ré-énumérés). Lève si le rescue ne revient pas.
  private def self.reboot_rescue_and_rescan(conn : SSH::Connection) : Array(Disk)
    log "reboot du rescue (le netboot OVH reste en rescue)…"
    conn.exec("( sleep 2 ; reboot ) >/dev/null 2>&1 &", raise_on_error: false)
    # Laisser l'ancien rescue tomber avant de poller, sinon le 1er lsblk
    # réussit sur la session encore vivante → fausse détection.
    sleep 30.seconds
    log "attente du retour du rescue + ré-énumération des disques (~2-6 min)…"
    start = Time.instant
    last_log = start
    loop do
      elapsed = (Time.instant - start).total_seconds.to_i
      raise "le rescue n'est pas revenu en SSH après #{elapsed}s — rebootez-le et relancez `beryl scan`." if elapsed > 600

      if conn.exec("lsblk -dn 2>/dev/null", raise_on_error: false).success?
        disks = read_disks(conn)
        log "rescue revenu après #{elapsed}s — #{disks.size} disque(s) ré-énumérés :"
        STDERR.puts disks_table(disks)
        return disks
      end

      if (Time.instant - last_log).total_seconds >= 35
        log "toujours en attente du rescue… (#{elapsed}s écoulées)"
        last_log = Time.instant
      end
      sleep 10.seconds
    end
  end

  def self.disks_table(disks : Array(Disk)) : String
    disks.map_with_index do |d, i|
      "  ##{(i + 1).to_s.rjust(2)}  #{d.name.ljust(8)}  #{d.human_size.rjust(10)}  #{d.kind.ljust(9)}  #{d.transport.ljust(6)}  #{d.model}"
    end.join('\n')
  end

  # Regex des noms de pool ZFS autorisés : commence par une lettre
  # minuscule, suivie de lettres/chiffres/underscore. Convention
  # standard ZFS — évite les caractères qui poseraient problème
  # en shell ou dans un YAML (espaces, tirets, majuscules…).
  POOL_NAME_RX = /\A[a-z][a-z0-9_]*\z/

  # Noms courts qui, s'ils étaient acceptés, produiraient un pool
  # `z<nom>` monté sur `/<nom>` — lequel écraserait un dossier
  # système FreeBSD de premier niveau et casserait l'OS
  # (bootloader, configuration, binaires, runtime).
  #
  # Liste dérivée d'un `ls -l /` sur FreeBSD 15 après install
  # fraîche. Ajouter ici tout nouveau top-level qui apparaîtrait
  # dans une version future.
  #
  # `root` figure à part (refusé avec un message dédié « réservé
  # au pool boot `zroot` ») par `ask_pool_short_name` et
  # `parse_pool_spec`.
  FREEBSD_RESERVED_MOUNTPOINTS = %w[
    bin boot dev etc home lib libexec media mnt net
    proc rescue sbin sys tmp usr var zroot
  ]

  # Boucle interactive « demande / valide » : appelle `ask`, exécute
  # le bloc sur la réponse, re-prompte sur `ArgumentError` avec le
  # message de l'erreur. Permet de garder l'opérateur dans le flow
  # sur une typo plutôt que de faire sortir `beryl scan` en
  # EXIT_UNEXPECTED. `Aborted` (réponse vide délibérée) remonte.
  private def self.ask_until_valid(prompt : String, default : String, & : String -> T) : T forall T
    loop do
      ans = ask(prompt, default: default)
      begin
        return yield(ans)
      rescue ex : ArgumentError
        STDERR.puts "  beryl : #{ex.message}"
        STDERR.puts
      end
    end
  end

  # Demande un nom court de pool data à l'opérateur (`data`, `cache`,
  # `backup`…) — beryl préfixe ensuite automatiquement en `z<court>`
  # et pose le mountpoint `/<court>`. Refuse :
  #
  #   - un format invalide (regex `POOL_NAME_RX`)
  #   - le nom `root` (réservé au pool boot `zroot`)
  #   - un nom déjà déclaré (comparaison sur le nom ZFS complet `z<court>`)
  #
  # Retourne `nil` si l'opérateur tape [Entrée] (signal « stop la
  # boucle multi-pool »).
  private def self.ask_pool_short_name(already_declared : Array(String)) : String?
    ask_until_valid(
      "Nom du point de montage (ex: data → pool zdata + mountpoint /data) ou [Entrée] pour terminer : ",
      default: "",
    ) do |ans|
      stripped = ans.strip
      # Chaîne vide = signal d'arrêt, pas une erreur.
      next if stripped.empty?
      validate_pool_name!(stripped)
      if stripped == "root"
        raise ArgumentError.new(
          "le nom `root` est réservé au pool boot `zroot` — choisissez autre chose " \
          "(ex: data, cache, backup)"
        )
      end
      full_name = "z#{stripped}"
      if already_declared.includes?(full_name)
        raise ArgumentError.new(
          "pool #{full_name.inspect} déjà déclaré (déjà posés : #{already_declared.join(", ")})"
        )
      end
      stripped
    end
  end

  # Valide le nom court d'un pool ZFS (sans préfixe `z`). Lève
  # `ArgumentError` avec un message explicite sur quoi l'opérateur
  # aurait dû taper. Utilisé à la fois côté interactif
  # (`ask_pool_short_name`) et côté CLI (`parse_pool_spec`).
  #
  # Deux checks :
  #   1. Format regex (lettre minuscule + [a-z0-9_]*).
  #   2. Noms réservés qui écraseraient un dossier système FreeBSD
  #      de premier niveau (/bin, /etc, /usr, /var, /tmp, /boot…)
  #      et casseraient l'OS. Sécurité : mieux vaut refuser que
  #      laisser l'opérateur saboter son FreeBSD au prochain boot.
  def self.validate_pool_name!(name : String) : Nil
    unless name.matches?(POOL_NAME_RX)
      raise ArgumentError.new(
        "nom invalide : #{name.inspect} (attendu : commence par une lettre, " \
        "uniquement minuscules/chiffres/underscore, ex: data, cache, backup01)"
      )
    end
    if FREEBSD_RESERVED_MOUNTPOINTS.includes?(name)
      raise ArgumentError.new(
        "nom réservé : #{name.inspect} — écraserait le dossier système FreeBSD `/#{name}` " \
        "et casserait l'OS. Choisissez un nom libre (ex: data, save, cache, backup). " \
        "Dossiers réservés : /#{FREEBSD_RESERVED_MOUNTPOINTS.join(", /")}."
      )
    end
  end

  # Sélection des disques pour un pool donné (`zroot`, `zdata`, …).
  # Le nom du pool apparaît dans le prompt pour que l'opérateur sache
  # toujours dans quelle « case » il travaille.
  #
  # Format des messages (norme beryl) :
  #   - options entre parenthèses `(…)`
  #   - défaut entre crochets `[défaut : X]` avec espaces français
  #     autour des `:`
  #
  # En mode flag (`--disks=…` ou `--pool=…`) : `resolve_disk_selection`
  # lève `ArgumentError` sur saisie invalide, qui remonte jusqu'à
  # `run()` (pas de re-prompt possible pour un flag).
  # En mode interactif : `ask_until_valid` re-prompte sur
  # `ArgumentError` avec message, seul `Aborted` (réponse vide)
  # termine.
  private def self.pick_disks_for(pool_name : String, candidates : Array(Disk), flag : String?, non_interactive : Bool) : Array(Disk)
    return resolve_disk_selection(candidates, flag) if flag
    # Un seul disque : rien à choisir, on ne pose pas la question.
    if candidates.size == 1
      STDERR.puts "  → #{pool_name} : un seul disque disponible, #{candidates.first.name} retenu."
      return candidates.dup
    end
    raise "--non-interactive requiert --disks=LIST (ou --pool=NAME:DISKS:RAID)" if non_interactive
    ask_until_valid(
      "Disques à utiliser pour #{pool_name} ? (#{disk_choice_hint(candidates)}) [défaut : all] : ",
      default: "all",
    ) { |ans| resolve_disk_selection(candidates, ans) }
  end

  # Exemples de réponse construits sur les VRAIS disques (pas `sda,sdb` en
  # dur) : `1,2 | nvme0n1,nvme1n1 | all`. Appelé avec au moins 2 disques.
  def self.disk_choice_hint(candidates : Array(Disk)) : String
    # Exemple de miroir : de préférence deux modèles différents (cf. `mix_models`).
    first = candidates.first
    second = candidates.find { |d| d.model != first.model && Scan.mirror_partner?(first, d) } || candidates[1]
    idx = [candidates.index!(first), candidates.index!(second)].map(&.+(1))
    "#{idx.join(",")} | #{first.name},#{second.name} | all"
  end

  # Deux disques du même modèle viennent souvent du même lot, avec le même
  # firmware : ils tendent à tomber en panne ensemble. Un miroir ZFS doit
  # donc réunir deux modèles différents quand le serveur en a (ADV-3 : 2 ×
  # Micron + 2 × Samsung). Pour un RAID 10, beryl forme les miroirs avec des
  # paires CONSÉCUTIVES : l'ordre de `lsblk` (nvme0n1, nvme1n1…) donnerait
  # Micron + Micron et Samsung + Samsung. La fiche est triée (`beryl fmt`) et
  # ne garde pas d'ordre : c'est `beryl bootstrap` qui forme les paires
  # (`raid10_order` sur les disques du rescue). `mix_models` annonce ces
  # paires pour chaque pool RAID 10 et avertit de tout miroir resté d'un seul modèle
  # alors qu'un disque d'un autre modèle, de même taille et même type, aurait
  # pu l'accompagner (`all` : tous les disques détectés).
  def self.mix_models(pools : Array(PoolSpec), all : Array(Disk)) : Array(PoolSpec)
    pools.map do |pool|
      ordered = pool.raid == 10 ? raid10_order(pool.disks) : pool.disks
      if ordered != pool.disks
        STDERR.puts "  → #{pool.name} : miroirs formés au bootstrap, deux modèles chacun : #{ordered.each_slice(2).map(&.map(&.name).join(" + ")).join(" ; ")}"
      end
      mirror_warnings(pool.name, ordered, pool.raid, all).each { |w| STDERR.puts w }
      pool.copy_with(disks: ordered)
    end
  end

  # Partenaire de miroir possible : même taille et même type (SSD ou disque
  # dur) — un NVMe n'est pas une alternative pour un miroir de disques durs. Pur.
  def self.mirror_partner?(a : Disk, b : Disk) : Bool
    a.size_bytes == b.size_bytes && a.is_ssd == b.is_ssd
  end

  # Le serveur a-t-il un disque d'un AUTRE modèle qui pourrait être le
  # partenaire de `disk` ? Pur.
  def self.other_model?(disk : Disk, all : Array(Disk)) : Bool
    all.any? { |d| d.model != disk.model && mirror_partner?(disk, d) }
  end

  # Ordre RAID 10 : paires consécutives de deux modèles différents tant que
  # possible (on puise d'abord dans le modèle le plus nombreux) ; à égalité,
  # l'ordre de détection est gardé. Pur.
  def self.raid10_order(disks : Array(Disk)) : Array(Disk)
    groups = disks.group_by(&.model).values.map(&.dup)
    result = [] of Disk
    until groups.empty?
      groups = groups.each_with_index.to_a.sort_by! { |(g, i)| {-g.size, i} }.map(&.[0])
      result << groups[0].shift
      partner = groups[1..].find(&.present?) || groups[0]
      if second = partner.shift?
        result << second
      end
      groups.reject!(&.empty?)
    end
    result
  end

  # Avertissements des miroirs d'un seul modèle (RAID 1 : le pool entier ;
  # RAID 10 : chaque paire), seulement si un autre modèle compatible existe. Pur.
  def self.mirror_warnings(pool_name : String, disks : Array(Disk), raid : Int32, all : Array(Disk)) : Array(String)
    return [] of String unless raid == 1 || raid == 10
    mirrors = raid == 1 ? [disks] : disks.each_slice(2).to_a
    mirrors.select { |m| m.size > 1 && m.map(&.model).uniq.size == 1 && other_model?(m.first, all) }.map do |m|
      "  ⚠ #{pool_name} : miroir #{m.map(&.name).join(" + ")} de deux disques du même modèle (#{m.first.model}) " \
      "alors que le serveur en a d'autres — même lot, même firmware : risque de panne simultanée."
    end
  end

  def self.resolve_disk_selection(all : Array(Disk), answer : String) : Array(Disk)
    answer = answer.strip
    raise Aborted.new if answer.empty?
    return all if answer.downcase == "all"
    result = [] of Disk
    available_names = all.map(&.name).join(", ")
    answer.split(",").map(&.strip).reject(&.empty?).each do |token|
      if token =~ /^\d+$/
        idx = token.to_i - 1
        unless (0...all.size).includes?(idx)
          raise ArgumentError.new(
            "index disque invalide : #{token} (attendu : 1 à #{all.size})"
          )
        end
        disk = all[idx]
        if result.includes?(disk)
          raise ArgumentError.new("disque en doublon dans la sélection : #{disk.name}")
        end
        result << disk
      else
        disk = all.find { |d| d.name == token }
        unless disk
          raise ArgumentError.new(
            "disque inconnu : #{token} (disques disponibles : #{available_names})"
          )
        end
        if result.includes?(disk)
          raise ArgumentError.new("disque en doublon dans la sélection : #{disk.name}")
        end
        result << disk
      end
    end
    raise Aborted.new if result.empty?
    result
  end

  # Prompt du niveau RAID sous forme numérique pour un pool donné.
  # Convention parlante beryl : 0, 1, 5, 6, 7, 10 plutôt que
  # stripe/mirror/raidz…
  #
  # Format cohérent avec `pick_disks_for` : options entre `(…)`,
  # défaut entre `[…]` avec espaces français autour des `:`.
  # Niveau RAID par défaut : toujours 0 (stripe), convention beryl —
  # backups bétonnés > redondance disque. L'opérateur qui veut
  # autre chose doit le dire explicitement, pas de magie sur le
  # nombre de disques (un défaut qui change selon le contexte = UX
  # imprévisible).
  DEFAULT_RAID = 0

  private def self.pick_raid_for(pool_name : String, count : Int32, flag : String?, non_interactive : Bool) : Int32
    # Un seul disque → aucune redondance possible : le vdev est
    # forcément simple (stripe = 0). On force 0 sans poser la question
    # (la choisir n'aurait aucun sens). Un --raid explicite non-stripe
    # devient alors une erreur claire plutôt qu'un échec tardif au
    # `zpool create`.
    if count <= 1
      if flag && validate_raid!(flag) != DEFAULT_RAID
        raise ArgumentError.new(
          "#{pool_name} : un seul disque sélectionné → RAID 0 (stripe) obligatoire, " \
          "--raid=#{flag} impossible (mirror/raidz exigent au moins 2 disques)"
        )
      end
      return DEFAULT_RAID
    end
    if flag
      level = validate_raid_for!(flag, count)
      stripe_warning(pool_name, count, level).try { |w| STDERR.puts w }
      return level
    end
    if non_interactive
      stripe_warning(pool_name, count, DEFAULT_RAID).try { |w| STDERR.puts w }
      return DEFAULT_RAID
    end
    legend = Beryl::Config::Zpool.legend(Beryl::Config::Zpool.possible_levels(count))
    loop do
      level = ask_until_valid(
        "Niveau RAID de #{pool_name} sur #{count} disques (#{legend}) [défaut : #{DEFAULT_RAID}] : ",
        default: DEFAULT_RAID.to_s,
      ) { |ans| validate_raid_for!(ans, count) }
      warning = stripe_warning(pool_name, count, level)
      return level unless warning
      STDERR.puts warning
      ans = ask("Confirmer le stripe SANS redondance sur #{count} disques ? [o/N] : ", default: "N")
      return level if ans.downcase.starts_with?("o")
      STDERR.puts
    end
  end

  # Garde-fou : un zroot en stripe (RAID 0) sur plusieurs disques n'a
  # AUCUNE redondance — un seul disque perdu = système perdu. Piège vu
  # in vivo après un passage JBOD → ZFS : le défaut 0 accepté d'un
  # [Entrée] a donné un zroot de 4 disques sans redondance, annulant
  # l'intérêt du JBOD. Le défaut reste 0 (convention beryl) ; on exige
  # seulement une confirmation explicite en interactif. Limité au
  # zroot : un pool de données en stripe (cache…) peut être voulu.
  # Renvoie le message d'avertissement, ou nil si rien à signaler.
  def self.stripe_warning(pool_name : String, count : Int32, level : Int32) : String?
    return unless pool_name == "zroot" && count > 1 && level == 0
    redundant = Beryl::Config::Zpool.possible_levels(count) - [0]
    "  ⚠ zroot en RAID 0 (stripe) sur #{count} disques : AUCUNE redondance, " \
    "un seul disque perdu = système perdu.\n" \
    "    Niveaux redondants possibles ici : #{Beryl::Config::Zpool.legend(redundant, ", ")}."
  end

  # `validate_raid!` + compatibilité avec le nombre de disques (règles de
  # `Zpool.validate!`, appliquées dès le scan au lieu du bootstrap). Lève
  # `ArgumentError` (re-prompt en interactif) en citant les niveaux possibles.
  def self.validate_raid_for!(answer : String, count : Int32) : Int32
    possible = Beryl::Config::Zpool.possible_levels(count)
    choices = Beryl::Config::Zpool.legend(possible, ", ")
    level = answer.strip.to_i?
    unless level && Beryl::Config::Zpool.known?(level)
      # Lettre, valeur vide ou niveau inconnu : on ne cite QUE les niveaux
      # possibles avec ces disques, pas les six.
      raise ArgumentError.new(
        "RAID invalide : #{answer.strip.inspect} — possibles avec #{count} disque(s) : #{choices}"
      )
    end
    return level if possible.includes?(level)
    raise ArgumentError.new("RAID #{level} impossible avec #{count} disque(s) — possibles : #{choices}")
  end

  # Valide une chaîne RAID. Lève `ArgumentError` sur entrée non-numérique
  # ou niveau inconnu.
  def self.validate_raid!(answer : String) : Int32
    n = answer.strip.to_i? || raise ArgumentError.new(
      "RAID invalide : #{answer.inspect} (attendu : un entier parmi 0, 1, 5, 6, 7, 10)"
    )
    unless Beryl::Config::Zpool.known?(n)
      raise ArgumentError.new(
        "niveau RAID #{n} non supporté (valeurs : 0, 1, 5, 6, 7, 10)"
      )
    end
    n
  end

  # Parse une spec `--pool=SHORTNAME:DISKS:RAID` et retourne un
  # `PoolSpec` data (pool `z<SHORTNAME>` + mountpoint `/<SHORTNAME>`,
  # `boot: false`).
  #
  # - SHORTNAME : nom court sans préfixe `z` (ex: `data`, `cache`).
  #   Refuse `root` (réservé au pool boot `zroot`).
  # - DISKS     : `sda,sdb` ou `all` (tous les disques restants).
  # - RAID      : 0|1|5|6|7|10.
  #
  # Toutes les validations lèvent `ArgumentError` pour remonter un
  # message clair à l'opérateur.
  def self.parse_pool_spec(spec : String, remaining : Array(Disk)) : PoolSpec
    parts = spec.split(':', 3)
    unless parts.size == 3
      raise ArgumentError.new(
        "--pool=#{spec.inspect} : format attendu SHORTNAME:DISKS:RAID " \
        "(ex : data:sda,sdb,sdc,sdd:10 → pool zdata, mountpoint /data)"
      )
    end
    short, disks_str, raid_str = parts
    short = short.strip
    raise ArgumentError.new("--pool=#{spec.inspect} : nom de pool vide") if short.empty?
    validate_pool_name!(short)
    if short == "root"
      raise ArgumentError.new(
        "--pool=#{spec.inspect} : `root` est réservé au pool boot `zroot` " \
        "(utilisez --disks et --raid pour le zroot)"
      )
    end
    disks = resolve_disk_selection(remaining, disks_str)
    raid = validate_raid_for!(raid_str, disks.size)
    PoolSpec.data(short, disks, raid)
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
    pools : Array(PoolSpec),
    provider_override : String? = nil,
    server_id_override : String? = nil,
    scaleway_zone_override : String? = nil,
    ovh_service_name_override : String? = nil,
    ovh_commercial_override : String? = nil,
    ovh_hardware_override : Beryl::HardwareSpec? = nil,
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
          if sn = (ovh_service_name_override || host.ovh_service_name)
            io << "ovh:\n  service_name: " << sn << '\n'
            # Nom commercial (gamme OVH) à CÔTÉ de service_name. Fallback sur la
            # valeur existante si l'API n'a rien renvoyé (pas d'écrasement).
            if cn = (ovh_commercial_override || host.ovh_commercial_name)
              io << "  commercial_name: " << cn << '\n'
            end
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
      pools.each do |pool|
        io << "    " << pool.name << ":              # nom du pool côté ZFS (`zpool list`)\n"
        io << "      boot: true        # c'est le pool système (exactement un)\n" if pool.boot
        if mp = pool.mountpoint
          io << "      mountpoint: " << mp << "   # point de montage FreeBSD\n"
        end
        io << "      raid: " << pool.raid << "             # " << Beryl::Config::Zpool.legend(Beryl::Config::Zpool.possible_levels(pool.disks.size)) << "\n"
        io << "      disks:\n"
        pool.disks.each { |d| io << "        - " << d.dev_path << "  # " << d.human_size << " " << d.kind << " " << d.model << '\n' }
      end
      # Bloc `hardware:` (specs déclarées par le provider) — alimente `beryl
      # info` hors-ligne. Fallback sur l'existant si l'API n'a rien renvoyé.
      if hw = (ovh_hardware_override || host.hardware)
        io << "\nhardware:             # specs provider (beryl info) — ne pas éditer à la main\n"
        # Clés par ordre alphabétique, comme `beryl fmt` et `info --refresh`.
        io << "  cores: " << hw.cores << '\n'
        io << "  cpu: " << hw.cpu << '\n'
        unless hw.disks.empty?
          io << "  disks:\n"
          hw.disks.each { |d| io << "    - " << d << '\n' }
        end
        if r = hw.raid
          io << "  raid: " << r << '\n'
        end
        io << "  ram_gb: " << hw.ram_gb << '\n'
        io << "  threads: " << hw.threads << '\n'
      end
    end
  end

  # Blocs provider connus : retirés de l'existant si le provider a changé
  # (sinon un ancien bloc `scaleway:` resterait après bascule vers ovh).
  KNOWN_PROVIDER_BLOCKS = %w[ovh scaleway dedibox hetzner latitude cherry phoenixnap vultr leaseweb]

  # Fusionne le YAML généré par scan dans un host.yml EXISTANT, en
  # PRÉSERVANT toutes les clés que scan ne gère pas (apply_recipes,
  # proxy_jump, ssh_host, user, port, freebsd.users…). scan possède :
  # `provider`, le bloc du provider, et `freebsd.{hostname,zfs}`.
  #
  # Les COMMENTAIRES de l'ancien fichier sont perdus (round-trip YAML) —
  # seules les DONNÉES sont préservées. Lève si l'existant n'est pas un
  # mapping YAML (le caller retombe alors sur l'écrasement explicite).
  def self.merge_scan_into(existing : String, scan_yaml : String) : String
    old = YAML.parse(existing).as_h
    scan = YAML.parse(scan_yaml).as_h
    fb_key = YAML::Any.new("freebsd")
    effective = scan[YAML::Any.new("provider")]?.try(&.as_s?)

    result = {} of YAML::Any => YAML::Any
    old.each do |k, v|
      ks = k.as_s?
      if ks == "freebsd"
        result[k] = merge_freebsd(v, scan[fb_key]?)
      elsif ks && scan.has_key?(k)
        # provider, bloc provider, hardware → rafraîchis par scan. Un BLOC
        # (mapping des deux côtés) est FUSIONNÉ, pas remplacé : les sous-clés
        # que ce scan n'apporte pas restent (ex. `ovh.price_eur`, `rack`,
        # `ipv4`, `ipv6` posés par `--discover` ou `info --refresh`).
        result[k] = merge_block(v, scan[k])
      elsif ks && KNOWN_PROVIDER_BLOCKS.includes?(ks) && ks != effective
        next # bloc d'un ancien provider → retiré (provider changé)
      else
        result[k] = v # apply_recipes, proxy_jump, ssh_host, user… → préservés
      end
    end
    # Clés que scan apporte et qui manquaient (provider/bloc/freebsd neufs).
    scan.each { |k, v| result[k] = v unless result.has_key?(k) }

    String.build do |io|
      io << "# Mis à jour par `beryl scan` le " << Beryl.format_timestamp(Time.local) << '\n'
      io << "# Champs scan (provider/service_name/hostname/disques/raid) rafraîchis ;\n"
      io << "# vos autres clés (apply_recipes, proxy_jump…) sont préservées.\n"
      io << result.to_yaml.sub(/\A---\n/, "")
    end
  end

  # Fusion superficielle de deux blocs : sous-clés de l'ancien gardées,
  # celles du scan prioritaires. Si l'un des deux n'est pas un mapping, la
  # valeur du scan l'emporte.
  private def self.merge_block(old_v : YAML::Any, scan_v : YAML::Any) : YAML::Any
    old_h = old_v.as_h?
    scan_h = scan_v.as_h?
    return scan_v unless old_h && scan_h
    merged = {} of YAML::Any => YAML::Any
    old_h.each { |k, v| merged[k] = v }
    scan_h.each { |k, v| merged[k] = v }
    YAML::Any.new(merged)
  end

  # Fusionne le bloc `freebsd:` : garde les sous-clés de l'opérateur
  # (users, packages…) et remplace celles que scan gère (hostname, zfs).
  private def self.merge_freebsd(old_fb : YAML::Any, scan_fb : YAML::Any?) : YAML::Any
    return old_fb unless scan_fb
    merged = {} of YAML::Any => YAML::Any
    (old_fb.as_h? || {} of YAML::Any => YAML::Any).each { |k, v| merged[k] = v }
    (scan_fb.as_h? || {} of YAML::Any => YAML::Any).each { |k, v| merged[k] = v }
    YAML::Any.new(merged)
  end

  # Récupère (nom commercial, specs matériel) OVH pour un service_name connu.
  # Best-effort : {nil, nil} si credentials absents / API muette → render_yaml
  # retombe alors sur les valeurs déjà présentes dans le host.yml (pas d'écrasement
  # destructif). JAMAIS bloquant.
  private def self.fetch_ovh_specs(
    host : Beryl::Config::ResolvedHost, service_name : String,
  ) : Tuple(String?, Beryl::HardwareSpec?)
    return {nil, nil} if host.vps?
    host.apply_all_credentials_to_env!
    ovh = Beryl::Providers::Ovh.new
    return {nil, nil} unless ovh.available?
    STDERR.puts "  → specs OVH (gamme commerciale + matériel) via l'API…"
    {ovh.commercial_range(service_name), ovh.server_hardware(service_name)}
  rescue ex
    STDERR.puts "  ⚠ specs OVH indisponibles (#{ex.message}) — valeurs existantes conservées."
    {nil, nil}
  end

  # Résout le service_name OVH d'un host scanné par FQDN/IP, via l'API
  # (match de l'IP principale). nil si non joignable, credentials absents,
  # IP non résolue, ou aucun match. JAMAIS bloquant.
  private def self.resolve_ovh_service_name(host : Beryl::Config::ResolvedHost) : String?
    return if host.vps?
    # IP PUBLIQUE (rescue_ssh_host), jamais le vRack : l'API OVH matche un
    # serveur sur son IP publique, pas sur une IP vRack privée.
    ip = resolve_host_ipv4(host.rescue_ssh_host)
    return unless ip
    host.apply_all_credentials_to_env!
    ovh = Beryl::Providers::Ovh.new
    return unless ovh.available?
    STDERR.puts "  → résolution du service_name OVH via l'API (IP #{ip})…"
    sn = ovh.find_dedicated_server_by_ip(ip)
    if sn
      STDERR.puts "  ✓ service_name OVH = #{sn}"
    else
      STDERR.puts "  ⚠ aucun serveur dédié OVH avec l'IP #{ip} — `ovh.service_name` à mettre à la main."
    end
    sn
  rescue ex
    STDERR.puts "  ⚠ résolution service_name OVH impossible (#{ex.message}) — à mettre à la main."
    nil
  end

  # Résout une IPv4 depuis un host : déjà une IP → tel quel ; sinon DNS (A).
  def self.resolve_host_ipv4(host : String) : String?
    return host if host =~ /\A\d{1,3}(\.\d{1,3}){3}\z/
    Socket::Addrinfo.resolve(host, 22, family: Socket::Family::INET, type: Socket::Type::STREAM).first?.try(&.ip_address.address)
  rescue
    nil
  end

  # Résout une IPv6 depuis un host : déjà une IPv6 (contient `:`) → tel quel ;
  # sinon DNS (AAAA). nil si aucune (host sans IPv6 publique).
  def self.resolve_host_ipv6(host : String) : String?
    return host if host.includes?(':')
    Socket::Addrinfo.resolve(host, 22, family: Socket::Family::INET6, type: Socket::Type::STREAM).first?.try(&.ip_address.address)
  rescue
    nil
  end

  def self.default_hostname(fqdn : String) : String
    fqdn.split('.').first
  end

  # `beryl scan --discover <société>` : liste les serveurs dédiés OVH du
  # compte (API, SANS SSH ni rescue), repère ceux absents de la config, et
  # écrit un host.yml MINIMAL (provider + bloc ovh) pour chacun. Les
  # disques/ZFS/hardware restent à compléter via `beryl scan <host> --apply`
  # en mode rescue. N'écrase jamais un host.yml existant.
  #
  # Domaine cible : si la société n'en a qu'UN, il est choisi d'office ;
  # si plusieurs, on prend `--domain` s'il est fourni, sinon on DEMANDE
  # (interactif) ou on REFUSE en `--non-interactive`.
  private def self.discover_servers(root : Beryl::Config::Root, config_root : String,
                                    account : String, domain_hint : String?,
                                    non_interactive : Bool, dry_run : Bool) : Int32
    acct = root.account?(account)
    unless acct
      STDERR.puts "beryl : société inconnue : #{account}. Connues : #{root.accounts.keys.sort.join(", ")}"
      return EXIT_USAGE
    end
    domains = acct.domains.keys.sort
    if domains.empty?
      STDERR.puts "beryl : la société #{account} n'a aucun domaine — impossible de placer les host.yml."
      return EXIT_USAGE
    end
    domain =
      if domains.size == 1
        domains.first
      elsif dh = domain_hint
        unless domains.includes?(dh)
          STDERR.puts "beryl : domaine « #{dh} » inconnu pour #{account}. Domaines : #{domains.join(", ")}."
          return EXIT_USAGE
        end
        dh
      elsif non_interactive
        STDERR.puts "beryl : #{account} a #{domains.size} domaines (#{domains.join(", ")}). Précisez --domain=<domaine>."
        return EXIT_USAGE
      else
        prompt_discover_domain(account, domains)
      end

    root.env_file.apply_all_to_env(account, overwrite: true)
    ovh = Beryl::Providers::Ovh.new
    unless ovh.available?
      STDERR.puts "beryl : credentials OVH absents pour #{account} (voir `beryl add-provider`)."
      return EXIT_BAD_CREDS
    end

    puts "#{account} : liste des serveurs OVH (API)…"
    all = ovh.dedicated_server_names
    index = ovh.ip_to_service_index
    known = Beryl::CLI::Info.scoped_hosts(root, account).select(&.provider.==("ovh")).compact_map do |h|
      h.ovh_service_name || ((ip = resolve_host_ipv4(h.ssh_host)) ? index[ip]? : nil)
    end
    new_servers = all.reject { |sn| known.includes?(sn) }.sort

    if new_servers.empty?
      puts "#{account} : aucun nouveau serveur (#{all.size} déjà connu(s))."
      return EXIT_OK
    end
    puts "#{account} : #{new_servers.size} nouveau(x) serveur(s) sur #{all.size} — récupération des métadonnées…"

    written = 0
    planned = [] of String
    existing = root.all_hosts_by_fqdn.values.map do |e|
      {account: e[:account].name, domain: e[:domain].name, short: e[:node].name}
    end
    new_servers.each do |sn|
      detail = ovh.server_detail(sn)
      ipv6 = ovh.ipv6_address(sn)
      ipv6_gateway = ovh.ipv6_gateway(sn)
      price = ovh.monthly_price(sn)
      short = discover_short_name(ovh.server_display_name(sn), sn, domain)
      path = File.join(config_root, account, domain, "#{short}.host.yml")
      if File.exists?(path)
        puts "  ↷ #{sn} → #{short} : #{path} existe déjà, ignoré."
        next
      end
      planned << Beryl::CLI::AccountUtils.host_ref(short, account, domain, existing)
      if dry_run
        puts "  [dry-run] écrirait #{path} (#{detail[:commercial] || "gamme ?"}#{price ? ", #{price} €/mois" : ""})"
        next
      end
      Dir.mkdir_p(File.dirname(path))
      Beryl::CLI::Fmt.write(path, discover_skeleton(short, domain, sn, detail, ipv6, price, ipv6_gateway))
      written += 1
      puts "  ✓ #{sn} → #{short}.host.yml (#{detail[:commercial] || "gamme ?"}#{price ? ", #{price} €/mois" : ""})"
    end

    puts
    puts "#{written} squelette(s) écrit(s) sous #{config_root}/#{account}/#{domain}/."
    puts discover_next_steps(account, planned, dry_run)
    EXIT_OK
  end

  # Demande interactivement dans quel domaine placer les host.yml
  # découverts, quand la société en a plusieurs. Accepte un numéro ou le
  # nom du domaine.
  private def self.prompt_discover_domain(account : String, domains : Array(String)) : String
    STDERR.puts "#{account} a plusieurs domaines — où placer les nouveaux host.yml ?"
    domains.each_with_index { |d, i| STDERR.puts "  #{i + 1}. #{d}" }
    loop do
      ans = ask("Domaine (numéro ou nom) : ", default: domains.first).strip
      if (idx = ans.to_i?) && idx >= 1 && idx <= domains.size
        return domains[idx - 1]
      end
      return ans if domains.includes?(ans)
      STDERR.puts "  réponse invalide, recommencez."
    end
  end

  # Nom court d'un serveur découvert : le displayName OVH nettoyé s'il
  # existe, sinon un placeholder `new-<id>` (partie ns du serviceName) à
  # renommer par l'opérateur.
  # Un displayName qui est déjà le FQDN du domaine cible (`web1.example.net`
  # pour le domaine `example.net`) donne son nom court (`web1`) : sinon le
  # host deviendrait `web1-example-net.example.net`.
  def self.discover_short_name(display : String?, service_name : String, domain : String? = nil) : String
    if (d = display) && !d.strip.empty?
      d = d.strip.downcase.rchop('.')
      if (dom = domain) && d.ends_with?(".#{dom.downcase}")
        d = d.rchop(".#{dom.downcase}")
      end
      slug = d.gsub(/[^a-z0-9]+/, "-").strip('-')
      return slug unless slug.empty?
    end
    "new-#{service_name.split('.').first}"
  end

  # Suite à donner après `--discover`, avec les VRAIS noms de hosts (pas de
  # `<host>` générique). En dry-run : d'abord relancer avec `--apply`. Le
  # scan des disques exige le rescue : `beryl rescue` vient AVANT `scan`.
  def self.discover_next_steps(account : String, hosts : Array(String), dry_run : Bool) : String
    return "" if hosts.empty?
    String.build do |io|
      if dry_run
        io << "Pour écrire ces squelettes : beryl scan --discover " << account << " --apply\n"
      end
      io << "Renommez si besoin (fichier .host.yml), puis, pour chaque serveur, passez-le\n"
      io << "en rescue avant de lire ses disques (⚠ rescue = REDÉMARRAGE du serveur, coupure) :\n"
      hosts.each { |h| io << "  beryl rescue " << h << " --apply && beryl scan " << h << " --apply\n" }
    end.chomp
  end

  # Squelette host.yml minimal : en-tête + provider + bloc ovh (API, sans
  # rescue). Réutilise `Info.ovh_block`. Les disques/ZFS/hardware seront
  # ajoutés plus tard par `beryl scan <host> --apply`.
  private def self.discover_skeleton(short : String, domain : String, service_name : String,
                                     detail : NamedTuple(commercial: String?, datacenter: String?, rack: String?, ipv4: String?),
                                     ipv6 : String?, price : String?,
                                     ipv6_gateway : String? = nil) : String
    stamp = Time.local.to_s("%d/%m/%Y %Hh%Mm%S")
    lines = [
      "# #{short}.#{domain}",
      "# Généré par `beryl scan --discover` le #{stamp} — SQUELETTE minimal.",
      "# Métadonnées OVH via API (sans rescue). Complétez disques/ZFS/hardware",
      "# via `beryl scan #{short}.#{domain} --apply` en mode rescue.",
      "",
      "installed: false # sauté par update/upgrade/os-upgrade ; retiré par `beryl bootstrap`",
      "provider: ovh",
    ]
    lines.concat(Beryl::CLI::Info.ovh_block(service_name, detail[:commercial], detail[:rack], detail[:ipv4], ipv6, price, ipv6_gateway, detail[:datacenter]))
    lines.join('\n') + "\n"
  end

  # `existing` : fiche ACTUELLE du serveur (même nom court), là où elle est —
  # y compris dans un groupe (`<domaine>/<groupe>/`) : réécrite sur place,
  # jamais doublée à la racine du domaine.
  def self.resolve_write_target(explicit : String?, auto : Bool, config_root : String, account_name : String, domain_name : String, short : String, existing : String? = nil) : String?
    return explicit if explicit
    return unless auto
    return existing if existing && File.basename(existing) == "#{short}.host.yml"
    File.join(config_root, account_name, domain_name, "#{short}.host.yml")
  end

  # Construit la commande à proposer quand beryl scan affiche un YAML
  # en mode suggestion (dry-run) : même args, mais en ajoutant
  # `--apply` et, si l'opérateur n'a pas passé `--hostname`, le short
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
    # `--apply` est ajouté par `Beryl.rerun_hint` (convention : dry-run par
    # défaut, `--apply` pour écrire le host.yml + actions --dns).
    replace = if raw_host && normalized_host
                {raw_host, normalized_host}
              end
    Beryl.rerun_hint("scan", args, extras, replace_host: replace)
  end

  # Variante Dedibox du flux `--dns`. Différences :
  #   - IPs + current_hostname viennent de l'API Dedibox
  #     (`GET /server/{id}`), pas OVH.
  #   - records A/AAAA posés via le dns_provider RÉEL de la zone
  #     (OVH, Gandi… selon `host.dns_provider`), via
  #     `DnsApply.forward_via_dns_provider`.
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
      log "DRY-RUN : plan DNSDedibox affiché, aucun appel API effectué"
      return plan
    end
    unless non_interactive
      ans = ask("Exécuter ces actions ? [o/N] : ", default: "N")
      raise Aborted.new unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
    end

    # Forward A/AAAA via le dns_provider RÉEL de la zone (multi-provider) :
    # OVH, Gandi… selon `host.dns_provider`. Plus de hardcode OVH (la zone
    # pouvait être hébergée ailleurs → 404). Le reverse Dedibox reste
    # manuel (l'API ne l'expose pas, cf. plan ci-dessus).
    logger = Proc(String, Nil).new { |m| log(m); nil }
    Beryl::CLI::DnsApply.forward_via_dns_provider(host, zone, short, ipv4, ipv6, logger)

    # Rename côté console Dedibox (via PUT /server/{id}).
    if current_hostname != short
      log "3 Dedibox : renomme hostname console : #{server_id} → #{short}"
      dedibox.servers.update_hostname(server_id, short)
    end

    log "3 Dedibox : nommage DNS posé : #{fqdn} ↔ serveur #{server_id} (reverse DNS à poser manuellement)"
    plan
  end

  # Variante Scaleway de `run_dns_setup`. Différences vs Dedibox :
  #
  #   - IPs + current_name viennent de l'API Scaleway
  #     (`client.baremetal.servers.get(uuid, zone)`). Si la zone
  #     n'est pas fournie explicitement (cas d'un UUID brut venu
  #     du shortcut), on la retrouve via `find_any_zone`.
  #   - Records A/AAAA posés via le dns_provider RÉEL de la zone
  #     (OVH, Gandi…). Même code que Dedibox (`forward_via_dns_provider`).
  #   - Rename console : `client.baremetal.servers.update(name:)`.
  #     Scaleway n'a pas de séparation « nom système / nom console »
  #     comme Dedibox : le `name` sert de nom d'affichage dans la
  #     console et dans les logs d'install.
  #   - Reverse DNS : EXPOSÉ par l'API Scaleway,
  #     `client.baremetal.servers.update(reverse:)`. Contrairement
  #     à Dedibox (qui force l'opérateur à passer par la console
  #     web), on peut le poser automatiquement.
  def self.run_dns_setup_scaleway(
    host : Beryl::Config::ResolvedHost,
    hostname_flag : String?,
    zone_flag : String?,
    non_interactive : Bool,
    dry_run : Bool,
    server_id : String,
    zone_override : String?,
  ) : Beryl::CLI::DnsSetup::Plan
    short = hostname_flag || (non_interactive ? raise("--dns + --non-interactive requiert --hostname=NAME") : ask("Nom court du serveur (ex: chouquette) : ", default: ""))
    raise Aborted.new if short.empty?
    dns_zone = zone_flag || host.domain_name
    fqdn = "#{short}.#{dns_zone}"

    scaleway = Beryl::CLI::Credentials.scaleway_client
    # Zone Scaleway : priorité au flag → YAML → scan multi-zones.
    # Si le scan ne trouve pas, message d'erreur clair.
    server = if zone_override
               scaleway.baremetal.servers.get(server_id: server_id, zone: zone_override)
             else
               scaleway.baremetal.servers.find_any_zone(server_id) ||
                 raise "Scaleway UUID #{server_id} : introuvable dans les zones connues"
             end
    scw_zone = server.zone || raise "Scaleway : zone indéterminée pour #{server_id}"
    ipv4_obj = server.ips.find { |ip| ip.version == "IPv4" } ||
               server.ips.first? ||
               raise "aucune IP attachée au serveur Scaleway #{server_id}"
    ipv6_obj = server.ips.find { |ip| ip.version == "IPv6" }
    ipv4 = ipv4_obj.address
    ipv6 = ipv6_obj.try(&.address)
    current_name = server.name || ""
    current_reverse_v4 = ipv4_obj.reverse
    current_reverse_v6 = ipv6_obj.try(&.reverse)

    plan = Beryl::CLI::DnsSetup::Plan.new(
      service_name: server_id,
      fqdn: fqdn,
      short_name: short,
      zone: dns_zone,
      ipv4: ipv4,
      ipv6: ipv6,
    )
    STDERR.puts
    STDERR.puts "Actions DNS + Scaleway prévues pour serveur #{server_id} (zone #{scw_zone}) :"
    STDERR.puts "  1. Créer (ou vérifier) A     #{fqdn}  →  #{ipv4}"
    if v6 = ipv6
      STDERR.puts "  2. Créer (ou vérifier) AAAA  #{fqdn}  →  #{v6}"
    else
      STDERR.puts "  2. AAAA : aucune IPv6 publique détectée côté Scaleway, ignoré"
    end
    STDERR.puts "  3. Rafraîchir la zone #{dns_zone}"
    if current_name == short
      STDERR.puts "  4. nom console Scaleway déjà à #{short}, rien à faire"
    else
      STDERR.puts "  4. Renommer console Scaleway : #{current_name.empty? ? "(aucun)" : current_name}  →  #{short}"
    end
    if current_reverse_v4 == fqdn
      STDERR.puts "  5. Reverse DNS IPv4 déjà à #{fqdn}, rien à faire"
    else
      STDERR.puts "  5. Reverse DNS IPv4 : #{current_reverse_v4 || "(aucun)"}  →  #{fqdn}"
    end
    if ipv6_obj
      if current_reverse_v6 == fqdn
        STDERR.puts "  6. Reverse DNS IPv6 déjà à #{fqdn}, rien à faire"
      else
        STDERR.puts "  6. Reverse DNS IPv6 : #{current_reverse_v6 || "(aucun)"}  →  #{fqdn}"
      end
    end
    STDERR.puts

    if dry_run
      log "DRY-RUN : plan DNSScaleway affiché, aucun appel API effectué"
      return plan
    end
    unless non_interactive
      ans = ask("Exécuter ces actions ? [o/N] : ", default: "N")
      raise Aborted.new unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
    end

    # Forward A/AAAA via le dns_provider RÉEL de la zone (multi-provider) :
    # OVH, Gandi… selon `host.dns_provider`. Le reverse + rename ci-dessous
    # restent spécifiques au compute Scaleway (API baremetal).
    logger = Proc(String, Nil).new { |m| log(m); nil }
    Beryl::CLI::DnsApply.forward_via_dns_provider(host, dns_zone, short, ipv4, ipv6, logger)

    # Rename + reverse IPv4 via un PATCH global sur l'API Scaleway.
    # `servers.update(reverse:)` ne s'applique qu'à l'IP primaire
    # (IPv4). L'update est idempotent côté Scaleway : renvoyer un
    # nom ou un reverse déjà en place n'est pas une erreur.
    new_name = current_name == short ? nil : short
    new_reverse_v4 = current_reverse_v4 == fqdn ? nil : fqdn
    if new_name || new_reverse_v4
      log "3 Scaleway : PATCH server name=#{new_name || "(inchangé)"} reverse_v4=#{new_reverse_v4 || "(inchangé)"}"
      scaleway.baremetal.servers.update(
        server_id: server_id,
        zone: scw_zone,
        name: new_name,
        reverse: new_reverse_v4,
      )
    end

    # Reverse IPv6 via un PATCH par IP (endpoint séparé côté Scaleway,
    # scaleway-api 0.4.2+). Si pas d'IPv6 ou reverse déjà en place,
    # on ne fait rien.
    if ipv6_obj && current_reverse_v6 != fqdn
      log "3 Scaleway : PATCH ip #{ipv6_obj.id} reverse_v6=#{fqdn}"
      scaleway.baremetal.servers.update_ip(
        server_id: server_id,
        ip_id: ipv6_obj.id,
        reverse: fqdn,
        zone: scw_zone,
      )
    end

    log "3 Scaleway : nommage DNS posé : #{fqdn} ↔ serveur #{server_id} (zone #{scw_zone})"
    plan
  end

  # DNS du host, APRÈS le scan et l'écriture de la fiche : forward via le
  # dns_provider RÉEL de la zone (Gandi, OVH… ; ADR-014), reverse + rename chez
  # l'hébergeur — même cœur que `beryl dns` (Beryl::CLI::DnsApply). BEST-EFFORT :
  # un échec (zone introuvable, API qui 404…) est signalé sans rien annuler du
  # scan. Constaté qsbg, 9 juin 2026 : quand le DNS passait en premier, un 404
  # OVH sur une zone Gandi avortait TOUT le scan. `short` = le nom de la fiche.
  # En dry-run, chaque flux respecte le flag et n'appelle aucune API.
  private def self.run_dns(host : Beryl::Config::ResolvedHost, provider : String?, short : String, zone_flag : String?,
                           dry_run : Bool, non_interactive : Bool, server_id_flag : String?, scaleway_zone_override : String?) : Nil
    case provider
    when "ovh"
      Beryl::CLI::DnsApply.for_host(host, short, zone_flag, dry_run, non_interactive, cmd: "beryl scan")
    when "scaleway"
      sid = server_id_flag || host.scaleway_server_id || raise MissingProviderConfig.new(
        "DNS + provider=scaleway : server_id manquant (ni --server-id, ni scaleway.server_id dans le merge)"
      )
      zone = scaleway_zone_override || host.scaleway_zone
      run_dns_setup_scaleway(host, short, zone_flag, non_interactive, dry_run, sid, zone)
    when "dedibox"
      sid = server_id_flag || host.dedibox_server_id || raise MissingDediboxServerId.new
      run_dns_setup_dedibox(host, short, zone_flag, non_interactive, dry_run, sid)
    else
      STDERR.puts "beryl : DNS non câblé pour provider=#{provider.inspect} (supportés : dedibox, ovh, scaleway)."
    end
  rescue ex
    STDERR.puts "beryl : étape DNS non aboutie (#{ex.class}: #{ex.message}) — la fiche est écrite ; " \
                "relancez `beryl dns #{host.account_name}/#{short}.#{host.domain_name}`."
  end

  # Question posée après l'écriture de la fiche (oui par défaut ; oui sans
  # question en --non-interactive).
  private def self.dns_wanted?(fqdn : String, non_interactive : Bool) : Bool
    return true if non_interactive
    STDERR.puts # ligne vide : la question se détache du journal qui précède
    ans = ask("Voulez-vous lancer le DNS de #{fqdn} (forward A/AAAA, reverse, rename chez l'hébergeur) ? [O/n] : ", default: "O")
    !ans.downcase.starts_with?("n")
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
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl scan] #{Beryl.format_step(message)}"
  end
end
