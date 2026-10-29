require "option_parser"
require "./scope"
require "./option_errors"
require "../config"
require "../apply"
require "../vrack_zone"
require "ssh"
require "./account_utils"
require "./dns_record"
require "./fleet_job"

# Sous-commande `beryl sync <host>` : applique sur le serveur FreeBSD
# (déjà bootstrappé) les *recettes* déclarées dans le dossier
# d'orchestration du host.
#
# Architecture à 2 niveaux (cf. `apply-recipes-architecture.adoc`) :
#   * recettes YAML reliées par `requires:` (résolution récursive,
#     tri topologique, détection de cycle) ;
#   * primitives Crystal natives idempotentes (`pkg-install`, …).
#
# Dossiers lus :
#   * recettes PRIVÉES de la société : `<config>/<société>/recipes/` ;
#   * dépôt central : `<recipes.local_path>/recipes/`
#     (défaut `<config>/recipes/recipes/`).
#
# Priorité de résolution : recettes de la société > dépôt central. Idempotence :
# chaque primitive lit l'état réel via SSH avant d'agir. Dry-run par
# défaut (calcule le plan sans rien modifier) ; `--apply` pour appliquer.
module Beryl::CLI::Apply
  EXIT_OK         =  0
  EXIT_USAGE      =  1
  EXIT_UNEXPECTED =  3
  EXIT_SSH_FAILED =  4
  EXIT_NO_FREEBSD = 10
  EXIT_RECIPE     = 11
  # Serveur nommé explicitement mais `installed: false` : à bootstrapper d'abord.
  EXIT_NOT_INSTALLED = 12

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = true
    parallel : Int32? = nil
    sequential = false
    canary : String? = nil
    detach = false
    status = false
    job_dir : String? = nil
    declared_only = false
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl sync <host|groupe|domaine|société|a,b,…> [recette] [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
      p.on("--parallel=N", "Plusieurs serveurs en --apply : canari puis N à la fois (défaut : réglage `parallel:` de la configuration, sinon 4 ; `no` = un après l'autre)") do |v|
        n = Beryl::CLI::FleetJob.parse_parallel(v)
        n == 0 ? (sequential = true) : (parallel = n)
      end
      p.on("--no-parallel", "Plusieurs serveurs : un après l'autre, sortie à l'écran (sans tâche de flotte)") { sequential = true }
      p.on("--canary=HOST", "Plusieurs serveurs : canari choisi (défaut : le premier de la portée)") { |v| canary = v }
      p.on("--detach", "Plusieurs serveurs : tâche en arrière-plan (suivi par --status)") { detach = true }
      p.on("--status", "État de la dernière tâche de flotte (ou de TÂCHE)") { status = true }
      p.on("--job=DIR", "(interne) orchestrateur d'une tâche détachée") { |v| job_dir = v }
      p.on("--declared-only", "(interne) recette ponctuelle seulement si le serveur la déclare") { declared_only = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)
    # `a, b, c` (espaces après les virgules, coupés par le shell) → `a,b,c`.
    positional = Beryl::CLI::Scope.join_list(positional)

    return Beryl::CLI::FleetJob.status("sync", positional.first?) if status
    if jd = job_dir
      return Beryl::CLI::FleetJob.run(jd, Beryl::CLI::FleetJob.self_cmd(config_root))
    end
    if (n = parallel) && n < 1
      STDERR.puts "beryl : --parallel attend un entier ≥ 1."
      return EXIT_USAGE
    end

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : portée non précisée. USAGE : beryl sync <host|domaine|société> [recette]"
      return EXIT_USAGE
    end
    # 2e positionnel optionnel : une recette nommée à appliquer en
    # ONE-OFF (non persistée dans la config), ex. une rotation de clé.
    adhoc_recipe = positional[1]?
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    @@fleet_root = root
    # Portée : host, domaine OU société (comme rotate-key). `apply example.net`
    # → tous les hosts du domaine ; `apply acme` → toute la société.
    list = raw.includes?(',')
    if list && !(unknown = unknown_parts(root, raw, account_hint, domain_hint)).empty?
      STDERR.puts "beryl : élément(s) inconnu(s) dans la liste #{raw} : #{unknown.join(", ")} (ni host, ni groupe, ni domaine, ni société)."
      return EXIT_USAGE
    end
    hosts = list ? resolve_list(root, raw, account_hint, domain_hint) : resolve_hosts(root, host_name, account_hint, domain_hint)
    if hosts.empty?
      STDERR.puts "beryl : portée inconnue : #{raw} (ni host, ni groupe, ni domaine, ni société). " \
                  "Sociétés configurées : #{root.accounts.keys.sort.join(", ")}"
      return EXIT_USAGE
    end
    log "portée #{raw} → #{hosts.size} hosts : #{hosts.map(&.short_name).join(", ")}" if hosts.size > 1

    # `installed: false` (pas encore bootstrappé) : sauté sur une portée
    # (société, domaine), comme update/upgrade/os-upgrade ; refusé s'il est
    # nommé explicitement — au lieu d'un échec de connexion SSH.
    single_host = !list && host_scope?(root, host_name, account_hint, domain_hint)
    # Serveurs NOMMÉS d'une liste (`zgra,zrbx`) : traités comme un serveur nommé.
    named = list ? named_hosts(root, raw, account_hint, domain_hint) : Set(String).new
    pending, hosts = split_installed(hosts)
    if !pending.empty? && single_host
      ref = Beryl::CLI::AccountUtils.host_ref(pending.first)
      STDERR.puts "beryl : #{pending.first.fqdn} n'est pas encore installé (installed: false) — " \
                  "lancez d'abord `beryl bootstrap #{ref} --apply`."
      return EXIT_NOT_INSTALLED
    end
    pending.each { |h| log "#{h.fqdn} : pas encore installé (installed: false) → sauté." }
    if hosts.empty?
      STDERR.puts "beryl : aucun serveur installé dans la portée #{raw}."
      return EXIT_USAGE
    end

    # `--apply` sur plusieurs serveurs : tâche de flotte PAR DÉFAUT (canari puis
    # N à la fois, cf. FleetJob ; N = --parallel, sinon le réglage `parallel:`,
    # sinon 4), chaque serveur traité par un `beryl sync <fqdn> [recette]
    # --apply` enfant. `--no-parallel` : un après l'autre, sortie à l'écran.
    # En dry-run, le plan reste séquentiel (lecture seule, d'un seul tenant).
    if !sequential && !dry_run && hosts.size > 1
      n = Beryl::CLI::FleetJob.parallel_for(hosts, parallel)
      fqdns = hosts.map(&.fqdn)
      if c = canary
        first = hosts.find { |h| h.fqdn == c || h.short_name == c }
        unless first
          STDERR.puts "beryl : canari « #{c} » absent de la portée #{raw}."
          return EXIT_USAGE
        end
        fqdns = [first.fqdn] + (fqdns - [first.fqdn])
      end
      child_args = [adhoc_recipe].compact + ["--apply"]
      # Recette ponctuelle : chaque enfant ne voit qu'UN serveur (nommé) ; la
      # règle « seulement là où elle est déclarée » lui est passée, sauf si
      # TOUS les serveurs de la portée ont été nommés.
      child_args << "--declared-only" if adhoc_recipe && !hosts.all? { |h| named.includes?(h.fqdn) }
      groups = hosts.compact_map { |h| h.reboot_group.try { |g| {h.fqdn, g} } }.to_h
      log "portée #{raw} : #{fqdns.size} serveurs → canari #{fqdns.first}, puis #{n} en parallèle"
      dir = Beryl::CLI::FleetJob.create("sync", raw, fqdns, child_args, n, groups,
        account: hosts.first.account_name, config_root: config_root)
      if detach
        pid = Beryl::CLI::FleetJob.detach(dir, Beryl::CLI::FleetJob.self_cmd(config_root))
        log "tâche #{File.basename(dir)} lancée en arrière-plan (pid #{pid}) — suivi : `beryl sync --status`"
        return EXIT_OK
      end
      return Beryl::CLI::FleetJob.run(dir, Beryl::CLI::FleetJob.self_cmd(config_root))
    end

    # Une erreur sur un host ne doit pas avorter le reste de la flotte :
    # apply_one capture ses propres erreurs et renvoie un code EXIT.
    worst = EXIT_OK
    # Recette ponctuelle sur un domaine ou une société : seuls les serveurs
    # qui la déclarent l'appliquent (cf. adhoc_requests).
    hosts.each do |host|
      # Serveur nommé (seul ou dans une liste) : la recette ponctuelle vaut
      # pour lui ; domaine, société, groupe : seulement là où elle est déclarée.
      rc = apply_one(config_root, host, adhoc_recipe, dry_run, restrict_adhoc: declared_only || (!single_host && !named.includes?(host.fqdn)))
      worst = rc unless rc == EXIT_OK
    end
    worst
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # {non installés, installés} (`installed: false` dans le host.yml).
  def self.split_installed(hosts : Array(Beryl::Config::ResolvedHost)) : Tuple(Array(Beryl::Config::ResolvedHost), Array(Beryl::Config::ResolvedHost))
    hosts.partition { |h| !h.installed? }
  end

  # La portée désigne-t-elle UN serveur (et non un domaine ou une société) ?
  private def self.host_scope?(root : Beryl::Config::Root, scope : String, account_hint : String?, domain_hint : String?) : Bool
    root.resolve(scope, account_hint: account_hint, domain_hint: domain_hint)
    true
  rescue Beryl::Config::Root::HostNotFound | Beryl::Config::Root::UnknownDomain
    false
  end

  # Portée d'apply → liste de hosts. Host d'abord (le plus précis), sinon
  # domaine (dans toute société, ou celle forcée par -a), sinon société
  # entière (tous les hosts de tous ses domaines).
  private def self.resolve_hosts(root : Beryl::Config::Root, scope : String, account_hint : String?, domain_hint : String?) : Array(Beryl::Config::ResolvedHost)
    begin
      return [root.resolve(scope, account_hint: account_hint, domain_hint: domain_hint)]
    rescue Beryl::Config::Root::HostNotFound | Beryl::Config::Root::UnknownDomain
      # pas un host → on tente domaine puis société.
    end

    root.accounts.each_value do |account|
      next if account_hint && account.name != account_hint
      if domain = account.domain?(scope)
        return resolve_domain_hosts(root, account, domain)
      end
    end

    if account = root.account?(scope)
      return account.domains.values.flat_map { |domain| resolve_domain_hosts(root, account, domain) }
    end

    # Groupe (`<domaine>/<groupe>.group.yml` + `<groupe>/*.host.yml`) : ses
    # serveurs, dans tous les domaines qui en ont un de ce nom (sauf -a/-d).
    group_hosts = [] of Beryl::Config::ResolvedHost
    root.accounts.each_value do |acct|
      next if account_hint && acct.name != account_hint
      acct.domains.each_value do |domain|
        next if domain_hint && domain.name != domain_hint
        next unless group = domain.groups[scope]?
        group.hosts.each_key do |hn|
          group_hosts << root.resolve(hn, account_hint: acct.name, domain_hint: domain.name)
        rescue
          next
        end
      end
    end
    group_hosts
  end

  # Éléments d'une liste qui ne désignent aucun serveur (faute de frappe…) :
  # refusés plutôt qu'ignorés en silence.
  def self.unknown_parts(root : Beryl::Config::Root, scope : String, account_hint : String?, domain_hint : String?) : Array(String)
    scope.split(',').map(&.strip).reject(&.empty?).select { |part| resolve_hosts(root, part, account_hint, domain_hint).empty? }
  end

  # FQDN des éléments d'une liste qui sont des SERVEURS (et non un groupe, un
  # domaine ou une société).
  private def self.named_hosts(root : Beryl::Config::Root, scope : String, account_hint : String?, domain_hint : String?) : Set(String)
    scope.split(',').map(&.strip).reject(&.empty?).compact_map do |part|
      root.resolve(part, account_hint: account_hint, domain_hint: domain_hint).fqdn
    rescue Beryl::Config::Root::HostNotFound | Beryl::Config::Root::UnknownDomain
      nil
    end.to_set
  end

  # Portée LISTE `a,b,c` : union des portées citées (serveur, groupe, domaine,
  # société), dans l'ordre de la liste, sans doublon. Pur côté config.
  def self.resolve_list(root : Beryl::Config::Root, scope : String, account_hint : String?, domain_hint : String?) : Array(Beryl::Config::ResolvedHost)
    scope.split(',').map(&.strip).reject(&.empty?)
      .flat_map { |part| resolve_hosts(root, part, account_hint, domain_hint) }.uniq(&.fqdn)
  end

  private def self.resolve_domain_hosts(root : Beryl::Config::Root, account : Beryl::Config::Account, domain : Beryl::Config::Domain) : Array(Beryl::Config::ResolvedHost)
    domain.all_hosts.keys.compact_map do |hn|
      root.resolve(hn, account_hint: account.name, domain_hint: domain.name)
    rescue
      nil
    end
  end

  # Applique les recettes à UN host. Retourne un code EXIT. Capture ses
  # erreurs (recette, SSH…) pour ne pas avorter une boucle de flotte.
  private def self.apply_one(config_root : String, host : Beryl::Config::ResolvedHost, adhoc_recipe : String?, dry_run : Bool, restrict_adhoc : Bool = false) : Int32
    host.apply_all_credentials_to_env!

    # Apply gère FreeBSD, et Linux sous systemd pour les recettes qui le
    # déclarent (`systems:`). Le système déclaré (`os:` du host.yml) est
    # comparé plus bas à celui que le serveur annonce (`uname -s`).
    unless {Beryl::Apply::FREEBSD, Beryl::Apply::LINUX}.includes?(host.os)
      STDERR.puts "beryl : #{host.fqdn} ignoré (apply = os: freebsd ou linux, os : #{host.os})."
      return EXIT_USAGE
    end
    # Un host virtuel (pas de `.host.yml`) n'a pas de connexion.
    if host.virtual
      log "#{host.fqdn} : host virtuel, rien à appliquer."
      Beryl::CLI::FleetJob.report(Beryl::CLI::FleetJob::UPTODATE, "host virtuel")
      return EXIT_OK
    end
    # Garde-fou : un host `protected: true` refuse un apply RÉEL (écriture). Le
    # dry-run (plan, lecture seule) reste permis. Pour les serveurs sensibles
    # (cible de pentest, gelés). Générique — aucun nom d'hôte en dur (libre).
    if !dry_run && host.protected?
      log "#{host.fqdn} : protégé (protected: true) → apply RÉEL refusé (le plan est le défaut, sans --apply)."
      Beryl::CLI::FleetJob.report(Beryl::CLI::FleetJob::CANCELLED, "protégé (protected: true)")
      return EXIT_OK
    end

    search_path = recipes_search_path(config_root, host)

    # Recettes d'ENTRÉE : la liste `apply_recipes:` cascadée du merge (état
    # désiré, versionné) + recettes-shell dérivées des users (ex. `shell:
    # oh-my-zsh` → recette oh-my-zsh avec user: <nom>) ; ou, en mode
    # ponctuel, la seule recette nommée en argument.
    declared = apply_recipes_list(host) + user_shell_recipe_requests(host)
    # `skip_recipes:` du host.yml : recettes héritées (défauts société ou
    # domaine) à NE PAS jouer sur cet hôte. Retirées AVANT la résolution, pour
    # que leurs dépendances (`requires:`) ne passent pas non plus.
    unless (skip = host.skip_recipes).empty?
      if (removed = declared.select { |req| skip.includes?(req.name) }).size > 0
        log "écartées (skip_recipes de #{host.fqdn}) : #{removed.map(&.name).uniq.join(", ")}"
        declared = declared.reject { |req| skip.includes?(req.name) }
      end
    end
    resolver = Beryl::Apply::Resolver.new(search_path)
    requests = declared
    if r = adhoc_recipe
      # Recettes tirées par les déclarées (`requires:`) : utile seulement
      # sur une portée multiple, pour une recette non déclarée en direct.
      closure =
        if restrict_adhoc && declared.none? { |req| req.name == r }
          resolver.resolve(declared.map(&.name).uniq).map(&.name)
        else
          [] of String
        end
      adhoc = adhoc_requests(r, declared, closure, restrict_adhoc)
      unless adhoc
        log "#{host.fqdn} : recette `#{r}` non déclarée (apply_recipes:) → sauté."
        Beryl::CLI::FleetJob.report(Beryl::CLI::FleetJob::UPTODATE, "sauté — `#{r}` non déclarée")
        return EXIT_OK
      end
      requests = adhoc
    end
    recipes = resolver.resolve(requests.map(&.name).uniq)

    # Garde vRack : une recette `requires_vrack: true` (ex. pkg-repo-acme, qui
    # joint le builder de paquets sur le vRack) est ÉCARTÉE si le host n'a pas
    # d'IP vRack (ex. han, GAME1). Évite un apply qui échouerait pour rien.
    if host.vrack_ip.nil? && (skipped = recipes.select(&.requires_vrack)).size > 0
      log "écartées (pas de vRack sur #{host.fqdn}) : #{skipped.map(&.name).join(", ")}"
      recipes = recipes.reject(&.requires_vrack)
    end

    # Réconciliation des comptes : phase intégrée (sauf mode ad-hoc),
    # pilotée par `freebsd.users` — TOUJOURS, même sans apply_recipes. La
    # liste users devient source unique : bootstrap crée, apply réconcilie.
    if !adhoc_recipe && (users_recipe = build_users_recipe(host))
      recipes = [users_recipe] + recipes
    end

    if recipes.empty?
      log "aucune recette ni user à réconcilier pour #{host.fqdn}."
      return EXIT_OK
    end

    # Connexion par l'utilisateur sudo (`connect_user` : `user:` explicite,
    # sinon le user sudo-capable, par ordre alphabétique) — le SSH root est
    # coupé sur les hôtes durcis.
    ssh_user = host.connect_user
    log "cible : #{Beryl.format_ssh_target(host)} (user SSH : #{ssh_user})"
    log "recettes (ordre résolu) : #{recipes.map(&.name).join(" → ")}"

    conn = host.connection(ssh_user)
    uname = conn.exec("uname -s", raise_on_error: false).stdout.strip
    # FreeBSD, ou Linux sous systemd (VM confiée par un client) : seules les
    # recettes et primitives qui déclarent `linux` y sont jouées.
    os =
      case uname
      when "FreeBSD" then Beryl::Apply::FREEBSD
      when "Linux"
        if conn.exec("test -d /run/systemd/system", raise_on_error: false).success?
          Beryl::Apply::LINUX
        end
      end
    unless os
      STDERR.puts "beryl : #{host.fqdn} : connexion #{ssh_user}@ impossible, ou système non pris en charge " \
                  "(uname -s = #{uname.inspect} ; FreeBSD ou Linux sous systemd attendu)"
      if pj = host.proxy_jump(ssh_user)
        STDERR.puts "  (accès via le bastion #{pj} → IP vRack #{host.ssh_host} : est-elle montée et joignable ? " \
                    "appliquez d'abord `vrack-interface` seul, validez, PUIS `sshd-vrack-only`.)"
      end
      return EXIT_NO_FREEBSD
    end
    unless os == host.os
      STDERR.puts "beryl : #{host.fqdn} : le host.yml déclare os: #{host.os}, le serveur répond #{uname} — " \
                  "corrigez `os:` avant d'appliquer quoi que ce soit."
      return EXIT_NO_FREEBSD
    end
    if (other = recipes.reject(&.systems.includes?(os))).size > 0
      log "écartées (pas prévues pour #{os}) : #{other.map(&.name).join(", ")}"
      recipes = recipes - other
      if recipes.empty?
        log "aucune recette pour #{os} sur #{host.fqdn}."
        return EXIT_OK
      end
    end

    # Escalade : si on n'est pas root, on vérifie que sudo NOPASSWD marche
    # puis on enrobe le shell pour que les opérations root passent par sudo.
    shell : Beryl::Apply::Shell
    if ssh_user == "root"
      shell = Beryl::Apply::SshShell.new(conn)
    else
      unless conn.exec("sudo -n true", raise_on_error: false).success?
        STDERR.puts "beryl : #{host.fqdn} : #{ssh_user} ne peut pas sudo sans mot de passe " \
                    "(sudo -n échoue). Vérifiez `%wheel NOPASSWD` + l'appartenance à wheel (ou `sudo: true`)."
        return EXIT_SSH_FAILED
      end
      shell = Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(conn))
    end
    vars = {
      "company"  => host.account_name,
      "fqdn"     => host.fqdn,
      "hostname" => host.short_name,
      "domain"   => host.domain_name,
    }
    # IP vRack (déclarée une seule fois via `vrack-interface: { ip }`) → `{{ vrack_ip }}`.
    # Absente si l'hôte n'est pas dans un vRack : une recette qui y fait référence
    # échouera alors explicitement (UnknownVariable), ce qui est le bon comportement.
    if vip = host.vrack_ip
      vars["vrack_ip"] = vip
    end
    # IP publique (IPv4) de l'hôte (champ `ovh.ipv4`, renseigné par
    # `beryl info --refresh`) → `{{ public_ip }}`. Permet aux recettes de
    # binder un service public sans coder l'IP en dur (ex. `listen
    # {{ public_ip }}:443`). Chaque hôte fournit LA sienne. Absente (donc
    # UnknownVariable explicite) si l'IP publique n'est pas connue.
    if pip = host.ovh_ipv4
      vars["public_ip"] = pip
    end
    # IP publique IPv6 (champ `ovh.ipv6`) → `{{ public_ip6 }}`, pour binder un
    # service en dual-stack (ex. `listen [{{ public_ip6 }}]:443`). Absente
    # (UnknownVariable explicite) si l'hôte n'a pas d'IPv6 connue.
    if pip6 = host.ovh_ipv6
      vars["public_ip6"] = pip6
    end
    # Passerelle IPv6 d'OVH (`ovh.ipv6_gateway`) → `{{ public_ip6_gateway }}`
    # (défaut de netif-ipv6). Absente : UnknownVariable explicite.
    if gw6 = host.ovh_ipv6_gateway
      vars["public_ip6_gateway"] = gw6
    end
    # DNS interne du vRack (`Beryl::VrackZone`), lu dans TOUTES les fiches du
    # même vRack : zone, données (`unbound-vrack`), serveurs de la zone et
    # zone inverse (`vrack-resolver`). Absents hors vRack ou sans bastion
    # (UnknownVariable explicite dans une recette qui s'en sert).
    # Réseau du vRack (`vrack.subnet`) → `{{ vrack_subnet }}` : défaut des
    # `allow_from` des recettes (tang-server, mirror-http…), sans recopier le
    # réseau dans chaque recette. Absent : UnknownVariable explicite.
    if subnet = host.vrack_subnet
      vars["vrack_subnet"] = subnet
    end
    if host.vrack_ip && (vname = host.vrack_name)
      peers = Beryl::VrackZone.peers(fleet_hosts(config_root), vname)
      vars["vrack_zone"] = host.vrack_zone
      vars["vrack_local_data"] = Beryl::VrackZone.local_data(peers, host.vrack_zone)
      stubs = Beryl::VrackZone.stub_addrs(peers)
      vars["vrack_stub_addrs"] = stubs unless stubs.empty?
      if rz = Beryl::VrackZone.reverse_zone(host.vrack_subnet)
        vars["vrack_reverse_zone"] = rz
      end
    end
    vars["root_ssh_login"] = root_ssh_login(host)
    vars["os"] = os
    # Dossier de configuration des paquets → `{{ pkg_etc }}` : /usr/local/etc
    # sous FreeBSD (ports), /etc sous Linux (paquets de la distribution). Une
    # recette portable y écrit sans dupliquer ses étapes (monitrc, monit.d…).
    vars["pkg_etc"] = os == Beryl::Apply::LINUX ? "/etc" : "/usr/local/etc"
    # Compte par lequel beryl se connecte : une recette qui restreint l'accès
    # SSH (`sshd-allow-users`) s'en sert pour ne jamais fermer sa propre porte.
    vars["connect_user"] = ssh_user
    context = Beryl::Apply::Context.new(
      protected_keys: connecting_pubkeys(host),
      vars: vars,
      dns: dns_hook(config_root, host),
      os: os,
    )
    recipe_args = recipe_arguments(requests, declared, recipes.map(&.name))
    report = Beryl::Apply::Executor.new(shell, dry_run, context).run(recipes, recipe_args)

    log "apply terminé pour #{host.fqdn}#{dry_run ? " (dry-run)" : ""} — #{report.summary_line}"
    # Tâche de flotte (`--parallel`, no-op sinon) : « mis à jour » si une étape a
    # agi (le canari est validé), « à jour » sinon.
    if report.failed > 0
      Beryl::CLI::FleetJob.report(Beryl::CLI::FleetJob::FAILED, report.summary_line, touched: report.applied > 0)
    elsif report.applied > 0
      Beryl::CLI::FleetJob.report(Beryl::CLI::FleetJob::UPGRADED, report.summary_line, touched: true)
    else
      Beryl::CLI::FleetJob.report(Beryl::CLI::FleetJob::UPTODATE, report.summary_line)
    end
    report.failed > 0 ? EXIT_RECIPE : EXIT_OK
  rescue ex : Beryl::Apply::Resolver::RecipeNotFound | Beryl::Apply::Resolver::Cycle | Beryl::Apply::Recipe::InvalidRecipe | Beryl::Apply::UnknownPrimitive | Beryl::Apply::DuplicatePath | Beryl::Apply::ConflictingRequiredArgs
    STDERR.puts "beryl : #{host.fqdn} : #{ex.message}"
    EXIT_RECIPE
  rescue ex : Beryl::Apply::MissingVariable
    STDERR.puts "beryl : #{host.fqdn} : #{missing_variable_message(ex, host)}"
    EXIT_RECIPE
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : #{host.fqdn} : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : #{host.fqdn} : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  @@fleet_root : Beryl::Config::Root? = nil
  @@fleet_hosts = {} of String => Array(Beryl::Config::ResolvedHost)

  # Toutes les fiches résolues de la config (une résolution par processus,
  # même en apply de flotte), comme `beryl info` : le DNS interne du vRack se
  # calcule sur le parc. Réutilise la config déjà chargée par `run`. Une fiche
  # qui ne se résout pas est ignorée (elle échouera dans son propre apply).
  def self.fleet_hosts(config_root : String) : Array(Beryl::Config::ResolvedHost)
    @@fleet_hosts[config_root] ||= begin
      root = @@fleet_root || Beryl::Config::Root.load(config_root)
      root.all_hosts_by_fqdn.keys.compact_map do |fqdn|
        root.resolve(fqdn)
      rescue
        nil
      end
    end
  end

  # `{{ root_ssh_login }}` (PermitRootLogin, recette sshd-auth-keys-only) : la
  # MÊME règle que le bootstrap — root COUPÉ (`no`), sauf `/home` chiffré
  # (profil C+), où root par clé (`prohibit-password`) est la porte de secours
  # tant que les datasets ne sont pas déverrouillés.
  def self.root_ssh_login(host : Beryl::Config::ResolvedHost) : String
    root_ssh_login(host.boot_zpool)
  rescue
    "no" # pas de pool boot déclaré : rien de chiffré
  end

  def self.root_ssh_login(boot_pool : Beryl::Config::Pool) : String
    boot_pool.system_datasets.any?(&.encrypted) ? "prohibit-password" : "no"
  end

  # Variables fournies par l'hôte → ce qu'il faut renseigner pour les avoir.
  VARIABLE_SOURCES = {
    "public_ip"          => "`ovh.ipv4` (ou `beryl info --refresh`)",
    "public_ip6"         => "`ovh.ipv6`",
    "public_ip6_gateway" => "`ovh.ipv6_gateway` (`beryl info --refresh` la lit dans l'API OVH)",
    "vrack_ip"           => "`vrack-interface: { ip: … }` dans `apply_recipes`",
  }

  # « recette `netif-ipv6` : variable `public_ip6` non définie — renseignez
  # `ovh.ipv6` dans <host.yml> » ; variable de recette inconnue : le message
  # nomme la recette et les variables connues.
  def self.missing_variable_message(ex : Beryl::Apply::MissingVariable, host : Beryl::Config::ResolvedHost) : String
    head = "recette `#{ex.recipe}` : variable `#{ex.variable}` non définie"
    if source = VARIABLE_SOURCES[ex.variable]?
      "#{head} — renseignez #{source} dans #{host.node.source_path}"
    else
      "#{head} — ni paramètre de la recette, ni variable de l'hôte " \
      "(connues : #{ex.known.join(", ")})"
    end
  end

  # Dossier `recipes/` du dépôt central. Lit le bloc `recipes:` du
  # merge (`local_path`, défaut `<config>/recipes`). Le dépôt central
  # est cloné/maintenu hors de beryl (Phase 1) ; les recettes vivent
  # dans son sous-dossier `recipes/`.
  # Recette synthétique de réconciliation des comptes, construite depuis
  # `freebsd.users` : un step `user-sync` par user déclaré. nil si aucun.
  private def self.build_users_recipe(host : Beryl::Config::ResolvedHost) : Beryl::Apply::Recipe?
    freebsd = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?)
    return unless freebsd
    users = freebsd[YAML::Any.new("users")]?.try(&.as_a?)
    return unless users

    steps = [] of Beryl::Apply::Step
    Beryl::Config::Users.list(users).each do |e|
      name_any = YAML::Any.new(e.name)
      # user-sync : tous les champs SAUF `shell` (géré à part : un /chemin par
      # user-shell ci-dessous, une recette par user_shell_recipe_requests).
      params = {} of String => YAML::Any
      e.fields.each { |k, v| params[k.as_s? || k.to_s] = v unless k.as_s? == "shell" }
      params["name"] = name_any
      steps << Beryl::Apply::Step.new(name: "user-sync", params: params)
      # Clé d'identité du user (générée sur le serveur, idempotent).
      steps << Beryl::Apply::Step.new(name: "user-ssh-key", params: {"name" => name_any})
      # `shell: /chemin` → user-shell (idempotent, gère le CHANGEMENT de shell).
      if path = e.shell_path
        steps << Beryl::Apply::Step.new(name: "user-shell",
          params: {"user" => name_any, "shell" => YAML::Any.new(path)})
      end
    end
    return if steps.empty?

    Beryl::Apply::Recipe.new(
      name: "users",
      description: "Réconciliation des comptes (freebsd.users)",
      requires: [] of String,
      parameters: {} of String => YAML::Any,
      arguments: {} of String => YAML::Any,
      steps: steps,
      source_path: "<built-in>",
    )
  end

  # Recettes dérivées du champ `shell` des users quand c'est un NOM DE RECETTE
  # (ex. `shell: oh-my-zsh`) : une requête `<recette>` avec `user: <nom>`. Un
  # `/chemin` n'en produit pas (géré par user-shell dans build_users_recipe).
  private def self.user_shell_recipe_requests(host : Beryl::Config::ResolvedHost) : Array(RecipeRequest)
    freebsd = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?)
    return [] of RecipeRequest unless freebsd
    users = freebsd[YAML::Any.new("users")]?.try(&.as_a?)
    return [] of RecipeRequest unless users
    Beryl::Config::Users.list(users).compact_map do |e|
      if recipe = e.shell_recipe
        RecipeRequest.new(recipe, {"user" => e.name})
      end
    end
  end

  # Chemin de recherche des recettes, par ORDRE DE PRIORITÉ :
  #   1. PRIVÉ société : `<config_root>/<société>/recipes/` (si présent) —
  #      recettes spécifiques à la société, peut SURCHARGER une générique du
  #      même nom. Vit dans le dépôt de config (déjà privé par société).
  #   2. GÉNÉRIQUE public : `<recipes.local_path>/recipes/` (défaut
  #      `<config_root>/recipes/recipes/`) — le set diffusable, sans société.
  # Public : réutilisé par `beryl info --versions/--updates` pour savoir quelles
  # recettes (donc quels paquets) s'appliquent à un host.
  def self.recipes_search_path(config_root : String, host : Beryl::Config::ResolvedHost) : Array(String)
    dirs = [] of String

    if acct = host.account_name
      private_dir = File.join(config_root, acct, "recipes")
      dirs << private_dir if Dir.exists?(private_dir)
    end

    block = host.merged[YAML::Any.new("recipes")]?.try(&.as_h?)
    local_path =
      if block && (lp = block[YAML::Any.new("local_path")]?.try(&.as_s?))
        File.expand_path(lp, home: true)
      else
        File.join(config_root, "recipes")
      end
    dirs << File.join(local_path, "recipes")

    dirs
  end

  # Une recette demandée + ses arguments éventuels (qui surchargent les
  # `parameters` de la recette pour CET hôte).
  record RecipeRequest, name : String, arguments : Hash(String, String)

  # Recettes d'entrée du mode ponctuel (`beryl sync <portée> <recette>`) :
  #   * recette DÉCLARÉE dans `apply_recipes:` → ses jeux d'arguments du
  #     host.yml sont repris (sinon une recette paramétrée par le host,
  #     ex. `zfs-scrub: { scrub_schedule: … }`, repartirait de ses défauts) ;
  #   * tirée par une recette déclarée (`requires:`) → sans argument ;
  #   * non déclarée : appliquée telle quelle sur UN serveur nommé (action
  #     ponctuelle, ex. rotation de clé), mais `nil` (serveur sauté) quand
  #     `restrict` — portée domaine ou société : `beryl sync <société>
  #     nginx-lite` ne doit pas installer nginx là où rien ne le demande.
  def self.adhoc_requests(name : String, declared : Array(RecipeRequest), closure : Array(String), restrict : Bool) : Array(RecipeRequest)?
    own = declared.select { |req| req.name == name }
    return own unless own.empty?
    return [RecipeRequest.new(name, {} of String => String)] if closure.includes?(name) || !restrict
    nil
  end

  # Jeux d'arguments par recette à jouer. Une dépendance tirée par la recette
  # ponctuelle (`requires:`) mais DÉCLARÉE dans `apply_recipes:` reprend ses
  # arguments du host.yml : `beryl sync <portée> periodic-quiet` tire monit,
  # qui sans eux repartait de ses défauts (relais de mail d'un client écrasé
  # par celui de la société, quimeo-twin, 29 oct. 2026).
  def self.recipe_arguments(requests : Array(RecipeRequest), declared : Array(RecipeRequest), resolved : Array(String)) : Hash(String, Array(Hash(String, String)))
    args = {} of String => Array(Hash(String, String))
    requests.each { |req| (args[req.name] ||= [] of Hash(String, String)) << req.arguments }
    resolved.each do |name|
      next if args.has_key?(name)
      own = declared.select { |req| req.name == name }
      args[name] = own.map(&.arguments) unless own.empty?
    end
    args
  end

  # Recettes d'entrée déclarées en config (`apply_recipes:`), cascadées
  # par le merge (société → domaine → host, append + dédup). Chaque entrée
  # est soit un NOM (string), soit une map à CLÉ UNIQUE `{<nom>: {clé:
  # valeur}}` pour passer des arguments — même forme que les steps d'une
  # recette. Ex. cibler un user particulier :
  #
  #   apply_recipes:
  #     - ssh-hardening
  #     - oh-my-zsh: { user: pne }
  private def self.apply_recipes_list(host : Beryl::Config::ResolvedHost) : Array(RecipeRequest)
    any = host.merged[YAML::Any.new("apply_recipes")]?
    return [] of RecipeRequest unless any
    (any.as_a? || [] of YAML::Any).flat_map do |e|
      if name = e.as_s?
        [RecipeRequest.new(name, {} of String => String)]
      elsif (h = e.as_h?) && !h.empty? && (rname = h.first[0].as_s?)
        # Args bruts : chaque clé → liste de valeurs (string → [v], liste
        # → [v1, v2…]). Le produit cartésien donne un jeu d'args par
        # combinaison → fan-out (ex. `user: [deploy, pne]` → 2 jeux).
        raw = {} of String => Array(String)
        argval = h.first[1]
        if argh = argval.as_h?
          argh.each do |k, v|
            kn = k.as_s? || k.to_s
            if vs = v.as_s?
              raw[kn] = [vs]
            elsif va = v.as_a?
              raw[kn] = va.compact_map(&.as_s?)
            end
          end
        elsif va = argval.as_a?
          # Forme positionnelle liste : `- pkg-add: [a, b, c]` → fan-out.
          raw[Beryl::Apply::Recipe::POSITIONAL_ARG] = va.compact_map(&.as_s?)
        elsif vs = argval.as_s?
          # Forme positionnelle scalaire : `- pkg-add: htop`.
          raw[Beryl::Apply::Recipe::POSITIONAL_ARG] = [vs]
        end
        expand_args(raw).map { |combo| RecipeRequest.new(rname, combo) }
      else
        [] of RecipeRequest
      end
    end
  end

  # Produit cartésien des arguments listes → un jeu d'arguments par
  # combinaison. `{}` → `[{}]` (une exécution, jeu vide) ; `{user: [a, b]}`
  # → `[{user: a}, {user: b}]` ; `{u: [a, b], t: [x, y]}` → 4 combinaisons.
  private def self.expand_args(raw : Hash(String, Array(String))) : Array(Hash(String, String))
    combos = [{} of String => String]
    raw.each do |key, values|
      combos = combos.flat_map { |c| values.map { |v| c.merge({key => v}) } }
    end
    combos
  end

  # Clé(s) publique(s) que beryl utilise pour se connecter, dérivée(s)
  # de `host.identity_file` via `ssh-keygen -y`. Alimente le garde-fou
  # de `user-update-keys` (refus de retirer la clé en cours d'usage).
  # Best-effort : si la clé est absente, chiffrée ou illisible, on
  # retourne une liste vide (pas de garde-fou plutôt qu'un plantage).
  private def self.connecting_pubkeys(host : Beryl::Config::ResolvedHost) : Array(String)
    idf = host.identity_file
    return [] of String unless idf && File.exists?(idf)
    buf = IO::Memory.new
    status = Process.run(
      "ssh-keygen",
      ["-y", "-f", idf],
      output: buf,
      error: Process::Redirect::Close,
      input: Process::Redirect::Close,
    )
    return [] of String unless status.success?
    buf.to_s.lines.map(&.strip).reject(&.empty?)
  rescue
    [] of String
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl sync] #{message}"
  end
