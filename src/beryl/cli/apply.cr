require "option_parser"
require "./option_errors"
require "../config"
require "../apply"
require "ssh"
require "./account_utils"
require "./dns_record"

# Sous-commande `beryl apply <host>` : applique sur le serveur FreeBSD
# (déjà bootstrappé) les *recettes* déclarées dans le dossier
# d'orchestration du host.
#
# Architecture à 2 niveaux (cf. `apply-recipes-architecture.adoc`) :
#   * recettes YAML reliées par `requires:` (résolution récursive,
#     tri topologique, détection de cycle) ;
#   * primitives Crystal natives idempotentes (`pkg-install`, …).
#
# Dossiers lus :
#   * orchestration du host : `<config>/<société>/<domaine>/<host>/`
#     (recettes explicitement demandées + overrides locaux) ;
#   * dépôt central : `<recipes.local_path>/recipes/`
#     (défaut `<config>/recipes/recipes/`).
#
# Priorité de résolution : dossier host > dépôt central. Idempotence :
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
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl apply <host|domaine|société> [recette] [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : portée non précisée. USAGE : beryl apply <host|domaine|société> [recette]"
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
    # Portée : host, domaine OU société (comme rotate-key). `apply example.net`
    # → tous les hosts du domaine ; `apply acme` → toute la société.
    hosts = resolve_hosts(root, host_name, account_hint, domain_hint)
    if hosts.empty?
      STDERR.puts "beryl : portée inconnue : #{raw} (ni host, ni domaine, ni société). " \
                  "Sociétés configurées : #{root.accounts.keys.sort.join(", ")}"
      return EXIT_USAGE
    end
    log "portée #{raw} → #{hosts.size} hosts : #{hosts.map(&.short_name).join(", ")}" if hosts.size > 1

    # `installed: false` (pas encore bootstrappé) : sauté sur une portée
    # (société, domaine), comme update/upgrade/os-upgrade ; refusé s'il est
    # nommé explicitement — au lieu d'un échec de connexion SSH.
    single_host = host_scope?(root, host_name, account_hint, domain_hint)
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

    # Une erreur sur un host ne doit pas avorter le reste de la flotte :
    # apply_one capture ses propres erreurs et renvoie un code EXIT.
    worst = EXIT_OK
    # Recette ponctuelle sur un domaine ou une société : seuls les serveurs
    # qui la déclarent l'appliquent (cf. adhoc_requests).
    hosts.each do |host|
      rc = apply_one(config_root, host, adhoc_recipe, dry_run, restrict_adhoc: !single_host)
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

    [] of Beryl::Config::ResolvedHost
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

    # Apply est FreeBSD-only dans ce build (ADR-014 prévoit Os::Debian…).
    unless host.os == "freebsd"
      STDERR.puts "beryl : #{host.fqdn} ignoré (apply = os: freebsd uniquement, os : #{host.os})."
      return EXIT_USAGE
    end
    # Un host virtuel (pas de `.host.yml`) n'a pas de connexion.
    if host.virtual
      log "#{host.fqdn} : host virtuel, rien à appliquer."
      return EXIT_OK
    end
    # Garde-fou : un host `protected: true` refuse un apply RÉEL (écriture). Le
    # dry-run (plan, lecture seule) reste permis. Pour les serveurs sensibles
    # (cible de pentest, gelés). Générique — aucun nom d'hôte en dur (libre).
    if !dry_run && host.protected?
      log "#{host.fqdn} : protégé (protected: true) → apply RÉEL refusé (le plan est le défaut, sans --apply)."
      return EXIT_OK
    end

    search_path = recipes_search_path(config_root, host)

    # Recettes d'ENTRÉE : la liste `apply_recipes:` cascadée du merge (état
    # désiré, versionné) + recettes-shell dérivées des users (ex. `shell:
    # oh-my-zsh` → recette oh-my-zsh avec user: <nom>) ; ou, en mode
    # ponctuel, la seule recette nommée en argument.
    declared = apply_recipes_list(host) + user_shell_recipe_requests(host)
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
    unless uname == "FreeBSD"
      STDERR.puts "beryl : #{host.fqdn} : connexion #{ssh_user}@ impossible ou pas FreeBSD (uname -s = #{uname.inspect})"
      if pj = host.proxy_jump(ssh_user)
        STDERR.puts "  (accès via le bastion #{pj} → IP vRack #{host.ssh_host} : est-elle montée et joignable ? " \
                    "appliquez d'abord `vrack-interface` seul, validez, PUIS `sshd-vrack-only`.)"
      end
      return EXIT_NO_FREEBSD
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
    vars["root_ssh_login"] = root_ssh_login(host)
    context = Beryl::Apply::Context.new(
      protected_keys: connecting_pubkeys(host),
      vars: vars,
      dns: dns_hook(config_root, host),
    )
    recipe_args = {} of String => Array(Hash(String, String))
    requests.each { |req| (recipe_args[req.name] ||= [] of Hash(String, String)) << req.arguments }
    report = Beryl::Apply::Executor.new(shell, dry_run, context).run(recipes, recipe_args)

    log "apply terminé pour #{host.fqdn}#{dry_run ? " (dry-run)" : ""} — #{report.summary_line}"
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

  # Recettes d'entrée du mode ponctuel (`beryl apply <portée> <recette>`) :
  #   * recette DÉCLARÉE dans `apply_recipes:` → ses jeux d'arguments du
  #     host.yml sont repris (sinon une recette paramétrée par le host,
  #     ex. `zfs-scrub: { scrub_schedule: … }`, repartirait de ses défauts) ;
  #   * tirée par une recette déclarée (`requires:`) → sans argument ;
  #   * non déclarée : appliquée telle quelle sur UN serveur nommé (action
  #     ponctuelle, ex. rotation de clé), mais `nil` (serveur sauté) quand
  #     `restrict` — portée domaine ou société : `beryl apply <société>
  #     nginx-lite` ne doit pas installer nginx là où rien ne le demande.
  def self.adhoc_requests(name : String, declared : Array(RecipeRequest), closure : Array(String), restrict : Bool) : Array(RecipeRequest)?
    own = declared.select { |req| req.name == name }
    return own unless own.empty?
    return [RecipeRequest.new(name, {} of String => String)] if closure.includes?(name) || !restrict
    nil
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
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl apply] #{message}"
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
      if dry_run
        "#{line} (dry-run)"
      else
        provider = Beryl::Providers.find(provider_name)
        unless provider && provider.capable_of?(:dns)
          raise Beryl::Apply::Primitive::PrimitiveError.new("`#{provider_name}` n'est pas un fournisseur DNS")
        end
        dns = provider.as(Beryl::DnsProvider)
        dns.ensure_record(zone.name, type, sub, value)
        dns.refresh_zone(zone.name)
        line
      end
    end
  end
end
