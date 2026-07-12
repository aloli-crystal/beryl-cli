require "../cli/credentials"
require "../cli/dns_setup"

module Beryl::Providers
  # Provider OVHcloud pour beryl. Encapsule la détection des credentials
  # (via `Beryl::CLI::Credentials.ovh_client`) et le listing des clés
  # SSH enregistrées dans le compte.
  #
  # Le client OVH est injectable via le constructeur pour les tests.
  # En production, on laisse le défaut `nil` et `client` résout à
  # la demande via `Credentials.ovh_client`.
  class Ovh < Beryl::Provider
    include Beryl::DnsProvider
    include Beryl::ComputeProvider

    def initialize(@injected_client : OvhApi::Client? = nil)
    end

    private def client : OvhApi::Client
      @injected_client || Beryl::CLI::Credentials.ovh_client
    end

    def name : String
      "ovh"
    end

    def display_name : String
      "OVHcloud"
    end

    def capabilities : Array(Symbol)
      [:dns, :compute]
    end

    # --- DnsProvider ---

    def ensure_record(zone : String, field_type : String, sub_domain : String, target : String) : Nil
      client.domains.ensure_record(zone, field_type, sub_domain, target)
    end

    def refresh_zone(zone : String) : Nil
      client.domains.refresh(zone)
    end

    def set_reverse(ip : String, reverse : String) : Nil
      target = reverse.ends_with?(".") ? reverse : "#{reverse}."
      # IPv6 : OVH gère le reverse au niveau du BLOC /64 — le path doit
      # porter le bloc, `ipReverse` l'adresse précise (sinon 404 « service
      # does not exist » sur le /128). IPv4 : bloc == adresse (/32).
      #
      # L'encodage du `/` du bloc (`…::/64` → `%2F`) est fait par le shard
      # api-ovh ≥ 0.7.3 (`encode_ip`) — on lui passe le bloc nu.
      path_ip = ip.includes?(':') ? Beryl::CLI::DnsSetup.ipv6_block_64(ip) : ip
      client.ips.set_reverse(ip: path_ip, reverse: target, ip_reverse: ip)
    end

    # --- ComputeProvider ---

    def request_rescue(resource_id : String, ssh_key_ref : String) : String
      task = client.dedicated_servers.prepare_rescue(
        service_name: resource_id, ssh_key_name: ssh_key_ref,
      )
      task.id.to_s
    end

    def boot_from_disk(resource_id : String) : String
      task = client.dedicated_servers.boot_from_disk(resource_id)
      task.id.to_s
    end

    def compute_task_status(task_id : String) : String
      # OVH : la task est liée à un service_name (pas un id global).
      # Le caller doit connaître le service_name pour interroger. À
      # l'usage, on préfère garder le pattern OVH existant (task
      # polling dans rescue.cr / boot_hd.cr) plutôt qu'une
      # abstraction lourde. Cette méthode est conservée pour l'API
      # mais jamais utilisée en interne — levée explicite.
      raise NotImplementedError.new(
        "OVH : compute_task_status n'est pas implémenté via cette API. " \
        "Utilisez `client.dedicated_servers.task(service_name, task_id)` directement."
      )
    end

    def compute_task_done?(status : String) : Bool
      status == "done"
    end

    # Inventaire disques déclaré par OVH (`specifications/hardware`). nil si
    # l'API ne répond pas ou n'expose pas `diskGroups`. flash = SSD+NVMe,
    # spinning = HDD ; total = somme de TOUS les disques déclarés. Couvert
    # par le droit `GET /dedicated/server/*` (pas de re-régén de clé).
    def hardware_disk_inventory(service_name : String) : Beryl::DiskInventory?
      resp = client.call("GET", "/dedicated/server/#{service_name}/specifications/hardware")
      groups = resp.try(&.["diskGroups"]?).try(&.as_a?)
      return nil unless groups
      flash = 0
      spinning = 0
      total = 0
      groups.each do |g|
        n = g["numberOfDisks"]?.try(&.as_i?) || 0
        next if n <= 0
        total += n
        type = (g["diskType"]?.try(&.as_s?) || "").downcase
        if type.includes?("ssd") || type.includes?("nvme")
          flash += n
        elsif type.includes?("hdd") || type.includes?("sata") || type.includes?("sas")
          spinning += n
        end
      end
      return nil if total == 0
      Beryl::DiskInventory.new(flash: flash, spinning: spinning, total: total)
    rescue
      nil
    end

    # Gamme commerciale OVH du serveur (ex. "Advance-2"), via
    # `GET /dedicated/server/{s}` → champ `commercialRange`. nil si l'API ne
    # répond pas. Couvert par le droit `GET /dedicated/server/*`.
    # Détails d'un serveur dédié en UN GET (`/dedicated/server/{s}`) : gamme
    # commerciale, baie (`rack`), IPv4 primaire (`ip`). Champs nil si absents /
    # API muette. Couvert par `GET /dedicated/server/*`.
    def server_detail(service_name : String) : NamedTuple(commercial: String?, rack: String?, ipv4: String?)
      resp = client.call("GET", "/dedicated/server/#{service_name}")
      {
        commercial: resp.try(&.["commercialRange"]?).try(&.as_s?),
        rack:       resp.try(&.["rack"]?).try(&.as_s?),
        ipv4:       resp.try(&.["ip"]?).try(&.as_s?),
      }
    rescue
      {commercial: nil, rack: nil, ipv4: nil}
    end

    # Gamme commerciale OVH seule (ex. "Advance-2"). Délègue à `server_detail`.
    def commercial_range(service_name : String) : String?
      server_detail(service_name)[:commercial]
    end

    # Caractéristiques matérielles DÉCLARÉES par OVH
    # (`specifications/hardware`) : CPU, cœurs/threads, RAM, disques. nil si
    # l'API ne répond pas. Lecture seule, droit `GET /dedicated/server/*`.
    def server_hardware(service_name : String) : Beryl::HardwareSpec?
      resp = client.call("GET", "/dedicated/server/#{service_name}/specifications/hardware")
      return nil unless resp
      nproc = resp["numberOfProcessors"]?.try(&.as_i?) || 1
      cpu = resp["processorName"]?.try(&.as_s?) || "(CPU inconnu)"
      cores = (resp["coresPerProcessor"]?.try(&.as_i?) || 0) * nproc
      threads = (resp["threadsPerProcessor"]?.try(&.as_i?) || 0) * nproc

      ram_gb = 0
      if mem = resp["memorySize"]?
        if mh = mem.as_h?
          v = mh["value"]?.try(&.as_i?) || 0
          unit = (mh["unit"]?.try(&.as_s?) || "GB").upcase
          ram_gb = unit.starts_with?("M") ? (v // 1024) : v
        elsif mv = mem.as_i?
          ram_gb = mv
        end
      end

      disks = [] of String
      raid : String? = nil
      if groups = resp["diskGroups"]?.try(&.as_a?)
        groups.each do |g|
          n = g["numberOfDisks"]?.try(&.as_i?) || 0
          next if n <= 0
          size_s = "?"
          if sz = g["diskSize"]?
            if sh = sz.as_h?
              size_s = "#{sh["value"]?.try(&.as_i?) || "?"} #{sh["unit"]?.try(&.as_s?) || "GB"}"
            elsif si = sz.as_i?
              size_s = "#{si} GB"
            end
          end
          type = g["diskType"]?.try(&.as_s?) || ""
          disks << "#{n} x #{size_s} #{type}".strip
          if rc = g["raidController"]?.try(&.as_s?)
            raid = rc unless rc.empty?
          end
        end
      end

      Beryl::HardwareSpec.new(
        cpu: nproc > 1 ? "#{nproc}x #{cpu}" : cpu,
        cores: cores, threads: threads, ram_gb: ram_gb, disks: disks, raid: raid,
      )
    rescue
      nil
    end

    # Cherche le service_name d'un serveur dédié OVH par son IP principale
    # (v4). nil si aucun match. Itère `/dedicated/server` puis lit l'`ip` de
    # chacun — permet de scanner un host par FQDN/IP sans connaître son
    # service_name. Couvert par `GET /dedicated/server` + `/dedicated/server/*`.
    def find_dedicated_server_by_ip(ip : String) : String?
      resp = client.call("GET", "/dedicated/server")
      return nil unless resp
      resp.as_a.each do |s|
        sn = s.as_s?
        next unless sn
        details = begin
          client.call("GET", "/dedicated/server/#{sn}")
        rescue
          next
        end
        next unless details
        return sn if details["ip"]?.try(&.as_s?) == ip
      end
      nil
    end

    # Prix de renouvellement MENSUEL du serveur (HT, devise du compte), via
    # `serviceInfos` → `serviceId` → `GET /services/{id}` (champ
    # `billing.pricing.price.value`). Chaîne formatée "89.99", nil si l'API ne
    # répond pas / ne l'expose pas / droit `GET /services/*` absent. Best-effort.
    def monthly_price(service_name : String) : String?
      infos = client.call("GET", "/dedicated/server/#{service_name}/serviceInfos")
      sid = infos.try(&.["serviceId"]?).try(&.as_i?)
      return nil unless sid
      svc = client.call("GET", "/services/#{sid}")
      return nil unless svc
      v = svc["billing"]?.try(&.["pricing"]?).try(&.["price"]?).try(&.["value"]?)
      val = v.try(&.as_f?) || v.try(&.as_i?).try(&.to_f)
      return nil unless val
      "%.2f" % val
    rescue
      nil
    end

    # Liste les `serviceName` de TOUS les serveurs dédiés du compte
    # (`GET /dedicated/server`). Sert à `beryl scan --discover`.
    def dedicated_server_names : Array(String)
      client.dedicated_servers.list
    end

    # Adresse IPv6 publique HÔTE du serveur (ex. "2001:41d0:250:dd00::1"),
    # dérivée du bloc `GET /dedicated/server/{s}/ips` (1ʳᵉ IP contenant ':',
    # suffixe `/64` retiré). On force le suffixe hôte `::1` : le bloc nu
    # `…dd00::` est l'anycast Subnet-Router (reste en DAD `tentative`,
    # inutilisable) — cf. primitive `netif6`. nil si aucune IPv6. Best-effort.
    def ipv6_address(service_name : String) : String?
      block = client.dedicated_servers.ips(service_name)
        .find(&.includes?(':')).try(&.split('/').first)
      return nil unless block
      block.ends_with?("::") ? "#{block}1" : block
    rescue
      nil
    end

    # `displayName` OVH du serveur (nom convivial du panel, ex. "adi"), via
    # `serviceInfos` → `serviceId` → `GET /services/{id}`. nil si non défini,
    # égal au serviceName, ou droit `GET /services/*` absent. Best-effort.
    def server_display_name(service_name : String) : String?
      infos = client.call("GET", "/dedicated/server/#{service_name}/serviceInfos")
      sid = infos.try(&.["serviceId"]?).try(&.as_i?)
      return nil unless sid
      svc = client.call("GET", "/services/#{sid}")
      name = svc.try(&.["resource"]?).try(&.["displayName"]?).try(&.as_s?) ||
             svc.try(&.["displayName"]?).try(&.as_s?)
      return nil if name.nil? || name.empty? || name == service_name
      name
    rescue
      nil
    end

    # Index { IP principale => service_name } de TOUS les serveurs dédiés du
    # compte, en UNE passe (liste + un GET par serveur). Sert au batch
    # `beryl info --refresh` : résoudre le service_name de chaque host par son
    # IP sans relister à chaque fois. Couvert par `GET /dedicated/server*`.
    def ip_to_service_index : Hash(String, String)
      idx = {} of String => String
      resp = client.call("GET", "/dedicated/server")
      return idx unless resp
      resp.as_a.each do |s|
        sn = s.as_s?
        next unless sn
        details = begin
          client.call("GET", "/dedicated/server/#{sn}")
        rescue
          next
        end
        next unless details
        if ip = details["ip"]?.try(&.as_s?)
          idx[ip] = sn
        end
      end
      idx
    end

    # --- vRack (réseau privé OVH) ---

    # Noms de service des vRacks du compte (ex. "pn-12345").
    def list_vracks : Array(String)
      resp = client.call("GET", "/vrack")
      resp ? resp.as_a.compact_map(&.as_s?) : [] of String
    end

    # Interface vRack d'un serveur (modèle vRack 2.0) : {uuid, vRack-actuel
    # ou nil}. nil si le serveur n'a aucune interface en mode `vrack`
    # (gamme sans support vRack). OVH a deux modèles : legacy
    # (`dedicatedServer`, par nom) et 2.0 (`dedicatedServerInterface`, par
    # UUID d'interface) — les serveurs récents (double NIC) sont en 2.0.
    def vrack_interface(service_name : String) : Tuple(String, String?)?
      uuids = client.call("GET", "/dedicated/server/#{service_name}/virtualNetworkInterface")
      return nil unless uuids
      uuids.as_a.each do |u|
        uuid = u.as_s?
        next unless uuid
        iface = client.call("GET", "/dedicated/server/#{service_name}/virtualNetworkInterface/#{uuid}")
        next unless iface
        mode = iface["mode"]?.try(&.as_s?) || ""
        return {uuid, iface["vrack"]?.try(&.as_s?)} if mode.includes?("vrack")
      end
      nil
    end

    # Le vRack contenant ce serveur (via son interface vRack), nil si aucun.
    def vrack_of_server(service_name : String) : String?
      vrack_interface(service_name).try(&.[1])
    end

    # Rattache le serveur au vRack (modèle interface vRack 2.0). Retourne
    # l'id de la task. Lève si le serveur n'a pas d'interface vRack.
    def attach_dedicated_server(vrack : String, service_name : String) : String
      iface = vrack_interface(service_name)
      raise "le serveur #{service_name} n'a pas d'interface vRack (gamme sans support vRack ?)" unless iface
      resp = client.call(
        "POST", "/vrack/#{vrack}/dedicatedServerInterface",
        body: {"dedicatedServerInterface" => iface[0]},
      )
      id = resp.try(&.["id"]?)
      id ? id.to_s : ""
    end

    # Statut d'une task vRack ("todo" / "doing" / "done" / "error"…). nil si
    # introuvable (souvent : la task est terminée et OVH l'a purgée).
    def vrack_task_status(vrack : String, task_id : String) : String?
      resp = client.call("GET", "/vrack/#{vrack}/task/#{task_id}")
      resp.try(&.["status"]?).try(&.as_s?)
    rescue
      nil
    end

    def available? : Bool
      ENV["OVH_APPLICATION_KEY"]? && ENV["OVH_APPLICATION_SECRET"]? && ENV["OVH_CONSUMER_KEY"]? ? true : false
    end

    def list_ssh_keys : Array(Beryl::SshKeyInfo)
      c = client
      names = c.ssh_keys.list
      names.map do |name|
        # L'API OVH oblige un GET supplémentaire par clé pour
        # récupérer le contenu. Coûteux si beaucoup de clés, mais
        # simple et suffisant pour le volume typique (1 à 5 clés).
        full = c.ssh_keys.get(name)
        Beryl::SshKeyInfo.new(id: name, name: name, public_key: full.key)
      end
    end

    # Côté YAML, OVH attend `ovh.ssh_key_name: <label>`. Le label est
    # directement le `keyName` OVH. Consommé par `beryl rescue` qui
    # passe cette valeur à `client.dedicated_servers.prepare_rescue`.
    def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
      result = {} of String => String | Array(String)
      result["ssh_key_name"] = key_id
      result
    end

    def credentials_env_vars : Array(Beryl::EnvVarSpec)
      [
        Beryl::EnvVarSpec.new(
          name: "OVH_APPLICATION_KEY",
          description: "Clé applicative (générée à l'URL d'aide)",
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_APPLICATION_SECRET",
          description: "Secret applicatif (donné une fois à la génération)",
          secret: true,
        ),
        # OVH_CONSUMER_KEY est marquée `optional` côté prompt : elle
        # n'est PAS demandée à l'utilisateur. Le hook
        # `bootstrap_credentials_if_needed` la génère automatiquement
        # via `POST /auth/credential` avec les access rules exactes,
        # une fois que APP_KEY + APP_SECRET sont dispos. L'utilisateur
        # n'a qu'à valider l'URL dans son navigateur.
        Beryl::EnvVarSpec.new(
          name: "OVH_CONSUMER_KEY",
          description: "Consumer key (générée auto par beryl init)",
          optional: true,
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_ENDPOINT",
          description: "Datacenter (eu|ca|us|kimsufi_eu|kimsufi_ca|soyoustart_eu|soyoustart_ca)",
          optional: true,
          default: "eu",
        ),
      ]
    end

    def credentials_help_url : String
      "https://eu.api.ovh.com/createApp/ (pour générer l'APP_KEY + APP_SECRET initiaux)"
    end

    # Détails affichés pendant `beryl init` : beryl génère la consumer
    # key automatiquement via `POST /auth/credential`, l'opérateur n'a
    # donc qu'à cocher « autoriser » dans le navigateur. Les routes
    # listées ci-dessous sont injectées automatiquement par le hook
    # `bootstrap_credentials_if_needed` — documentation uniquement.
    def credentials_help_details : String?
      lines = [] of String
      lines << "Beryl générera la consumer key lui-même avec ces droits :"
      required_access_rules.each { |r| lines << "  #{r[:verb].ljust(5)} #{r[:path]}" }
      lines << "Après création, ouvrez l'URL de validation dans le navigateur."
      lines.join("\n")
    end

    # Routes OVH que beryl appelle. Injectées dans la `consumer_key`
    # au moment de la création via `POST /auth/credential`. Les `*`
    # sont des wildcards supportés par OVH (pattern « tout sous ce
    # préfixe avec un / »). ATTENTION : `/me/sshKey/*` NE matche PAS
    # `/me/sshKey` nu (endpoint de liste). Il faut les deux :
    #   - `/me/sshKey`   → GET pour lister les noms de clés
    #   - `/me/sshKey/*` → GET pour récupérer le détail d'une clé
    # Même logique pour `/dedicated/server` et `/domain/zone`.
    def required_access_rules : Array({verb: String, path: String})
      [
        {verb: "GET", path: "/dedicated/server"},   # liste des serveurs
        {verb: "GET", path: "/dedicated/server/*"}, # détails + sous-routes
        {verb: "PUT", path: "/dedicated/server/*"},
        {verb: "POST", path: "/dedicated/server/*"},
        {verb: "GET", path: "/me/sshKey"},     # liste des clés SSH
        {verb: "GET", path: "/me/sshKey/*"},   # contenu d'une clé
        {verb: "GET", path: "/domain/zone"},   # liste des zones
        {verb: "GET", path: "/domain/zone/*"}, # records d'une zone
        {verb: "POST", path: "/domain/zone/*/record"},
        {verb: "PUT", path: "/domain/zone/*/record/*"},    # màj d'un record (ensure_record)
        {verb: "DELETE", path: "/domain/zone/*/record/*"}, # suppression d'un record
        {verb: "POST", path: "/domain/zone/*/refresh"},
        {verb: "PUT", path: "/ip/*/reverse"},
        {verb: "POST", path: "/ip/*/reverse"},
        {verb: "GET", path: "/services/*"}, # prix/mois (billing) + infos service
        {verb: "PUT", path: "/services/*"}, # displayName rename (avril 2026)
        {verb: "GET", path: "/vrack"},      # liste des vRacks
        {verb: "GET", path: "/vrack/*"},    # serveurs/interfaces du vRack + tasks
        {verb: "POST", path: "/vrack/*"},   # rattacher (dedicatedServer ET dedicatedServerInterface)
      ]
    end

    # Génère la consumer key OVH si absente (ou si force_regen).
    # Utilise `POST /auth/credential` du shard ovh-api 0.4.0 avec
    # la liste exacte des access rules de `required_access_rules`.
    #
    # Flux utilisateur :
    #   1. Requête API → retourne une URL de validation
    #   2. Beryl ouvre le navigateur (macOS `open`, Linux `xdg-open`)
    #   3. L'utilisateur clique « autoriser » dans OVH
    #   4. Beryl attend une confirmation (Entrée)
    #   5. La consumer_key est stockée dans env
    def bootstrap_credentials_if_needed(
      env : Hash(String, String),
      force_regen : Bool = false,
      interactive : Bool = true,
    ) : Hash(String, String)
      existing = env["OVH_CONSUMER_KEY"]?
      return env if existing && !existing.empty? && !force_regen

      app_key = env["OVH_APPLICATION_KEY"]?
      app_secret = env["OVH_APPLICATION_SECRET"]?
      endpoint = env["OVH_ENDPOINT"]? || "eu"
      if app_key.nil? || app_key.empty? || app_secret.nil? || app_secret.empty?
        raise "OVH_APPLICATION_KEY et OVH_APPLICATION_SECRET requis avant de générer la consumer key"
      end

      rules = required_access_rules.map do |r|
        OvhApi::Endpoints::AccessRule.new(method: r[:verb], path: r[:path])
      end

      STDERR.puts "[beryl init] OVH : génération d'une consumer key avec #{rules.size} access rule(s)..."
      temp_client = OvhApi::Client.new(
        application_key: app_key,
        application_secret: app_secret,
        endpoint: endpoint_symbol(endpoint),
      )
      result = temp_client.auth.request_consumer_key(rules)

      STDERR.puts "[beryl init] OVH : ouvrez cette URL dans votre navigateur pour valider :"
      STDERR.puts "             #{result.validation_url}"
      STDERR.puts "             (Après « Authorize », OVH affiche un message déconcertant"
      STDERR.puts "              « Authorize %!s(<nil>) » — c'est un bug d'affichage chez eux,"
      STDERR.puts "              la clé est bien créée et stockée par beryl.)"

      if interactive
        STDERR.print "[beryl init] OVH : Tapez Entrée une fois la clé validée côté OVH... "
        STDERR.flush
        STDIN.gets
      else
        STDERR.puts "[beryl init] OVH : --non-interactive → la clé est enregistrée telle quelle."
        STDERR.puts "             Elle sera utilisable une fois validée côté OVH."
      end

      # Interroge OVH pour confirmer la validation et afficher la
      # date d'expiration. Si l'appel échoue (clé pas encore validée,
      # API qui hoquette…), on continue — la clé est déjà stockée,
      # l'info d'expiration n'est qu'un confort.
      report_credential_expiration(app_key, app_secret, endpoint, result.consumer_key)

      updated = env.dup
      updated["OVH_CONSUMER_KEY"] = result.consumer_key
      updated
    end

    # Fait un `GET /auth/currentCredential` avec la nouvelle consumer
    # key et affiche la durée de validité restante. Silencieux sur
    # erreur (la clé peut être en `pendingValidation` si l'utilisateur
    # a tapé Entrée trop vite, l'API OVH peut hoqueter, etc.) — on ne
    # bloque pas le flux pour une info annexe.
    private def report_credential_expiration(
      app_key : String,
      app_secret : String,
      endpoint : String,
      consumer_key : String,
    ) : Nil
      signed_client = OvhApi::Client.new(
        application_key: app_key,
        application_secret: app_secret,
        consumer_key: consumer_key,
        endpoint: endpoint_symbol(endpoint),
      )
      info = signed_client.auth.current_credential
      if days = info.days_until_expiration
        date = info.expiration.not_nil!.to_s("%d/%m/%Y")
        STDERR.puts "[beryl init] OVH : consumer key valide pendant #{days} jour(s) (jusqu'au #{date})."
        STDERR.puts "             Relancez `beryl init ovh --regen-credentials` pour renouveler."
      else
        STDERR.puts "[beryl init] OVH : consumer key en validité illimitée."
      end
    rescue
      # Silencieux : info annexe, pas de friction pour l'utilisateur.
    end

    # Convertit la String `OVH_ENDPOINT` en Symbol attendu par
    # `OvhApi::Client`. Les String pures sont interprétées comme
    # URLs par le shard, donc on doit mapper explicitement les noms
    # courts vers leurs symboles.
    private def endpoint_symbol(endpoint : String) : Symbol
      case endpoint
      when "eu"            then :eu
      when "ca"            then :ca
      when "us"            then :us
      when "kimsufi_eu"    then :kimsufi_eu
      when "kimsufi_ca"    then :kimsufi_ca
      when "soyoustart_eu" then :soyoustart_eu
      when "soyoustart_ca" then :soyoustart_ca
      else
        raise "OVH_ENDPOINT invalide : #{endpoint.inspect} (eu|ca|us|kimsufi_*|soyoustart_*)"
      end
    end

    def owns?(host_name : String) : Bool
      # Quand un client est injecté (cas test), on l'utilise sans
      # vérifier `available?` (les env vars ne sont pas forcément
      # posées en spec).
      return false unless @injected_client || available?
      client.dedicated_servers.list.includes?(host_name)
    rescue
      false
    end
  end
end
