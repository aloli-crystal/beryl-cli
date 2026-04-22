require "yaml"

module Beryl::Config
  # Point d'entrée de la configuration beryl. Regroupe :
  #
  #   - le socle `_default.yml` (Hash brut)
  #   - les domaines chargés (Hash<String, Domain>)
  #   - `.env.yml` pour les credentials par domaine
  #
  # Les opérations habituelles (résolution d'un host, obtention de la
  # config mergée) passent par des méthodes de cette classe.
  class Root
    DEFAULT_PATH = File.expand_path("~/.beryl", home: true)

    getter path : String
    getter defaults : Hash(YAML::Any, YAML::Any)
    getter domains : Hash(String, Domain)
    getter env_file : EnvFile
    getter ssh_dir : String

    def initialize(@path, @defaults, @domains, @env_file, @ssh_dir = DEFAULT_SSH_DIR)
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
        domains: result[:domains],
        env_file: result[:env_file],
        ssh_dir: ssh_dir,
      )
    end

    # Liste des noms de domaines configurés (ex: ["aloli.net", "quimeo.fr"]).
    def domain_names : Array(String)
      @domains.keys.sort
    end

    # Retourne un domaine ou nil.
    def domain?(name : String) : Domain?
      @domains[name]?
    end

    # Tous les hosts de tous les domaines, par FQDN.
    # Pratique pour lister et pour les recherches globales.
    def all_hosts_by_fqdn : Hash(String, {domain: Domain, group: Group?, node: HostNode})
      result = {} of String => NamedTuple(domain: Domain, group: Group?, node: HostNode)
      @domains.each_value do |domain|
        domain.direct_hosts.each do |name, node|
          fqdn = "#{name}.#{domain.name}"
          result[fqdn] = {domain: domain, group: nil.as(Group?), node: node}
        end
        domain.groups.each_value do |group|
          group.hosts.each do |name, node|
            fqdn = "#{name}.#{domain.name}"
            result[fqdn] = {domain: domain, group: group.as(Group?), node: node}
          end
        end
      end
      result
    end

    # Résout un nom CLI vers un host effectif mergé.
    #
    # Règles (premier match gagne) :
    #
    #   1. `--domain=<name>` fourni ET un host du même nom existe
    #      dans ce domaine → utilisé.
    #   2. `--domain=<name>` fourni sans host existant → host virtuel
    #      dans ce domaine (utile pour `beryl rescue` sur un serveur
    #      neuf).
    #   3. Suffix match : `rails01.aloli.net` → `aloli.net` trouvé
    #      par suffix. Si fichier host existe → utilisé. Sinon host
    #      virtuel.
    #   4. Recherche dans les fichiers existants (nom de fichier ou
    #      valeur `provider.service_name`/`server_id`). Si 1 match →
    #      utilisé. Si plusieurs → ambigu (lève `AmbiguousHost`).
    #   5. Sinon → `HostNotFound` qui suggère `--domain`.
    #
    # Résultat : un `ResolvedHost` (host effectif + domaine + groupe).
    def resolve(name : String, domain_hint : String? = nil) : ResolvedHost
      # 1–2 : --domain explicite
      if domain_hint
        domain = @domains[domain_hint]? || raise UnknownDomain.new(
          "domaine inconnu : #{domain_hint}. Domaines configurés : #{domain_names.join(", ")}"
        )
        short = short_name_in_domain(name, domain)
        if node_info = find_host_in_domain(domain, short)
          return build_resolved(domain, node_info[:group], node_info[:node])
        end
        # Host virtuel : pas de fichier, mais on peut opérer dessus
        # (ex: beryl rescue sur un serveur neuf).
        return virtual_resolved(domain, short)
      end

      # 3 : suffix match sur un domaine connu
      if (suffix_match = match_domain_suffix(name))
        domain, short = suffix_match
        if node_info = find_host_in_domain(domain, short)
          return build_resolved(domain, node_info[:group], node_info[:node])
        end
        return virtual_resolved(domain, short)
      end

      # 4 : recherche dans les fichiers (nom logique et provider-name)
      matches = search_all_domains(name)
      case matches.size
      when 0
        raise HostNotFound.new(
          "hôte inconnu : #{name}. Passez --domain=<nom> " \
          "(domaines configurés : #{domain_names.join(", ")})"
        )
      when 1
        m = matches.first
        build_resolved(m[:domain], m[:group], m[:node])
      else
        raise AmbiguousHost.new(
          "nom `#{name}` présent dans plusieurs domaines : " \
          "#{matches.map(&.[:domain].name).join(", ")}. " \
          "Précisez --domain=<nom>.",
          matches,
        )
      end
    end

    # Extrait le nom court d'un host à partir d'un nom CLI qui peut
    # être FQDN ou court. `rails01.aloli.net` dans le domaine
    # `aloli.net` → `rails01`. Si le nom est déjà court (pas de point)
    # ou ne finit pas par `.<domaine>`, on retourne tel quel.
    private def short_name_in_domain(name : String, domain : Domain) : String
      suffix = ".#{domain.name}"
      name.ends_with?(suffix) ? name[0...(name.size - suffix.size)] : name
    end

    # Si le nom se termine par `.<domaine>` pour l'un des domaines
    # configurés, retourne `{domaine, nom_court}`.
    private def match_domain_suffix(name : String) : {Domain, String}?
      @domains.each_value do |domain|
        suffix = ".#{domain.name}"
        if name.ends_with?(suffix)
          return {domain, name[0...(name.size - suffix.size)]}
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

    # Cherche dans tous les domaines un host par nom de fichier ET par
    # valeur `provider.service_name` / `scaleway.server_id` / `id`.
    private def search_all_domains(name : String) : Array(NamedTuple(domain: Domain, group: Group?, node: HostNode))
      matches = [] of NamedTuple(domain: Domain, group: Group?, node: HostNode)
      @domains.each_value do |domain|
        domain.direct_hosts.each do |host_name, node|
          matches << {domain: domain, group: nil.as(Group?), node: node} if host_matches?(host_name, node, name)
        end
        domain.groups.each_value do |group|
          group.hosts.each do |host_name, node|
            matches << {domain: domain, group: group.as(Group?), node: node} if host_matches?(host_name, node, name)
          end
        end
      end
      matches
    end

    # Vrai si le nom de host ou l'une des valeurs `provider-name`
    # déclarées dans le YAML correspond au nom cherché.
    private def host_matches?(host_name : String, node : HostNode, search : String) : Bool
      return true if host_name == search
      # Cherche dans les provider-names connus au niveau host (le
      # merge complet serait nécessaire pour le champ qui vient du
      # domaine — mais en pratique c'est le host lui-même qui porte
      # le service_name spécifique).
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

    private def build_resolved(domain : Domain, group : Group?, node : HostNode) : ResolvedHost
      merged = Merger.merge(@defaults, domain, group, node, ssh_dir: @ssh_dir)
      ResolvedHost.new(
        short_name: node.name,
        domain: domain,
        group: group,
        node: node,
        merged: merged,
      )
    end

    # Construit un host virtuel (pas de fichier). Utilisé pour
    # `beryl rescue` sur un serveur neuf : on connaît le domaine et
    # le nom mais il n'y a pas encore de YAML dédié.
    private def virtual_resolved(domain : Domain, short_name : String) : ResolvedHost
      virtual_node = HostNode.new(
        name: short_name,
        raw: {} of YAML::Any => YAML::Any,
        source_path: "<virtual>",
      )
      merged = Merger.merge(@defaults, domain, nil, virtual_node, ssh_dir: @ssh_dir)
      ResolvedHost.new(
        short_name: short_name,
        domain: domain,
        group: nil,
        node: virtual_node,
        merged: merged,
        virtual: true,
      )
    end

    # ---------- Exceptions de résolution ----------

    class UnknownDomain < Exception
    end

    class HostNotFound < Exception
    end

    class AmbiguousHost < Exception
      getter candidates : Array(NamedTuple(domain: Domain, group: Group?, node: HostNode))

      def initialize(message : String, @candidates)
        super(message)
      end
    end
  end

  # Host résolu : résultat d'une recherche dans la `Root`. Porte le
  # contexte (domaine, groupe éventuel) + la config effective mergée.
  # Expose des accesseurs pratiques pour les sous-commandes (ssh_host,
  # ovh_service_name, …) qui évitent ainsi le parsing manuel du hash
  # `merged`.
  class ResolvedHost
    getter short_name : String # "rails01"
    getter domain : Domain
    getter group : Group?
    getter node : HostNode
    getter merged : Hash(YAML::Any, YAML::Any)
    getter virtual : Bool # true si pas de fichier

    def initialize(
      @short_name : String,
      @domain : Domain,
      @group : Group?,
      @node : HostNode,
      @merged : Hash(YAML::Any, YAML::Any),
      @virtual : Bool = false,
    )
    end

    # FQDN reconstitué : `<short_name>.<domaine>`. Le groupe
    # n'apparaît pas (règle figée : pas de `rails01.web.aloli.net`).
    #
    # Exception : si `short_name` contient déjà un point, c'est que
    # l'utilisateur a passé un FQDN externe (nom hébergeur type
    # `ns3156789.ip-51-83-6.eu` ou un alias DNS qui ne relève pas du
    # domaine aloli). Dans ce cas on le garde tel quel — sans quoi on
    # fabriquerait un `ns3156789.ip-51-83-6.eu.aloli.net` qui ne
    # résout nulle part.
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

    # Provider déclaré dans le merged (ex: "ovh", "scaleway").
    def provider : String?
      @merged[YAML::Any.new("provider")]?.try(&.as_s?)
    end

    # Accès générique à un champ du bloc `<provider>:` (service_name,
    # server_id, zone, etc.).
    def provider_field(provider_name : String, field : String) : String?
      block = @merged[YAML::Any.new(provider_name)]?.try(&.as_h?)
      return nil unless block
      block[YAML::Any.new(field)]?.try(&.as_s?)
    end

    def ovh_service_name : String?
      provider_field("ovh", "service_name")
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

    # Hostname effectif pour SSH. Pour OVH avec service_name déclaré,
    # on privilégie le FQDN OVH (toujours résoluble). Sinon le FQDN
    # logique. Permet de se connecter même sans DNS custom posé.
    def ssh_host : String
      if provider == "ovh" && (sn = ovh_service_name)
        return sn
      end
      fqdn
    end

    # Vrai si ssh_host ≠ fqdn (on utilise le nom hébergeur, pas le
    # nom custom). Utile pour afficher les deux dans les logs.
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

    # Hash `freebsd.zpool.*` — syntaxe single-pool historique (RAID
    # numérique + disks à la racine du zpool). Conservée pour lire
    # une éventuelle config simple.
    def freebsd_zpool_hash : Hash(YAML::Any, YAML::Any)
      freebsd_hash[YAML::Any.new("zpool")]?.try(&.as_h?) || {} of YAML::Any => YAML::Any
    end

    # Hash `freebsd.zfs.*` — syntaxe multi-pool : chaque clé enfant
    # est le nom d'un pool ZFS, avec son propre `raid`, `disks`,
    # éventuel `boot: true` / `mountpoint`.
    def freebsd_zfs_hash : Hash(YAML::Any, YAML::Any)
      freebsd_hash[YAML::Any.new("zfs")]?.try(&.as_h?) || {} of YAML::Any => YAML::Any
    end

    # Liste tous les pools ZFS déclarés, en supportant les deux
    # syntaxes :
    # - `freebsd.zfs.<nom>.{raid, disks, boot, mountpoint}` (preferred)
    # - `freebsd.zpool.{raid, disks}` (single-pool legacy, interprété
    #   comme un pool unique nommé « zroot » avec boot: true)
    def zpools : Array(Beryl::Config::Pool)
      zfs = freebsd_zfs_hash
      if zfs.empty?
        # Legacy : un seul zpool implicite
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

    # Pool de boot (exactement un obligatoirement pour un bootstrap
    # valide). Lève `NoBootPool` si aucun, `MultipleBootPools` si
    # plusieurs. Accessible seulement après `validate_zfs!`.
    def boot_zpool : Beryl::Config::Pool
      boots = zpools.select(&.boot)
      raise NoBootPool.new("aucun pool `boot: true` pour #{fqdn}") if boots.empty?
      raise MultipleBootPools.new("plusieurs pools `boot: true` pour #{fqdn}") if boots.size > 1
      boots.first
    end

    # Pools data (tous les pools sauf celui de boot). Créés après
    # l'install FreeBSD via `zpool create`.
    def data_zpools : Array(Beryl::Config::Pool)
      zpools.reject(&.boot)
    end

    # Tous les disques déclarés dans tous les pools, à plat.
    def all_declared_disks : Array(String)
      zpools.flat_map(&.disks)
    end

    # Valide l'ensemble `freebsd.zfs.*` :
    #   - au moins un pool, exactement un avec `boot: true`
    #   - chaque pool a un raid+disks compatibles (MIN_DISKS, parité)
    #   - aucun disque n'est déclaré dans plusieurs pools
    #   - les pools data ont un mountpoint
    def validate_zfs! : Nil
      pools = zpools
      raise NoZFSPool.new("aucun pool ZFS déclaré pour #{fqdn} (freebsd.zfs.<nom> ou freebsd.zpool)") if pools.empty?

      # Exactement un boot
      boots = pools.select(&.boot)
      raise NoBootPool.new("aucun pool `boot: true` pour #{fqdn}") if boots.empty?
      raise MultipleBootPools.new("plusieurs pools `boot: true` pour #{fqdn} : #{boots.map(&.name).join(", ")}") if boots.size > 1

      # Chaque pool : raid/disks valides
      pools.each(&.validate!)

      # Pas de disque partagé
      seen = Set(String).new
      pools.each do |pool|
        pool.disks.each do |d|
          raise DuplicatedDisk.new("le disque #{d} est déclaré dans plusieurs pools") if seen.includes?(d)
          seen << d
        end
      end

      # Les pools data doivent avoir un mountpoint
      data_zpools.each do |p|
        raise MissingMountpoint.new("pool data `#{p.name}` sans mountpoint (ajoutez `mountpoint: /xxx`)") if p.mountpoint.nil?
      end
    end

    class NoZFSPool < Exception; end

    class NoBootPool < Exception; end

    class MultipleBootPools < Exception; end

    class DuplicatedDisk < Exception; end

    class MissingMountpoint < Exception; end

    # Construit une `SSH::Connection` prête à l'emploi vers cet host
    # avec `ssh_host` comme cible.
    def connection : SSH::Connection
      SSH::Connection.new(
        host: ssh_host,
        user: user,
        port: port,
        identity_file: identity_file,
      )
    end

    def group_name : String?
      @group.try(&.name)
    end
  end
end
