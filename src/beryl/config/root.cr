require "yaml"

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
    DEFAULT_PATH = File.expand_path("~/.beryl", home: true)

    getter path : String
    getter defaults : Hash(YAML::Any, YAML::Any)
    getter accounts : Hash(String, Account)
    getter env_file : EnvFile
    getter ssh_dir : String

    def initialize(@path, @defaults, @accounts, @env_file, @ssh_dir = DEFAULT_SSH_DIR)
    end

    # Charge une arborescence complète depuis le disque. `ssh_dir`
    # est le dossier où chercher les clés SSH référencées par nom
    # (ex. `philippe.aloli.fr.pub` → `<ssh_dir>/philippe.aloli.fr.pub`).
    # Paramétrable pour les tests qui utilisent des fixtures.
    def self.load(path : String = DEFAULT_PATH, ssh_dir : String = DEFAULT_SSH_DIR) : Root
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
    # en ait plusieurs, mais possible (ex: une société ALOLI et une
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
    #   3. Suffix match : `rails01.aloli.net` — cherche un domaine
    #      `aloli.net` dans toutes les sociétés. Si plusieurs sociétés
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
    # être FQDN ou court. `rails01.aloli.net` dans le domaine
    # `aloli.net` → `rails01`.
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
      merged = Merger.merge(@defaults, domain, group, node, ssh_dir: @ssh_dir)
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
      merged = Merger.merge(@defaults, domain, nil, virtual_node, ssh_dir: @ssh_dir)
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
    end

    # FQDN reconstitué : `<short_name>.<domaine>`. Le groupe
    # n'apparaît pas (règle figée : pas de `rails01.web.aloli.net`).
    #
    # Exception : si `short_name` contient déjà un point, c'est un
    # FQDN externe (nom hébergeur type `ns3156789.ip-51-83-6.eu` ou
    # alias DNS qui ne relève pas du domaine aloli). On le garde
    # tel quel — sans quoi on fabriquerait un
    # `ns3156789.ip-51-83-6.eu.aloli.net` qui ne résout nulle part.
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

    def scaleway_server_id : String?
      provider_field("scaleway", "server_id")
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

    def identity_file : String?
      @merged[YAML::Any.new("identity_file")]?.try(&.as_s?)
    end

    # OS du host (freebsd, debian, ubuntu, …). Défaut : freebsd
    # (historique beryl). L'architecture ADR-014 prévoit l'extension
    # multi-OS, l'impl actuelle ne câble que FreeBSD.
    def os : String
      @merged[YAML::Any.new("os")]?.try(&.as_s?) || "freebsd"
    end

    # Hostname effectif pour SSH. Pour OVH avec service_name déclaré,
    # on privilégie le FQDN OVH (toujours résoluble). Sinon le FQDN
    # logique.
    def ssh_host : String
      if provider == "ovh" && (sn = ovh_service_name)
        return sn
      end
      fqdn
    end

    # Vrai si ssh_host ≠ fqdn (on utilise le nom hébergeur, pas le
    # nom custom).
    def ssh_host_is_provider_name? : Bool
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
        )
      end
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

    # Construit une `SSH::Connection` prête à l'emploi.
    def connection : SSH::Connection
      SSH::Connection.new(
        host: ssh_host,
        user: user,
        port: port,
        identity_file: identity_file,
      )
    end
  end
end
