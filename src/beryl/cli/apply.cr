require "option_parser"
require "../config"
require "../apply"
require "ssh"
require "./account_utils"

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
# chaque primitive lit l'état réel via SSH avant d'agir. `--dry-run`
# (alias `--check`) calcule sans rien modifier.
module Beryl::CLI::Apply
  EXIT_OK         =  0
  EXIT_USAGE      =  1
  EXIT_UNEXPECTED =  3
  EXIT_SSH_FAILED =  4
  EXIT_NO_FREEBSD = 10
  EXIT_RECIPE     = 11

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = false
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl apply <host|domaine|société> [recette] [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-n", "--dry-run", "Affiche ce qui changerait sans l'appliquer") { dry_run = true }
      p.on("--check", "Synonyme de --dry-run (lecture seule)") { dry_run = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

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
    # Portée : host, domaine OU société (comme rotate-key). `apply quimeo.net`
    # → tous les hosts du domaine ; `apply quimeo` → toute la société.
    hosts = resolve_hosts(root, host_name, account_hint, domain_hint)
    if hosts.empty?
      STDERR.puts "beryl : portée inconnue : #{raw} (ni host, ni domaine, ni société). " \
                  "Sociétés configurées : #{root.accounts.keys.sort.join(", ")}"
      return EXIT_USAGE
    end
    log "portée #{raw} → #{hosts.size} hosts : #{hosts.map(&.short_name).join(", ")}" if hosts.size > 1

    # Une erreur sur un host ne doit pas avorter le reste de la flotte :
    # apply_one capture ses propres erreurs et renvoie un code EXIT.
    worst = EXIT_OK
    hosts.each do |host|
      rc = apply_one(config_root, host, adhoc_recipe, dry_run)
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
      begin
        root.resolve(hn, account_hint: account.name, domain_hint: domain.name)
      rescue
        nil
      end
    end
  end

  # Applique les recettes à UN host. Retourne un code EXIT. Capture ses
  # erreurs (recette, SSH…) pour ne pas avorter une boucle de flotte.
  private def self.apply_one(config_root : String, host : Beryl::Config::ResolvedHost, adhoc_recipe : String?, dry_run : Bool) : Int32
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

    central_dir = central_recipes_dir(config_root, host)

    # Recettes d'ENTRÉE : recette nommée en argument (one-off), sinon la
    # liste `apply_recipes:` cascadée du merge (état désiré, versionné).
    requests =
      if r = adhoc_recipe
        [RecipeRequest.new(r, {} of String => String)]
      else
        # apply_recipes: explicites + recettes-shell dérivées des users
        # (ex. `shell: oh-my-zsh` → recette oh-my-zsh avec user: <nom>).
        apply_recipes_list(host) + user_shell_recipe_requests(host)
      end
    resolver = Beryl::Apply::Resolver.new(central_dir)
    recipes = resolver.resolve(requests.map(&.name).uniq)

    # Garde vRack : une recette `requires_vrack: true` (ex. pkg-repo-quimeo, qui
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

    # Connexion comme le PREMIER user sudo-capable de freebsd.users (le
    # SSH root est coupé sur les hôtes durcis) ; à défaut host.user.
    ssh_user = sudo_user(host) || host.user
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
    context = Beryl::Apply::Context.new(
      protected_keys: connecting_pubkeys(host),
      vars: vars,
    )
    recipe_args = {} of String => Array(Hash(String, String))
    requests.each { |req| (recipe_args[req.name] ||= [] of Hash(String, String)) << req.arguments }
    report = Beryl::Apply::Executor.new(shell, dry_run, context).run(recipes, recipe_args)

    log "apply terminé pour #{host.fqdn}#{dry_run ? " (dry-run)" : ""} — #{report.summary_line}"
    report.failed > 0 ? EXIT_RECIPE : EXIT_OK
  rescue ex : Beryl::Apply::Resolver::RecipeNotFound | Beryl::Apply::Resolver::Cycle | Beryl::Apply::Recipe::InvalidRecipe | Beryl::Apply::UnknownPrimitive
    STDERR.puts "beryl : #{host.fqdn} : #{ex.message}"
    EXIT_RECIPE
  rescue ex : SSH::CommandFailed
    STDERR.puts "beryl : #{host.fqdn} : #{ex.message}"
    EXIT_SSH_FAILED
  rescue ex
    STDERR.puts "beryl : #{host.fqdn} : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Dossier `recipes/` du dépôt central. Lit le bloc `recipes:` du
  # merge (`local_path`, défaut `<config>/recipes`). Le dépôt central
  # est cloné/maintenu hors de beryl (Phase 1) ; les recettes vivent
  # dans son sous-dossier `recipes/`.
  # Premier user sudo-capable de `freebsd.users` : `sudo: true` explicite
  # prime, sinon (champ absent) on déduit de l'appartenance au groupe
  # `wheel`. nil si aucun → apply retombe sur host.user (root).
  private def self.sudo_user(host : Beryl::Config::ResolvedHost) : String?
    freebsd = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?)
    return nil unless freebsd
    users = freebsd[YAML::Any.new("users")]?.try(&.as_a?)
    return nil unless users

    Beryl::Config::Users.list(users).each do |e|
      can =
        if flag = e.fields[YAML::Any.new("sudo")]?
          flag.as_bool? == true
        else
          # `secondary_groups` (canonique) OU alias `groups` — même tolérance
          # que user-sync, sinon le user de connexion diffère.
          {"secondary_groups", "groups"}.any? do |key|
            e.fields[YAML::Any.new(key)]?.try(&.as_a?).try(&.any? { |g| g.as_s? == "wheel" }) || false
          end
        end
      return e.name if can
    end
    nil
  end

  # Recette synthétique de réconciliation des comptes, construite depuis
  # `freebsd.users` : un step `user-sync` par user déclaré. nil si aucun.
  private def self.build_users_recipe(host : Beryl::Config::ResolvedHost) : Beryl::Apply::Recipe?
    freebsd = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?)
    return nil unless freebsd
    users = freebsd[YAML::Any.new("users")]?.try(&.as_a?)
    return nil unless users

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
    return nil if steps.empty?

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

  private def self.central_recipes_dir(config_root : String, host : Beryl::Config::ResolvedHost) : String
    block = host.merged[YAML::Any.new("recipes")]?.try(&.as_h?)
    local_path =
      if block && (lp = block[YAML::Any.new("local_path")]?.try(&.as_s?))
        File.expand_path(lp, home: true)
      else
        File.join(config_root, "recipes")
      end
    File.join(local_path, "recipes")
  end

  # Une recette demandée + ses arguments éventuels (qui surchargent les
  # `parameters` de la recette pour CET hôte).
  record RecipeRequest, name : String, arguments : Hash(String, String)

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
