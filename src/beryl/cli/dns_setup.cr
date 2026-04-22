require "ovh-api/ovh_api"

# Met en place les informations de nommage d'un serveur OVH fraîchement
# reçu pour qu'on puisse ensuite l'appeler par son nom custom et oublier
# son service_name OVH :
#
#   1. Enregistrements A + AAAA dans la zone DNS custom (ex. aloli.net)
#   2. Refresh de la zone (OVH l'exige pour propager)
#   3. Reverse DNS sur IPv4 + IPv6 → FQDN custom
#   4. Renommage du « display name » du serveur côté panel OVH
#
# Le shard `ovh-api` couvre (3). Les autres endpoints (zone records,
# zone refresh, update du displayName) passent par `OvhApi::Client#call`
# en bas niveau — ça évite de publier une release du shard pour chaque
# ajout de feature côté beryl.
#
# Toutes les actions sont idempotentes côté beryl : avant de créer un
# record, on vérifie qu'il n'existe pas déjà. Un relancement après
# interruption ne crée pas de doublons.
module Beryl::CLI::DnsSetup
  # Plan d'actions calculé à partir des infos du serveur + choix de
  # l'utilisateur. Exposé pour qu'on puisse l'afficher à l'opérateur
  # avant confirmation.
  struct Plan
    getter service_name : String
    getter fqdn : String       # ex. loulou.aloli.net
    getter short_name : String # ex. loulou
    getter zone : String       # ex. aloli.net
    getter ipv4 : String
    getter ipv6 : String?
    getter current_display_name : String?

    def initialize(@service_name, @fqdn, @short_name, @zone, @ipv4, @ipv6, @current_display_name)
    end

    # Rend le plan en lignes numérotées pour l'affichage console.
    def describe : String
      String.build do |io|
        io << "Actions DNS + OVH prévues pour #{@service_name} :\n"
        io << "  1. Créer (ou vérifier) A     #{@short_name}.#{@zone}  →  #{@ipv4}\n"
        if @ipv6
          io << "  2. Créer (ou vérifier) AAAA  #{@short_name}.#{@zone}  →  #{@ipv6}\n"
        else
          io << "  2. AAAA : aucun IPv6 détecté sur le serveur, ignoré\n"
        end
        io << "  3. Rafraîchir la zone #{@zone}\n"
        io << "  4. Reverse DNS IPv4 : #{@ipv4} → #{@fqdn}.\n"
        if @ipv6
          io << "  5. Reverse DNS IPv6 : #{@ipv6} → #{@fqdn}.\n"
        end
        if @current_display_name == @fqdn
          io << "  6. displayName OVH déjà à #{@fqdn}, rien à faire\n"
        else
          io << "  6. Renommer OVH : "
          io << (@current_display_name.try(&.empty?) != false ? "(aucun)" : @current_display_name.not_nil!)
          io << "  →  #{@fqdn}\n"
        end
      end
    end
  end

  # Récupère les infos nécessaires (IPs, displayName actuel) pour
  # construire un Plan cohérent.
  #
  # `/dedicated/server/{svc}` renvoie `{name, ip, reverse, datacenter, ...}`.
  # `/dedicated/server/{svc}/ips` renvoie une liste d'IPs (v4 + v6).
  # On pioche la v6 dans la liste ; s'il n'y en a pas, on continue sans.
  def self.build_plan(
    client : OvhApi::Client,
    service_name : String,
    short_name : String,
    zone : String,
  ) : Plan
    server_info = client.call("GET", "/dedicated/server/#{service_name}")
    raise "API OVH : /dedicated/server/#{service_name} a renvoyé vide" unless server_info

    ipv4 = server_info["ip"]?.try(&.as_s) || raise "aucune IPv4 déclarée sur #{service_name}"
    display_name = server_info["name"]?.try(&.as_s)

    # Liste des IPs affectées au serveur. On cherche la première v6.
    # Format des IPs dans l'API : "51.83.6.X/32" pour v4, "2001:...::/64"
    # pour v6.
    ipv6 = nil
    ips_any = client.call("GET", "/dedicated/server/#{service_name}/ips")
    if ips_any
      ips_any.as_a.each do |ip_any|
        s = ip_any.as_s
        next unless s.includes?(':')
        # Extrait la partie IP du bloc CIDR.
        base = s.split('/').first
        # Convention OVH : l'IP usable = base + "1" si bloc /64.
        ipv6 = derive_ipv6_address(base, s)
        break
      end
    end

    fqdn = "#{short_name}.#{zone}"
    Plan.new(service_name, fqdn, short_name, zone, ipv4, ipv6, display_name)
  end

  # À partir d'un bloc CIDR IPv6 (ex. "2001:41d0:2:6e01::/64"), déduit
  # l'adresse usable habituelle chez OVH : base + "::1".
  def self.derive_ipv6_address(base : String, cidr : String) : String
    # Si le bloc se termine par ::/64, l'IP usable standard OVH est
    # ::1 (ou plutôt l'adresse que le serveur utilise effectivement).
    # Faute d'info précise, on pose ::1 qui marche dans 99% des cas.
    if cidr.ends_with?("/64") && base.ends_with?("::")
      base + "1"
    else
      base
    end
  end

  # Exécute le plan. Chaque étape est idempotente.
  def self.apply!(client : OvhApi::Client, plan : Plan, logger : Proc(String, Nil)) : Nil
    ensure_record(client, plan.zone, "A", plan.short_name, plan.ipv4, logger)
    if v6 = plan.ipv6
      ensure_record(client, plan.zone, "AAAA", plan.short_name, v6, logger)
    end
    refresh_zone(client, plan.zone, logger)
    set_reverse_if_needed(client, plan.ipv4, plan.fqdn, logger)
    if v6 = plan.ipv6
      set_reverse_if_needed(client, v6, plan.fqdn, logger)
    end
    update_display_name(client, plan.service_name, plan.fqdn, logger) unless plan.current_display_name == plan.fqdn
  end

  # Crée un record (A ou AAAA) s'il n'existe pas déjà avec la même
  # cible. S'il existe avec une cible différente, on le met à jour.
  def self.ensure_record(
    client : OvhApi::Client,
    zone : String,
    field_type : String,
    sub_domain : String,
    target : String,
    logger : Proc(String, Nil),
  ) : Nil
    # Liste des record IDs pour ce subdomain + fieldType.
    existing = client.call("GET", "/domain/zone/#{zone}/record",
      query: {"fieldType" => field_type, "subDomain" => sub_domain})
    ids = existing ? existing.as_a.map(&.as_i64) : [] of Int64

    ids.each do |id|
      rec = client.call("GET", "/domain/zone/#{zone}/record/#{id}")
      next unless rec
      current_target = rec["target"]?.try(&.as_s)
      if current_target == target
        logger.call("#{field_type} #{sub_domain}.#{zone} → #{target} déjà en place (id=#{id}), rien à faire")
        return
      else
        logger.call("#{field_type} #{sub_domain}.#{zone} : mise à jour #{current_target} → #{target} (id=#{id})")
        client.call("PUT", "/domain/zone/#{zone}/record/#{id}",
          body: {"target" => target})
        return
      end
    end

    logger.call("création #{field_type} #{sub_domain}.#{zone} → #{target}")
    client.call("POST", "/domain/zone/#{zone}/record",
      body: {
        "fieldType" => field_type,
        "subDomain" => sub_domain,
        "target"    => target,
      })
  end

  def self.refresh_zone(client : OvhApi::Client, zone : String, logger : Proc(String, Nil)) : Nil
    logger.call("refresh zone #{zone}")
    client.call("POST", "/domain/zone/#{zone}/refresh")
  end

  # Pose le reverse DNS. L'API OVH exige l'IP en forme « ipBlock » dans
  # le path et l'IP précise dans le body (utile quand on a un bloc avec
  # plusieurs IPs).
  def self.set_reverse_if_needed(
    client : OvhApi::Client,
    ip : String,
    reverse : String,
    logger : Proc(String, Nil),
  ) : Nil
    # Le format attendu : reverse doit finir par un point.
    target = reverse.ends_with?(".") ? reverse : "#{reverse}."

    # On ne connaît pas le bloc exact (v4 = /32, v6 = /64). Dans l'API
    # OVH, l'endpoint /ip/{ip}/reverse accepte soit l'IP nue (v4) soit
    # le bloc (v6). Le shard ovh-api gère déjà cette subtilité.
    client.ips.set_reverse(ip: ip, reverse: target, ip_reverse: ip)
    logger.call("reverse DNS posé : #{ip} → #{target}")
  rescue ex : OvhApi::Error
    # Si le reverse est déjà posé à la bonne valeur, OVH peut lever une
    # erreur « déjà à cette valeur ». On tolère.
    if ex.message.to_s.downcase.includes?("already") || ex.message.to_s.downcase.includes?("existe")
      logger.call("reverse DNS déjà en place pour #{ip}, rien à faire")
    else
      raise ex
    end
  end

  def self.update_display_name(
    client : OvhApi::Client,
    service_name : String,
    new_name : String,
    logger : Proc(String, Nil),
  ) : Nil
    logger.call("renomme displayName OVH : #{service_name} → #{new_name}")
    client.call("PUT", "/dedicated/server/#{service_name}",
      body: {"displayName" => new_name})
  end
end
