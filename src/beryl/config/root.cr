require "yaml"
require "./users"

module Beryl::Config
  # Point d'entrée de la configuration beryl (ADR-014).
  #
  # Regroupe :
  #   - le socle `_default.yml` (Hash brut, commun à toutes sociétés)
  #   - les *sociétés* chargées (`accounts : Hash<String, Account>`),
  #     chacune contenant ses domaines
  #   - `.env.yml` pour les credentials indexés `[account][provider]`
  #
  # Les opérations habituelles (résolution d'un host, obtention de la
  # config mergée) passent par des méthodes de cette classe.
  class Root
    # Racine de config par défaut (dynamique : honore
    # `$XDG_CONFIG_HOME` si défini au runtime, sinon
    # `~/.config/beryl/`). Voir `Beryl::Xdg.config_dir`.
    def self.default_path : String
      Beryl::Xdg.config_dir
    end

    getter path : String
    getter defaults : Hash(YAML::Any, YAML::Any)
    getter accounts : Hash(String, Account)
    getter env_file : EnvFile
    getter ssh_dir : String

    def initialize(@path, @defaults, @accounts, @env_file, @ssh_dir = DEFAULT_SSH_DIR)
    end

    # Charge une arborescence complète depuis le disque. `ssh_dir`
    # est le dossier où chercher les clés SSH référencées par nom
    # (ex. `philippe.example.com.pub` → `<ssh_dir>/philippe.example.com.pub`).
    # Paramétrable pour les tests qui utilisent des fixtures.
    def self.load(path : String? = nil, ssh_dir : String = DEFAULT_SSH_DIR) : Root
      path ||= default_path
      expanded = File.expand_path(path, home: true)
      result = Loader.load(expanded)
      Root.new(
        path: expanded,
        defaults: result[:defaults],
        accounts: result[:accounts],
        env_file: result[:env_file],
        ssh_dir: ssh_dir,
      )
    end

    # Liste des noms de sociétés configurées (triée).
    def account_names : Array(String)
      @accounts.keys.sort
    end

    # Retourne une société ou nil.
    def account?(name : String) : Account?
      @accounts[name]?
    end

    # Toutes les sociétés qui ont un domaine de ce nom. Rare qu'il y
    # en ait plusieurs, mais possible (ex: une société acme et une
    # société cliente ACME possèdent toutes deux `example.com`).
    def accounts_with_domain(domain_name : String) : Array(Account)
      @accounts.values.select { |a| a.domain?(domain_name) }
    end

    # Tous les hosts de toutes les sociétés, par FQDN.
    # Pratique pour `beryl list-hosts` et pour les recherches globales.
    def all_hosts_by_fqdn : Hash(String, NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode))
      result = {} of String => NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode)
      @accounts.each_value do |account|
        account.domains.each_value do |domain|
          domain.direct_hosts.each do |name, node|
            fqdn = "#{name}.#{domain.name}"
            result[fqdn] = {account: account, domain: domain, group: nil.as(Group?), node: node}
          end
          domain.groups.each_value do |group|
            group.hosts.each do |name, node|
              fqdn = "#{name}.#{domain.name}"
              result[fqdn] = {account: account, domain: domain, group: group.as(Group?), node: node}
            end
          end
        end
      end
      result
    end

    # Résout un nom CLI vers un host effectif mergé.
    #
    # Règles (premier match gagne) :
    #
    #   1. `--account=A` + `--domain=D` : cherche dans A/D directement
    #      (host du fichier si présent, sinon virtuel).
    #   2. `--domain=D` seul : cherche D dans toutes les sociétés.
    #      Lève `AmbiguousHost` si plusieurs sociétés ont le domaine
    #      et que le host n'est pas unique parmi elles.
    #   3. Suffix match : `rails01.example.net` — cherche un domaine
    #      `example.net` dans toutes les sociétés. Si plusieurs sociétés
    #      l'ont ET que le host existe dans une seule → utilisé.
    #   4. Recherche nom court + provider-name dans tous les hosts de
    #      toutes les sociétés. Unique → utilisé ; multi → ambigu.
    #   5. Sinon → `HostNotFound`.
    #
    # Résultat : un `ResolvedHost` (host effectif + société + domaine + groupe).
    def resolve(name : String, account_hint : String? = nil, domain_hint : String? = nil) : ResolvedHost
      # 1 : account + domain explicites
      if account_hint && domain_hint
        account = @accounts[account_hint]? || raise UnknownAccount.new(
          "société inconnue : #{account_hint}. Connues : #{account_names.join(", ")}"
        )
        domain = account.domain?(domain_hint) || raise UnknownDomain.new(
          "domaine inconnu dans #{account_hint} : #{domain_hint}. " \
          "Domaines de #{account_hint} : #{account.domain_names.join(", ")}"
        )
        short = short_name_in_domain(name, domain)
        if node_info = find_host_in_domain(domain, short)
          return build_resolved(account, domain, node_info[:group], node_info[:node])
        end
        return virtual_resolved(account, domain, short)
      end

      # 1b : account_hint seul (sans domain) — cas typique de la
      # forme path-like `acme/loulou` ou `acme/ns3156789.ip-...`.
      if account_hint
        account = @accounts[account_hint]? || raise UnknownAccount.new(
          "société inconnue : #{account_hint}. Connues : #{account_names.join(", ")}"
        )
        # Cherche le host dans tous les domaines de l'account.
        account.domains.each_value do |d|
          short = short_name_in_domain(name, d)
          if info = find_host_in_domain(d, short)
            return build_resolved(account, d, info[:group], info[:node])
          end
        end
        # Pas trouvé : host virtuel. Si l'account a un seul domaine,
        # on crée le virtual dedans directement. Sinon on ne sait
        # pas lequel choisir → on lève AmbiguousHost.
        if account.domains.size == 1
          d = account.domains.values.first
          short = short_name_in_domain(name, d)
          return virtual_resolved(account, d, short)
        end
        raise AmbiguousHost.new(
          "host `#{name}` introuvable dans #{account_hint}, et plusieurs " \
          "domaines existent (#{account.domain_names.join(", ")}). " \
          "Précisez --domain=<nom> ou utilisez " \
          "`#{account_hint}/<domaine>/#{name}`.",
          [] of NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode),
        )
      end

      # 2 : domain seul
      if domain_hint
        accounts_with = accounts_with_domain(domain_hint)
        raise UnknownDomain.new(
          "domaine inconnu : #{domain_hint}. " \
          "Aucune société ne l'héberge."
        ) if accounts_with.empty?
        if accounts_with.size == 1
          account = accounts_with.first
          domain = account.domain?(domain_hint).not_nil!
          short = short_name_in_domain(name, domain)
          if node_info = find_host_in_domain(domain, short)
            return build_resolved(account, domain, node_info[:group], node_info[:node])
          end
          return virtual_resolved(account, domain, short)
        end
        # Plusieurs sociétés ont ce domaine : si le host existe dans
        # une seule, on prend celui-là. Sinon ambigu.
        matches = [] of NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode)
        accounts_with.each do |a|
          d = a.domain?(domain_hint).not_nil!
          short = short_name_in_domain(name, d)
          if info = find_host_in_domain(d, short)
            matches << {account: a, domain: d, group: info[:group], node: info[:node]}
          end
        end
        case matches.size
        when 1
          m = matches.first
          return build_resolved(m[:account], m[:domain], m[:group], m[:node])
        when 0
          # Aucun host trouvé : virtual dans la première société qui a le domaine ?
          # Non, ambigu aussi — on oblige --account.
          raise AmbiguousHost.new(
            "domaine `#{domain_hint}` présent dans plusieurs sociétés : " \
            "#{accounts_with.map(&.name).join(", ")}. Précisez --account=<nom>.",
            [] of NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode),
          )
        else
          raise AmbiguousHost.new(
            "host `#{name}` dans plusieurs sociétés : " \
            "#{matches.map(&.[:account].name).join(", ")}. Précisez --account=<nom>.",
            matches,
          )
        end
      end

      # 3 : suffix match sur un domaine connu (toutes sociétés)
      if (suffix_match = match_domain_suffix(name))
        account, domain, short = suffix_match
        if node_info = find_host_in_domain(domain, short)
          return build_resolved(account, domain, node_info[:group], node_info[:node])
        end
        return virtual_resolved(account, domain, short)
      end

      # 4 : recherche globale (nom de fichier + provider-names)
      matches = search_all_accounts(name)
      case matches.size
      when 0
        raise HostNotFound.new(
          "hôte inconnu : #{name}. Passez --domain=<nom> " \
          "(sociétés configurées : #{account_names.join(", ")})"
        )
      when 1
        m = matches.first
        build_resolved(m[:account], m[:domain], m[:group], m[:node])
      else
        raise AmbiguousHost.new(
          "nom `#{name}` présent dans plusieurs sociétés : " \
          "#{matches.map(&.[:account].name).join(", ")}. " \
          "Précisez --account=<nom> et/ou --domain=<nom>.",
          matches,
        )
      end
    end

    # Extrait le nom court d'un host à partir d'un nom CLI qui peut
    # être FQDN ou court. `rails01.example.net` dans le domaine
    # `example.net` → `rails01`.
    private def short_name_in_domain(name : String, domain : Domain) : String
      suffix = ".#{domain.name}"
      name.ends_with?(suffix) ? name[0...(name.size - suffix.size)] : name
    end

    # Si le nom se termine par `.<domaine>` pour l'un des domaines
    # configurés (toutes sociétés confondues), retourne
    # `{account, domain, nom_court}`. Si plusieurs sociétés partagent
    # le même domaine (rare), prend la première par ordre alphabétique.
    private def match_domain_suffix(name : String) : {Account, Domain, String}?
      @accounts.keys.sort.each do |account_name|
        account = @accounts[account_name]
        account.domains.each_value do |domain|
          suffix = ".#{domain.name}"
          if name.ends_with?(suffix)
            return {account, domain, name[0...(name.size - suffix.size)]}
          end
        end
      end
      nil
    end

    # Cherche `short_name` comme nom de host dans un domaine (directs
    # ou dans un groupe).
    private def find_host_in_domain(domain : Domain, short_name : String) : NamedTuple(group: Group?, node: HostNode)?
      if direct = domain.direct_hosts[short_name]?
        return {group: nil.as(Group?), node: direct}
      end
      domain.groups.each_value do |group|
        if h = group.hosts[short_name]?
          return {group: group.as(Group?), node: h}
        end
      end
      nil
    end

    # Cherche dans toutes les sociétés un host par nom de fichier ET
    # par valeur `provider.service_name` / `scaleway.server_id` / `id`.
    private def search_all_accounts(name : String) : Array(NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode))
      matches = [] of NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode)
      @accounts.each_value do |account|
        account.domains.each_value do |domain|
          domain.direct_hosts.each do |host_name, node|
            matches << {account: account, domain: domain, group: nil.as(Group?), node: node} if host_matches?(host_name, node, name)
          end
          domain.groups.each_value do |group|
            group.hosts.each do |host_name, node|
              matches << {account: account, domain: domain, group: group.as(Group?), node: node} if host_matches?(host_name, node, name)
            end
          end
        end
      end
      matches
    end

    # Vrai si le nom de host ou l'une des valeurs `provider-name`
    # déclarées dans le YAML correspond au nom cherché.
    private def host_matches?(host_name : String, node : HostNode, search : String) : Bool
      return true if host_name == search
      %w[ovh scaleway hetzner latitude cherry phoenixnap vultr leaseweb].each do |p|
        p_block = node.raw[YAML::Any.new(p)]?.try(&.as_h?)
        next unless p_block
        {"service_name", "server_id", "id"}.each do |field|
          value = p_block[YAML::Any.new(field)]?.try(&.as_s?)
          return true if value == search
        end
      end
      false
    end

    private def build_resolved(account : Account, domain : Domain, group : Group?, node : HostNode) : ResolvedHost
      merged = Merger.merge(@defaults, account.metadata, domain, group, node, ssh_dir: @ssh_dir)
      ResolvedHost.new(
        short_name: node.name,
        account: account,
        domain: domain,
        group: group,
        node: node,
        merged: merged,
        env_file: @env_file,
      )
    end

    # Construit un host virtuel (pas de fichier host). Utilisé pour
    # `beryl rescue` sur un serveur neuf : on connaît la société, le
    # domaine et le nom mais il n'y a pas encore de YAML dédié.
    private def virtual_resolved(account : Account, domain : Domain, short_name : String) : ResolvedHost
      virtual_node = HostNode.new(
        name: short_name,
        raw: {} of YAML::Any => YAML::Any,
        source_path: "<virtual>",
      )
      merged = Merger.merge(@defaults, account.metadata, domain, nil, virtual_node, ssh_dir: @ssh_dir)
      ResolvedHost.new(
        short_name: short_name,
        account: account,
        domain: domain,
        group: nil,
        node: virtual_node,
        merged: merged,
        env_file: @env_file,
        virtual: true,
      )
    end

    # ---------- Exceptions de résolution ----------

    class UnknownAccount < Exception
    end

    class UnknownDomain < Exception
    end

    class HostNotFound < Exception
    end

    class AmbiguousHost < Exception
      getter candidates : Array(NamedTuple(account: Account, domain: Domain, group: Group?, node: HostNode))

      def initialize(message : String, @candidates)
        super(message)
      end
    end
  end

  # Host résolu : résultat d'une recherche dans la `Root`. Porte le
  # contexte (société, domaine, groupe éventuel) + la config effective
  # mergée + un accès direct aux credentials via `credentials_for`.
  class ResolvedHost
    getter short_name : String # "rails01"
    getter account : Account
    getter domain : Domain
    getter group : Group?
    getter node : HostNode
    getter merged : Hash(YAML::Any, YAML::Any)
    getter env_file : EnvFile
    getter virtual : Bool # true si pas de fichier

    def initialize(
      @short_name : String,
      @account : Account,
      @domain : Domain,
      @group : Group?,
      @node : HostNode,
      @merged : Hash(YAML::Any, YAML::Any),
      @env_file : EnvFile,
      @virtual : Bool = false,
    )
      @ssh_key_warned = false
    end

    # FQDN reconstitué : `<short_name>.<domaine>`. Le groupe
    # n'apparaît pas (règle figée : pas de `rails01.web.example.net`).
    #
    # Exception : si `short_name` contient déjà un point, c'est un
    # FQDN externe (nom hébergeur type `ns3156789.ip-51-83-6.eu` ou
    # alias DNS qui ne relève pas du domaine acme). On le garde
    # tel quel — sans quoi on fabriquerait un
    # `ns3156789.ip-51-83-6.eu.example.net` qui ne résout nulle part.
    def fqdn : String
      return @short_name if @short_name.includes?('.')
      "#{@short_name}.#{@domain.name}"
    end

    def group_name : String?
      @group.try(&.name)
    end

    def domain_name : String
      @domain.name
    end

    def account_name : String
      @account.name
    end

    # Credentials du (account, provider) pour ce host. Utilisé par
    # les CLI qui font des appels API (rescue, bootstrap, scan…).
    def credentials_for(provider : String) : Hash(String, String)
      @env_file.for_account_provider(@account.name, provider)
    end

    # Injecte les credentials d'un provider dans `ENV` (pour les
    # shards OVH/Scaleway qui lisent leurs variables depuis ENV).
    # Retourne le nombre de variables posées.
    def apply_credentials_to_env!(provider : String, overwrite : Bool = true) : Int32
      @env_file.apply_to_env(@account.name, provider, overwrite: overwrite)
    end

    # Injecte TOUTES les credentials de la société dans `ENV` (tous
    # fournisseurs confondus). Utilisé par les CLI qui peuvent
    # potentiellement appeler plusieurs APIs (ex: scan --dns qui
    # touche au DNS provider + compute provider).
    def apply_all_credentials_to_env! : Int32
      @env_file.apply_all_to_env(@account.name, overwrite: true)
    end

    # Provider déclaré dans le merged (ex: "ovh", "scaleway"). Dans
    # le vocabulaire ADR-014 c'est le *compute_provider* (où le
    # serveur est hébergé), distinct du `dns_provider` du domaine.
    def provider : String?
      @merged[YAML::Any.new("provider")]?.try(&.as_s?)
    end

    # DNS provider du domaine (qui gère la zone). Peut différer du
    # `provider` (hébergeur) — cas typique : zone chez Gandi, serveurs
    # chez OVH.
    def dns_provider : String?
      @merged[YAML::Any.new("dns_provider")]?.try(&.as_s?)
    end

    # Noms des blocs providers présents dans le merged. Utile pour
    # les messages d'erreur quand `provider:` n'est pas déclaré.
    def present_provider_blocks : Array(String)
      known = %w[ovh scaleway hetzner latitude cherry phoenixnap vultr leaseweb gandi cloudflare]
      known.select { |name| @merged.has_key?(YAML::Any.new(name)) }
    end

    # Accès générique à un champ du bloc `<provider>:` (service_name,
    # server_id, zone, etc.).
    def provider_field(provider_name : String, field : String) : String?
      block = @merged[YAML::Any.new(provider_name)]?.try(&.as_h?)
      return nil unless block
      block[YAML::Any.new(field)]?.try(&.as_s?)
    end

    # Service name OVH. Pour un host déclaré, lu dans `ovh.service_name`.
    # Pour un host virtuel (serveur neuf) dont `provider: ovh` est
    # explicitement résolu ET dont le short_name contient un point
    # (FQDN hébergeur), on fallback sur `short_name`.
    def ovh_service_name : String?
      explicit = provider_field("ovh", "service_name")
      return explicit if explicit
      if @virtual && provider == "ovh" && @short_name.includes?('.')
        return @short_name
      end
      nil
    end

    def ovh_ssh_key_name : String?
      provider_field("ovh", "ssh_key_name")
    end

    # Gamme commerciale OVH (ex. "Advance-2"), écrite par `beryl scan` à
    # côté de `service_name`. nil si jamais scanné (ou non-OVH).
    def ovh_commercial_name : String?
      provider_field("ovh", "commercial_name")
    end

    # Prix de renouvellement mensuel (HT) écrit par `beryl info --refresh`
    # (`ovh.price_eur`), ou posé à la main. Renvoie une CHAÎNE (ex. "89.99").
    # Tolère le NOMBRE comme la chaîne : `price_eur: 89.99` est lu par YAML
    # comme un float → `as_s?` renverrait nil (bug : prix absent du .adoc).
    def ovh_price : String?
      v = @merged[YAML::Any.new("ovh")]?.try(&.as_h?).try(&.[YAML::Any.new("price_eur")]?)
      return nil unless v
      v.as_s? || v.as_f?.try { |f| "%.2f" % f } || v.as_i?.try(&.to_s)
    end

    # Baie (rack) OVH du serveur, écrite par `beryl info --refresh` (`ovh.rack`).
    # Sert à repérer les serveurs CO-LOCALISÉS (panne baie = perte simultanée).
    def ovh_rack : String?
      provider_field("ovh", "rack")
    end

    # IPv4 / IPv6 publiques écrites par `beryl info --refresh` (`ovh.ipv4`/`ovh.ipv6`).
    def ovh_ipv4 : String?
      provider_field("ovh", "ipv4")
    end

    def ovh_ipv6 : String?
      provider_field("ovh", "ipv6")
    end

    # Caractéristiques matérielles écrites par `beryl scan` (bloc top-level
    # `hardware:`). nil si jamais scanné. Source de `beryl info` (hors-ligne).
    def hardware : Beryl::HardwareSpec?
      h = @merged[YAML::Any.new("hardware")]?.try(&.as_h?)
      return nil unless h
      get = ->(k : String) { h[YAML::Any.new(k)]? }
      disks = get.call("disks").try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      Beryl::HardwareSpec.new(
        cpu: get.call("cpu").try(&.as_s?) || "(inconnu)",
        cores: get.call("cores").try(&.as_i?) || 0,
        threads: get.call("threads").try(&.as_i?) || 0,
        ram_gb: get.call("ram_gb").try(&.as_i?) || 0,
        disks: disks,
        raid: get.call("raid").try(&.as_s?),
      )
    end

    def scaleway_server_id : String?
      provider_field("scaleway", "server_id")
    end

    # ID entier Dedibox (stocké sous `dedibox.server_id` dans le YAML).
    # Retourne la valeur sous forme de String pour homogénéité avec
    # les autres providers ; le parsing Int32 se fait côté
    # `Beryl::Providers::Dedibox#request_rescue`.
    def dedibox_server_id : String?
      explicit = provider_field("dedibox", "server_id")
      return explicit if explicit
      # Tolère aussi un champ entier natif (YAML `server_id: 186260`).
      block = @merged[YAML::Any.new("dedibox")]?.try(&.as_h?)
      return nil unless block
      int_val = block[YAML::Any.new("server_id")]?.try(&.as_i?)
      int_val.try(&.to_s)
    end

    def scaleway_zone : String?
      provider_field("scaleway", "zone")
    end

    def port : Int32
      @merged[YAML::Any.new("port")]?.try(&.as_i?) || 22
    end

    def user : String
      @merged[YAML::Any.new("user")]?.try(&.as_s?) || "root"
    end

    # `protected: true` dans le host.yml → beryl REFUSE les opérations qui
    # MODIFIENT le serveur (ex. `upgrade --apply`). Le dry-run et la lecture
    # restent autorisés. Pour les hosts sensibles (cible de pentest, serveur
    # gelé…). Générique — aucun nom d'hôte en dur dans le code.
    def protected? : Bool
      @merged[YAML::Any.new("protected")]?.try(&.as_bool?) || false
    end

    # Le host a-t-il du chiffrement ZFS (pools data chiffrés OU datasets zroot
    # chiffrés du profil Option I) ? Sert à savoir s'il faut être déverrouillé
    # avant une opération qui ÉCRIT (pkg upgrade…).
    def encrypted? : Bool
      data_zpools.any?(&.encrypted?) || !zpools.find(&.boot).try(&.encryption_root).nil?
    end

    # Datasets/pools dont la clé doit être chargée pour que les points de
    # montage chiffrés soient montés (pour vérifier le verrou via `keystatus`) :
    # pools data chiffrés + encryptionroot zroot (profil Option I).
    def encryption_units : Array(String)
      units = data_zpools.select(&.encrypted?).map(&.name)
      if er = zpools.find(&.boot).try(&.encryption_root)
        units << er
      end
      units
    end

    # Utilisateur de connexion SSH effectif : le PREMIER user sudo-capable de
    # `freebsd.users` (groupe `wheel` ou `sudo: true`), à défaut `user`. Sur les
    # hôtes durcis le root SSH est fermé → beryl entre par ce compte. Aligné sur
    # `beryl apply`/`vrack` (qui dérivaient cette logique chacun de leur côté).
    def connect_user : String
      if users = @merged[YAML::Any.new("freebsd")]?.try(&.as_h?).try(&.[YAML::Any.new("users")]?).try(&.as_a?)
        Beryl::Config::Users.list(users).each do |e|
          wheel = {"groups", "secondary_groups"}.any? do |k|
            e.fields[YAML::Any.new(k)]?.try(&.as_a?).try(&.any? { |g| g.as_s? == "wheel" })
          end
          sudo = e.fields[YAML::Any.new("sudo")]?.try(&.as_bool?) == true
          return e.name if wheel || sudo
        end
      end
      user
    end

    # Hôte de rebond SSH (bastion) pour joindre ce host, ex.
    # `deploy@zsbg.example.net`. Passé à ssh via `-o ProxyJump=…` (donc
    # aussi à scp). INDISPENSABLE pour les hôtes cachés derrière le vRack
    # (port 22 public fermé) : beryl ne les joint plus qu'à travers un
    # bastion z. À combiner avec `ssh_host:` = IP vRack du host. nil =
    # connexion directe (cas par défaut).
    # Champ `bastion:` du host :
    #   - `true`         → CE host est un bastion (point d'entrée public du vRack).
    #   - `<nom>`        → host caché, joint VIA le bastion nommé (`bastion_name`).
    #   - `false`/absent → pas de bastion.
    # Section `vrack:` (config vRack du host, gérée par `beryl vrack`). Champs :
    # `name` (id OVH pn-XXXX), `ip` (scalaire OU liste=rotation), `proxy_jump`
    # (host caché) / `bastion` (true=z, false=public). Hash brut ou nil.
    private def vrack_hash : Hash(YAML::Any, YAML::Any)?
      @merged[YAML::Any.new("vrack")]?.try(&.as_h?)
    end

    private def vrack_field(key : String) : YAML::Any?
      vrack_hash.try(&.[YAML::Any.new(key)]?)
    end

    # Nom du vRack (id OVH pn-XXXX) déclaré dans `vrack.name`, ou nil.
    def vrack_name : String?
      vrack_field("name").try(&.as_s?)
    end

    # CE host est un bastion (point d'entrée public du vRack). Modèle :
    # `vrack.bastion: true`. Fallback legacy : `bastion: true` top-level.
    def bastion? : Bool
      if v = vrack_field("bastion")
        return v.as_bool? == true
      end
      @merged[YAML::Any.new("bastion")]?.try(&.as_bool?) == true
    end

    # Nom (court ou FQDN) du bastion par lequel joindre ce host caché, ou nil
    # (nil si `bastion:` est un booléen ou absent).
    def bastion_name : String?
      @merged[YAML::Any.new("bastion")]?.try(&.as_s?)
    end

    # ProxyJump effectif. `proxy_jump:` explicite prime ; sinon, si `bastion:
    # <nom>` est posé, on dérive `<user>@<nom>.<domaine>` (user du saut = celui
    # de la connexion). nil = connexion directe (cas par défaut).
    def proxy_jump(connect_user : String? = nil) : String?
      # Modèle `vrack.proxy_jump` (posé par `beryl vrack`), chaîne complète
      # `<user>@<bastion.fqdn>` → le user du transfert est dedans.
      if np = vrack_field("proxy_jump").try(&.as_s?)
        return np
      end
      # Legacy : `proxy_jump:` top-level, puis dérivation depuis `bastion: <nom>`.
      if explicit = @merged[YAML::Any.new("proxy_jump")]?.try(&.as_s?)
        return explicit
      end
      if name = bastion_name
        host = name.includes?('.') ? name : "#{name}.#{domain_name}"
        return "#{connect_user || user}@#{host}"
      end
      nil
    end

    # Host CACHÉ (22 public fermé) — IMPLICITE : présence d'un `proxy_jump`
    # (nouveau modèle) ou d'un `bastion: <nom>` (legacy, dérive proxy_jump).
    # Un bastion (`network.bastion: true`) n'a pas de proxy_jump → non caché.
    def hidden? : Bool
      !proxy_jump.nil?
    end

    # IP vRack du host, source de vérité du DNS interne (`beryl vrack-dns`).
    # Lue d'un champ explicite `vrack_ip:` ou, à défaut, des arguments de la
    # recette `vrack-interface` dans `apply_recipes:` (`{ ip: 192.168.42.x }`).
    # nil si le host n'est pas sur le vRack.
    # IP(s) vRack normalisées en LISTE (1ʳᵉ = primaire, suivantes = alias /
    # rotation). Source : `network.vrack_ip` (scalaire OU liste). Fallback
    # legacy : `vrack_ip:` top-level puis recette `vrack-interface`.
    def vrack_ips : Array(String)
      if v = vrack_field("ip")
        if s = v.as_s?
          return [s]
        elsif a = v.as_a?
          return a.compact_map(&.as_s?)
        end
      end
      if explicit = @merged[YAML::Any.new("vrack_ip")]?.try(&.as_s?)
        return [explicit]
      end
      if ip = legacy_vrack_interface_ip
        return [ip]
      end
      [] of String
    end

    # 1ʳᵉ IP vRack (primaire), ou nil si le host n'est pas sur le vRack.
    # Source de vérité du DNS interne (`beryl vrack-dns`) et de `ssh_host`
    # quand le host est caché.
    def vrack_ip : String?
      vrack_ips.first?
    end

    # Vrai si l'IP est déjà déclarée DANS la section `vrack:` (≠ fallback legacy).
    # Sert à `beryl vrack` pour ne consolider l'IP que si elle n'y est pas (et ne
    # pas écraser une LISTE de rotation).
    def vrack_declares_ip? : Bool
      !vrack_field("ip").nil?
    end

    # Vrai si le RÔLE réseau est déjà déterminé (`proxy_jump` ou `bastion`
    # posé — section `vrack:` ou fallback legacy top-level). Sert à `beryl
    # vrack` : on n'ouvre le chooser de rôle que si le rôle est encore inconnu
    # (re-poser la question quand il est déjà fixé n'apporte rien).
    def vrack_role_declared? : Bool
      {"proxy_jump", "bastion"}.any? do |k|
        !vrack_field(k).nil? || !@merged[YAML::Any.new(k)]?.nil?
      end
    end

    # Legacy : IP déclarée par la recette `vrack-interface` dans `apply_recipes`.
    private def legacy_vrack_interface_ip : String?
      arr = @merged[YAML::Any.new("apply_recipes")]?.try(&.as_a?)
      return nil unless arr
      arr.each do |entry|
        args = entry.as_h?.try(&.[YAML::Any.new("vrack-interface")]?).try(&.as_h?)
        next unless args
        if ip = args[YAML::Any.new("ip")]?.try(&.as_s?)
          return ip
        end
      end
      nil
    end

    # URL d'un binaire `storcli64` (Linux) à récupérer dans le rescue pour
    # piloter un contrôleur RAID matériel (MegaRAID…). Le rescue OVH ne
    # fournit aucun outil contrôleur → beryl le `curl` depuis ici. Hébergé
    # par nos soins (ex. release `acme/infra-bin`). nil = pas de
    # reconstruction RAID possible (seule l'option « volume tel quel »).
    def storcli_url : String?
      @merged[YAML::Any.new("storcli_url")]?.try(&.as_s?)
    end

    # Chemin de la clé privée SSH à utiliser pour ce host.
    #
    # Ordre de résolution :
    #
    #   1. `identity_file:` explicitement déclaré dans le merge (YAML
    #      host, domaine, `_account.yml` ou `_default.yml`). Prime.
    #   2. Résolution par convention beryl depuis `ovh.ssh_key_name` :
    #      le label côté OVH (ex: `user-example-com`) est traduit en
    #      fichier local `<ssh_dir>/philippe.example.com.key`. Permet de
    #      ne pas dupliquer l'info : la même clé est référencée par
    #      son nom côté provider et résolue automatiquement côté disque.
    #   3. Sinon nil. `SSH::Connection` lancera alors sans `-i`, et
    #      comme `IdentitiesOnly=yes` est forcé, l'auth publickey
    #      échouera avec un message clair (pas de fallback silencieux
    #      sur les clés par défaut du shell).
    def identity_file : String?
      if explicit = @merged[YAML::Any.new("identity_file")]?.try(&.as_s?)
        return File.expand_path(explicit, home: true)
      end
      if name = ovh_ssh_key_name
        return ::SSH::KeyStore.new.path_for(name)
      end
      nil
    end

    # OS du host (freebsd, debian, ubuntu, …). Défaut : freebsd
    # (historique beryl). L'architecture ADR-014 prévoit l'extension
    # multi-OS, l'impl actuelle ne câble que FreeBSD.
    def os : String
      @merged[YAML::Any.new("os")]?.try(&.as_s?) || "freebsd"
    end

    # IP overlay (mesh Headscale) déclarée dans le YAML host
    # (`overlay_ip: 100.64.x.y`). Lue par `ssh_host` quand le mode
    # transport global est `:overlay` — cf. Phase 4 de la roadmap
    # Headscale dans la mémoire `roadmap_beryl_headscale.md`.
    def overlay_ip : String?
      @merged[YAML::Any.new("overlay_ip")]?.try(&.as_s?)
    end

    # Hostname effectif pour SSH.
    #
    # Ordre de résolution :
    #
    #   0. Si transport global = `:overlay` ET `overlay_ip:` présent
    #      → cette IP. Use case : tous les CLI beryl appelés avec
    #      `--transport=overlay` parlent au host via le mesh Headscale,
    #      avec un port 22 fermé en public (cf. recipe
    #      `sshd-overlay-only`).
    #   1. `ssh_host:` explicite dans le YAML mergé. Prime sur tout
    #      le reste sauf l'overlay.
    #      Cas d'usage : test local (`ssh_host: 127.0.0.1`), VPN
    #      avec FQDN interne distinct du DNS public, alias DNS
    #      provider qu'on veut figer.
    #   2. Si provider OVH avec `ovh.service_name` : on privilégie
    #      le FQDN OVH (toujours résoluble en DNS public).
    #   3. Sinon le FQDN logique (`<short_name>.<domaine>`).
    #
    # Avant le fix du 28 avril 2026 (commit 3b19dfb), `ssh_host:` du
    # YAML était silencieusement ignoré sauf pour OVH — incohérent et
    # bloquant pour tester en local.
    def ssh_host : String
      if Beryl.use_overlay_transport? && (ip = overlay_ip)
        return ip
      end
      if explicit = @merged[YAML::Any.new("ssh_host")]?.try(&.as_s?)
        return explicit
      end
      # Host caché (proxy_jump présent) → on le joint par sa 1ʳᵉ IP vRack (le 22
      # public est fermé). Le ProxyJump passe par le bastion.
      if hidden? && (vip = vrack_ips.first?)
        return vip
      end
      if provider == "ovh" && (sn = ovh_service_name)
        return sn
      end
      fqdn
    end

    # Adresse SSH pour les opérations en mode RESCUE (`beryl rescue`,
    # `beryl wipe`, phase rescue de `beryl bootstrap`).
    #
    # Le système de secours (rescue Linux) ne dispose QUE de l'IP
    # publique du serveur : il n'est ni attaché au vRack ni joint à
    # l'overlay, et n'a pas de ProxyJump. Pour un host CACHÉ, `ssh_host`
    # renvoie l'IP vRack (injoignable en rescue) → on l'ignore et on vise
    # l'adresse publique DNS-résoluble (service OVH) ou l'IPv4 publique.
    #
    # Pour tout host NON caché, on retombe sur `ssh_host` à l'identique
    # (aucun changement de comportement). Surchargable via
    # `rescue_ssh_host:` dans le YAML mergé.
    def rescue_ssh_host : String
      if explicit = @merged[YAML::Any.new("rescue_ssh_host")]?.try(&.as_s?)
        return explicit
      end
      if hidden?
        if provider == "ovh" && (sn = ovh_service_name)
          return sn
        end
        if ip = ovh_ipv4
          return ip
        end
      end
      ssh_host
    end

    # Vrai si l'opérateur a déclaré explicitement `ssh_host:` dans
    # un YAML du merge. Distingue le cas « override YAML » du cas
    # « nom de host hébergeur dérivé ». Utilisé par
    # `Beryl.format_ssh_target` pour produire un libellé sémantiquement
    # juste : « fqdn (via 127.0.0.1) » plutôt que « fqdn (= 127.0.0.1
    # côté local) » qui prêterait à confusion (« local » n'est pas un
    # provider hébergeur).
    def ssh_host_explicit? : Bool
      !@merged[YAML::Any.new("ssh_host")]?.try(&.as_s?).nil?
    end

    # Vrai si `ssh_host` provient d'un *provider hébergeur*
    # (typiquement OVH avec `ovh.service_name`) et diffère du FQDN
    # logique. Distingue ce cas du cas « override YAML » couvert
    # par `ssh_host_explicit?`. Si l'opérateur a posé un
    # `ssh_host:` YAML, ce flag est faux même si la valeur diffère
    # du FQDN — la responsabilité est à l'opérateur, pas au
    # provider.
    def ssh_host_is_provider_name? : Bool
      return false if ssh_host_explicit?
      return false if hidden? # vient de l'IP vRack (host caché), pas du provider
      ssh_host != fqdn
    end

    # Bloc `freebsd:` mergé (hash brut).
    def freebsd_hash : Hash(YAML::Any, YAML::Any)
      @merged[YAML::Any.new("freebsd")]?.try(&.as_h?) || {} of YAML::Any => YAML::Any
    end

    def freebsd_string(field : String) : String?
      freebsd_hash[YAML::Any.new(field)]?.try(&.as_s?)
    end

    def freebsd_int(field : String) : Int32?
      freebsd_hash[YAML::Any.new(field)]?.try(&.as_i?)
    end

    def freebsd_string_array(field : String) : Array(String)
      val = freebsd_hash[YAML::Any.new(field)]?
      return [] of String unless val
      (val.as_a? || [] of YAML::Any).compact_map(&.as_s?)
    end

    # Hash `freebsd.zpool.*` — syntaxe single-pool legacy.
    def freebsd_zpool_hash : Hash(YAML::Any, YAML::Any)
      freebsd_hash[YAML::Any.new("zpool")]?.try(&.as_h?) || {} of YAML::Any => YAML::Any
    end

    # Hash `freebsd.zfs.*` — syntaxe multi-pool.
    def freebsd_zfs_hash : Hash(YAML::Any, YAML::Any)
      freebsd_hash[YAML::Any.new("zfs")]?.try(&.as_h?) || {} of YAML::Any => YAML::Any
    end

    # Liste tous les pools ZFS déclarés (ancienne et nouvelle syntaxe).
    def zpools : Array(Beryl::Config::Pool)
      zfs = freebsd_zfs_hash
      if zfs.empty?
        zp = freebsd_zpool_hash
        return [] of Beryl::Config::Pool if zp.empty?
        return [Beryl::Config::Pool.new(
          name: "zroot",
          boot: true,
          raid: (zp[YAML::Any.new("raid")]?.try(&.as_i?) || 0),
          disks: (zp[YAML::Any.new("disks")]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String),
        )]
      end
      zfs.map do |name_any, value_any|
        name = name_any.as_s
        h = value_any.as_h? || {} of YAML::Any => YAML::Any
        Beryl::Config::Pool.new(
          name: name,
          boot: h[YAML::Any.new("boot")]?.try(&.as_bool?) || false,
          raid: (h[YAML::Any.new("raid")]?.try(&.as_i?) || 0),
          disks: (h[YAML::Any.new("disks")]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String),
          mountpoint: h[YAML::Any.new("mountpoint")]?.try(&.as_s?),
          encryption: parse_encryption(h[YAML::Any.new("encryption")]?, name),
          profile: h[YAML::Any.new("profile")]?.try(&.as_s?),
        )
      end
    end

    # Délégation à la factory `EncryptionConfig.from_yaml` —
    # historique : ce parser vivait inline dans `zpools` ; extrait
    # côté struct pour permettre les tests unitaires sans fixture.
    private def parse_encryption(any : YAML::Any?, pool_name : String) : Beryl::Config::EncryptionConfig?
      Beryl::Config::EncryptionConfig.from_yaml(any, pool_name)
    end

    def boot_zpool : Beryl::Config::Pool
      boots = zpools.select(&.boot)
      raise NoBootPool.new("aucun pool `boot: true` pour #{fqdn}") if boots.empty?
      raise MultipleBootPools.new("plusieurs pools `boot: true` pour #{fqdn}") if boots.size > 1
      boots.first
    end

    def data_zpools : Array(Beryl::Config::Pool)
      zpools.reject(&.boot)
    end

    def all_declared_disks : Array(String)
      zpools.flat_map(&.disks)
    end

    def validate_zfs! : Nil
      pools = zpools
      raise NoZFSPool.new("aucun pool ZFS déclaré pour #{fqdn} (freebsd.zfs.<nom> ou freebsd.zpool)") if pools.empty?

      boots = pools.select(&.boot)
      raise NoBootPool.new("aucun pool `boot: true` pour #{fqdn}") if boots.empty?
      raise MultipleBootPools.new("plusieurs pools `boot: true` pour #{fqdn} : #{boots.map(&.name).join(", ")}") if boots.size > 1

      pools.each(&.validate!)

      seen = Set(String).new
      pools.each do |pool|
        pool.disks.each do |d|
          raise DuplicatedDisk.new("le disque #{d} est déclaré dans plusieurs pools") if seen.includes?(d)
          seen << d
        end
      end

      data_zpools.each do |p|
        raise MissingMountpoint.new("pool data `#{p.name}` sans mountpoint (ajoutez `mountpoint: /xxx`)") if p.mountpoint.nil?
      end
    end

    class NoZFSPool < Exception; end

    class NoBootPool < Exception; end

    class MultipleBootPools < Exception; end

    class DuplicatedDisk < Exception; end

    class MissingMountpoint < Exception; end

    # Avertissement clé SSH : pour un host OVH, si AUCUNE clé privée n'est
    # résolue (ni `identity_file:` explicite, ni `ovh.ssh_key_name` valide),
    # beryl se connecterait SANS `-i` — et comme `IdentitiesOnly=yes` est forcé,
    # l'auth publickey échoue par un opaque « Permission denied ». On renvoie ici
    # un message clair. nil si tout va bien (clé résolue) ou host non-OVH (où
    # l'absence de clé peut être légitime : test local, autre provider…).
    #
    # Piège typique : `ovh.ssh_key_name` rangé sous `freebsd:` au lieu de la
    # RACINE → `ovh_ssh_key_name` (qui lit le bloc `ovh:` racine) renvoie nil.
    def ssh_key_diagnostic : String?
      return nil unless provider == "ovh"
      return nil unless identity_file.nil?
      if name = ovh_ssh_key_name
        "clé OVH « #{name} » (ovh.ssh_key_name) introuvable dans ~/.ssh " \
        "(attendu ~/.ssh/#{name.gsub('-', '.')}.key)"
      else
        "aucune clé SSH résolue pour #{fqdn} : `ovh.ssh_key_name` absent — " \
        "il doit être au niveau RACINE du YAML (bloc `ovh:`), PAS sous `freebsd:`"
      end
    end

    # Émet l'avertissement clé SSH au plus une fois par host (évite le spam
    # quand un CLI ouvre plusieurs connexions). Branché sur tous les points
    # d'entrée SSH (`connection`, `rescue_connection`).
    private def warn_ssh_key_once : Nil
      return if @ssh_key_warned
      @ssh_key_warned = true
      if msg = ssh_key_diagnostic
        STDERR.puts "beryl : ⚠️  #{msg}"
      end
    end

    # Construit une `SSH::Connection` prête à l'emploi.
    def connection(user_override : String? = nil) : SSH::Connection
      warn_ssh_key_once
      eff_user = user_override || user
      opts = {} of String => String
      if pj = proxy_jump(eff_user)
        opts["ProxyJump"] = pj
      end
      SSH::Connection.new(
        host: ssh_host,
        user: eff_user,
        port: port,
        identity_file: identity_file,
        options: opts,
      )
    end

    # Connexion au rescue Linux : TOUJOURS root, INDÉPENDAMMENT de `user`
    # (qui désigne l'utilisateur du serveur INSTALLÉ, ex. admin). Toute
    # commande qui parle au rescue (scan, wipe, bootstrap…) doit l'utiliser
    # plutôt que `connection`, sinon `user: admin` casse l'accès (le rescue
    # n'a que root).
    def rescue_connection : SSH::Connection
      warn_ssh_key_once
      SSH::Connection.new(
        host: ssh_host,
        user: "root",
        port: port,
        identity_file: identity_file,
      )
    end
  end
end
