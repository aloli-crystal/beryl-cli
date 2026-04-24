require "option_parser"
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "dedibox-api/dedibox_api"
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

  class MissingProviderConfig < Exception
  end

  # Un pool ZFS déclaré par l'opérateur : nom ZFS, disques alloués,
  # niveau RAID numérique (0|1|5|6|7|10), et `boot: true` pour
  # exactement UN pool (le zroot, pool système — `mountpoint` nil).
  #
  # Convention Aloli pour les pools data : l'opérateur tape un nom
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
      p.on("-P NAME", "--provider=NAME", "Surcharge `provider:` du merge (ex: dedibox, ovh, scaleway)") { |v| provider_override = v }
      p.on("-I ID", "--server-id=ID", "ID serveur côté hébergeur (ex: Dedibox entier, Scaleway UUID). Inutile pour OVH (le FQDN est le service_name)") { |v| server_id_flag = v }
      p.on("-n", "--dry-run", "Affiche ce qui serait fait sans écrire ni appeler d'API") { dry_run = true }
      p.on("-w", "--write", "Écrit ~/.beryl/<domaine>/<nom>.yml") { write_auto = true }
      p.on("-W PATH", "--write-to=PATH", "Écrit dans le chemin explicite") { |v| write_path = File.expand_path(v, home: true) }
      p.on("-k LIST", "--disks=LIST", "Disques du pool zroot (ex: sda,sdb | 'all')") { |v| disks_flag = v }
      p.on("-r N", "--raid=N", "Niveau RAID du pool zroot (0|1|5|6|7|10)") { |v| raid_flag = v }
      p.on("--pool=SPEC", "Pool additionnel NAME:DISKS:RAID (répétable, ex: zdata:sda,sdb:10)") { |v| pool_specs << v }
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
      when "scaleway"
        sid = server_id_flag || host.scaleway_server_id || raise MissingProviderConfig.new(
          "--dns + provider=scaleway : server_id manquant (ni --server-id, ni scaleway.server_id dans le merge)"
        )
        zone = scaleway_zone_override || host.scaleway_zone
        dns_plan = run_dns_setup_scaleway(host, hostname_flag, zone_flag, non_interactive, dry_run, sid, zone)
      when "dedibox"
        sid = server_id_flag || host.dedibox_server_id || raise MissingDediboxServerId.new
        dns_plan = run_dns_setup_dedibox(host, hostname_flag, zone_flag, non_interactive, dry_run, sid)
      else
        STDERR.puts "beryl : --dns n'est pas câblé pour provider=#{effective_provider.inspect} " \
                    "(supportés : dedibox, ovh, scaleway). Le scan continue sans DNS."
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
        STDERR.puts "  Convention Aloli : le nom que vous tapez (ex: data) sera utilisé"
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

    yaml = render_yaml(host, short, pools,
      provider_override: provider_override, server_id_override: server_id_flag,
      scaleway_zone_override: scaleway_zone_override)
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
      STDERR.puts "    - Dedibox  : injection IAM automatique en rescue — vérifier que beryl a fait le promote 4/4"
      STDERR.puts "    - OVH      : https://www.ovh.com → Serveurs → Clés SSH (puis `ovh.ssh_key_name`)"
      STDERR.puts "    - Scaleway : https://console.scaleway.com → IAM → SSH keys (org-wide)"
    end
    EXIT_SSH_FAILED
  rescue ex : Aborted
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
      next nil if stripped.empty?
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
  # Format des messages (norme Aloli) :
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
    raise "--non-interactive requiert --disks=LIST (ou --pool=NAME:DISKS:RAID)" if non_interactive
    ask_until_valid(
      "Disques à utiliser pour #{pool_name} ? (1,2 | sda,sdb | 'all') [défaut : all] : ",
      default: "all",
    ) { |ans| resolve_disk_selection(candidates, ans) }
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
  # Convention parlante Aloli : 0, 1, 5, 6, 7, 10 plutôt que
  # stripe/mirror/raidz…
  #
  # Format cohérent avec `pick_disks_for` : options entre `(…)`,
  # défaut entre `[…]` avec espaces français autour des `:`.
  # Niveau RAID par défaut : toujours 0 (stripe), convention Aloli —
  # backups bétonnés > redondance disque. L'opérateur qui veut
  # autre chose doit le dire explicitement, pas de magie sur le
  # nombre de disques (un défaut qui change selon le contexte = UX
  # imprévisible).
  DEFAULT_RAID = 0

  private def self.pick_raid_for(pool_name : String, count : Int32, flag : String?, non_interactive : Bool) : Int32
    _ = count
    if flag
      return validate_raid!(flag)
    end
    return DEFAULT_RAID if non_interactive
    ask_until_valid(
      "Niveau RAID de #{pool_name} (0=stripe 1=mirror 5=raidz 6=raidz2 7=raidz3 10=mirror_stripe) [défaut : #{DEFAULT_RAID}] : ",
      default: DEFAULT_RAID.to_s,
    ) { |ans| validate_raid!(ans) }
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
    raid = validate_raid!(raid_str)
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
      pools.each do |pool|
        io << "    " << pool.name << ":              # nom du pool côté ZFS (`zpool list`)\n"
        io << "      boot: true        # c'est le pool système (exactement un)\n" if pool.boot
        if mp = pool.mountpoint
          io << "      mountpoint: " << mp << "   # point de montage FreeBSD\n"
        end
        io << "      raid: " << pool.raid << "             # 0=stripe 1=mirror 5=raidz 6=raidz2 7=raidz3 10=mirror_stripe\n"
        io << "      disks:\n"
        pool.disks.each { |d| io << "        - " << d.dev_path << "  # " << d.human_size << " " << d.kind << " " << d.model << '\n' }
      end
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

  # Variante Scaleway de `run_dns_setup`. Différences vs Dedibox :
  #
  #   - IPs + current_name viennent de l'API Scaleway
  #     (`client.baremetal.servers.get(uuid, zone)`). Si la zone
  #     n'est pas fournie explicitement (cas d'un UUID brut venu
  #     du shortcut), on la retrouve via `find_any_zone`.
  #   - Records A/AAAA posés via le DNS provider de la zone
  #     (OVH côté Aloli). Même code que Dedibox.
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
    ipv4 = server.ips.find { |ip| ip.version == "IPv4" }.try(&.address) ||
           server.ips.first?.try(&.address) ||
           raise "aucune IP attachée au serveur Scaleway #{server_id}"
    ipv6 = server.ips.find { |ip| ip.version == "IPv6" }.try(&.address)
    current_name = server.name || ""
    current_reverse = server.ips.find { |ip| ip.version == "IPv4" }.try(&.reverse)

    plan = Beryl::CLI::DnsSetup::Plan.new(
      service_name: server_id,
      fqdn: fqdn,
      short_name: short,
      zone: dns_zone,
      ipv4: ipv4,
      ipv6: ipv6,
      current_display_name: current_name,
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
    if current_reverse == fqdn
      STDERR.puts "  5. Reverse DNS IPv4 déjà à #{fqdn}, rien à faire"
    else
      STDERR.puts "  5. Reverse DNS IPv4 : #{current_reverse || "(aucun)"}  →  #{fqdn}"
    end
    STDERR.puts

    if dry_run
      log "DRY-RUN : plan DNS Scaleway affiché, aucun appel API effectué"
      return plan
    end
    unless non_interactive
      ans = ask("Exécuter ces actions ? [o/N] : ", default: "N")
      raise Aborted.new unless ans.downcase.starts_with?("o") || ans.downcase.starts_with?("y")
    end

    # Records DNS via le DNS provider (OVH côté Aloli aujourd'hui).
    # Même logique que Dedibox : si la zone est ailleurs qu'OVH, il
    # faudra une abstraction DnsProvider — pas encore câblée.
    ovh = Beryl::CLI::Credentials.ovh_client
    logger = Proc(String, Nil).new { |m| log(m); nil }
    Beryl::CLI::DnsSetup.ensure_record(ovh, dns_zone, "A", short, ipv4, logger)
    if v6 = ipv6
      Beryl::CLI::DnsSetup.ensure_record(ovh, dns_zone, "AAAA", short, v6, logger)
    end
    Beryl::CLI::DnsSetup.refresh_zone(ovh, dns_zone, logger)

    # Rename + reverse via un PATCH unique sur l'API Scaleway.
    # L'update est idempotent côté Scaleway : renvoyer un nom ou un
    # reverse déjà en place n'est pas une erreur.
    new_name = current_name == short ? nil : short
    new_reverse = current_reverse == fqdn ? nil : fqdn
    if new_name || new_reverse
      log "Scaleway : PATCH server name=#{new_name || "(inchangé)"} reverse=#{new_reverse || "(inchangé)"}"
      scaleway.baremetal.servers.update(
        server_id: server_id,
        zone: scw_zone,
        name: new_name,
        reverse: new_reverse,
      )
    end

    log "nommage DNS + Scaleway posé : #{fqdn} ↔ serveur #{server_id} (zone #{scw_zone})"
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