end

module Beryl::CLI::Apply
  # Pose DNS de la primitive `dns-record` : zone de la société de l'hôte
  # (la plus longue qui contient le nom), son `dns_provider`, les
  # identifiants du coffre déjà appliqués pour l'hôte. Mêmes validations que
  # `beryl dns-record`.
  def self.dns_hook(config_root : String, host : Beryl::Config::ResolvedHost) : Beryl::Apply::DnsHook
    ->(fqdn : String, type : String, target : String, dry_run : Bool) do
      root = Beryl::Config::Root.load(config_root)
      account = root.account?(host.account_name) ||
                raise Beryl::Apply::Primitive::PrimitiveError.new("société inconnue : #{host.account_name}")
      zone = account.domains.values.select { |d| fqdn == d.name || fqdn.ends_with?(".#{d.name}") }.max_by?(&.name.size)
      raise Beryl::Apply::Primitive::PrimitiveError.new("#{fqdn} : aucune zone de #{account.name} ne le contient") if zone.nil?
      provider_name = zone.raw[YAML::Any.new("dns_provider")]?.try(&.as_s?)
      if provider_name.nil? || provider_name.empty?
        raise Beryl::Apply::Primitive::PrimitiveError.new("aucun `dns_provider` déclaré pour #{zone.name}")
      end
      sub = fqdn == zone.name ? "" : fqdn.rchop(".#{zone.name}")
      value = begin
        Beryl::CLI::DnsRecord.normalize_target(type, target)
      rescue ex : ArgumentError
        raise Beryl::Apply::Primitive::PrimitiveError.new(ex.message.to_s)
      end
      line = "#{type} #{fqdn} → #{value} (#{provider_name})"
      if dns_current?(fqdn, type, value)
        {false, "#{line} : déjà en place"}
      elsif dry_run
        {true, "#{line} (dry-run)"}
      else
        provider = Beryl::Providers.find(provider_name)
        unless provider && provider.capable_of?(:dns)
          raise Beryl::Apply::Primitive::PrimitiveError.new("`#{provider_name}` n'est pas un fournisseur DNS")
        end
        dns = provider.as(Beryl::DnsProvider)
        dns.ensure_record(zone.name, type, sub, value)
        dns.refresh_zone(zone.name)
        {true, line}
      end
    end
  end
end

module Beryl::CLI::Apply
  # Le nom répond-il déjà par cette adresse (A, AAAA) ? Lecture par le
  # résolveur du poste : un enregistrement juste n'est ni reposé ni compté
  # comme un changement (sinon les `if_changed` de la recette se
  # déclencheraient à chaque apply). CNAME : toujours posé (pas de lecture).
  def self.dns_current?(fqdn : String, type : String, value : String) : Bool
    family = case type
             when "A"    then Socket::Family::INET
             when "AAAA" then Socket::Family::INET6
             else             return false
             end
    expected = Socket::IPAddress.new(value, 0).address
    Socket::Addrinfo.resolve(fqdn, 0, family: family, type: Socket::Type::STREAM).any? do |info|
      info.ip_address.address == expected
    end
  rescue Socket::Error | ArgumentError
    false
  end
end
