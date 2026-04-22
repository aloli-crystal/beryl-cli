require "ovh-api/ovh_api"

# Met en place les informations de nommage d'un serveur OVH fraîchement
# reçu pour qu'on puisse ensuite l'appeler par son nom custom et oublier
# son service_name OVH :
#
#   1. Record A dans la zone DNS custom (ex. aloli.net) pointant
#      directement vers l'IPv4 du serveur.
#   2. Record AAAA dans la même zone pointant vers l'IPv6 (si IPv6
#      détectée, sinon étape ignorée).
#   3. Refresh de la zone (OVH l'exige pour propager).
#   4. Reverse DNS sur IPv4 + IPv6 → FQDN custom (loulou.aloli.net.).
#      Les deux reverses pointent vers le MÊME FQDN, pas des variantes
#      type loulou-v4/loulou-v6.
#   5. Renommage du « display name » du serveur côté panel OVH.
#
# Philippe 22 avril 2026 (terrain) :
#   « Dans la zone aloli.net : deux CNAME ipv4 et ipv6 [A + AAAA en
#    fait]. Chez OVH le reverse est un champs le FQDN. Donc deux CNAME
#    dans la zone et un seul (FQDN) chez OVH. »
#
# Route choisie vs CNAME-vers-service_name : poser A + AAAA en direct
# signifie que le FQDN custom reste valide même si OVH change le
# service_name ou si la résolution de leur zone a un hoquet. En
# contrepartie il faut mettre à jour aloli.net si l'IP du serveur
# change — ce qui ne se produit pas sans intervention manuelle.
#
# Implémentation : 100% via le shard ovh-api 0.3.0 qui expose
# `client.domains` (records, refresh, ensure_record idempotent),
# `client.dedicated_servers.update(display_name:)` et `client.ips.set_reverse`.
# Plus aucun `client.call("GET", "/domain/...")` en bas niveau.
#
# Toutes les actions sont idempotentes côté shard : avant de créer un
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
        if v6 = @ipv6
          io << "  2. Créer (ou vérifier) AAAA  #{@short_name}.#{@zone}  →  #{v6}\n"
        else
          io << "  2. AAAA : aucune IPv6 détectée, ignoré\n"
        end
        io << "  3. Rafraîchir la zone #{@zone}\n"
        io << "  4. Reverse DNS IPv4 : #{@ipv4} → #{@fqdn}.\n"
        if v6 = @ipv6
          io << "  5. Reverse DNS IPv6 : #{v6} → #{@fqdn}.\n"
        else
          io << "  5. Reverse IPv6 : aucune IPv6 détectée, ignoré\n"
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
  # construire un Plan cohérent. Utilise `client.dedicated_servers.info`
  # et `client.dedicated_servers.ips` du shard ovh-api 0.3.0.
  def self.build_plan(
    client : OvhApi::Client,
    service_name : String,
    short_name : String,
    zone : String,
  ) : Plan
    server_info = client.dedicated_servers.info(service_name)
    ipv4 = server_info["ip"]?.try(&.as_s) || raise "aucune IPv4 déclarée sur #{service_name}"
    display_name = server_info["name"]?.try(&.as_s)

    # Liste des IPs affectées au serveur. On cherche la première v6.
    # Format des IPs : "51.83.6.X/32" pour v4, "2001:...::/64" pour v6.
    ipv6 = nil
    client.dedicated_servers.ips(service_name).each do |cidr|
      next unless cidr.includes?(':')
      base = cidr.split('/').first
      ipv6 = derive_ipv6_address(base, cidr)
      break
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
  #
  # L'ordre est important : on pose A + AAAA et on refresh la zone
  # AVANT le reverse. Si OVH valide le reverse en vérifiant que le
  # forward pointe bien vers la bonne IP, la zone doit être déjà à
  # jour. Même logique pour le displayName : on le change en dernier,
  # une fois que le FQDN custom est complètement fonctionnel.
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

  # Crée / met à jour / laisse en place un record DNS de façon
  # idempotente. Logique portée dans le shard ovh-api 0.3.0 via
  # `client.domains.ensure_record`.
  def self.ensure_record(
    client : OvhApi::Client,
    zone : String,
    field_type : String,
    sub_domain : String,
    target : String,
    logger : Proc(String, Nil),
  ) : Nil
    logger.call("#{field_type} #{sub_domain}.#{zone} → #{target} (ensure idempotent)")
    client.domains.ensure_record(zone, field_type, sub_domain, target)
  end

  def self.refresh_zone(client : OvhApi::Client, zone : String, logger : Proc(String, Nil)) : Nil
    logger.call("refresh zone #{zone}")
    client.domains.refresh(zone)
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
    client.dedicated_servers.update(service_name, display_name: new_name)
  end
end
