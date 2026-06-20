require "option_parser"
require "./dns_apply"
require "./dns_setup"
require "./credentials"
require "./account_utils"
require "../config"

module Beryl::CLI
  # `beryl dns-alias <host> --name <label>` — pose un ALIAS DNS A/AAAA pointant
  # `<label>.<zone>` vers l'IP du host, via le dns_provider de la zone. FORWARD
  # SEUL : pas de reverse PTR, pas de rename panel (≠ `beryl dns`, qui pose le
  # record CANONIQUE du host). Un alias est un nom de service, pas l'identité du
  # host — on ne veut donc pas toucher au reverse de l'IP.
  #
  # Cas d'usage principal : FAILOVER Headscale. Après promotion d'un standby,
  # l'opérateur repointe `headscale.<zone>` vers le serveur promu :
  #
  #   beryl dns-alias zstandby.aloli.net --name headscale
  #
  # Réduit le RTO du failover (cf. roadmap headscale + doc headscale-setup.adoc :
  # « mettre à jour le DNS headscale.aloli.net »). Généralement utile pour tout
  # alias de service (smtp, db, …) pointant vers un host.
  module DnsAlias
    EXIT_OK      =  0
    EXIT_USAGE   =  2
    EXIT_RUNTIME = 10

    def self.run(config_root : String, args : Array(String)) : Int32
      name_flag : String? = nil
      zone_flag : String? = nil
      account_hint : String? = nil
      domain_hint : String? = nil
      dry_run = false
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl dns-alias <host> --name <label> [options]\n\n" \
                   "Pose un alias DNS A/AAAA `<label>.<zone>` → IP du host (forward seul,\n" \
                   "sans reverse ni rename). Ex. failover Headscale : --name headscale."
        p.on("--name=LABEL", "Label de l'alias (REQUIS ; ex. headscale)") { |v| name_flag = v }
        p.on("-z ZONE", "--zone=ZONE", "Zone DNS (défaut : domaine du host)") { |v| zone_flag = v }
        p.on("-a ACCOUNT", "--account=ACCOUNT", "Société (sinon déduite)") { |v| account_hint = v }
        p.on("-d DOMAIN", "--domain=DOMAIN", "Domaine (sinon déduit)") { |v| domain_hint = v }
        p.on("-n", "--dry-run", "Affiche le plan sans appel API") { dry_run = true }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      raw = positional.first?
      unless raw
        STDERR.puts "beryl dns-alias : host non précisé. USAGE : beryl dns-alias <host> --name <label>"
        return EXIT_USAGE
      end
      label = name_flag
      if label.nil? || label.empty?
        STDERR.puts "beryl dns-alias : `--name <label>` requis (ex. --name headscale)."
        return EXIT_USAGE
      end

      parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
      host_name = parsed[:host]
      account_hint ||= parsed[:account]
      domain_hint ||= parsed[:domain]

      root = Beryl::Config::Root.load(config_root)
      host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

      zone = zone_flag || host.domain_name
      if zone.nil? || zone.empty?
        STDERR.puts "beryl dns-alias : zone indéterminée (ni --zone ni domaine du host) — précisez --zone."
        return EXIT_USAGE
      end
      cmd = "beryl dns-alias"
      log = ->(m : String) { STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [#{cmd}] #{m}"; nil }

      dns_provider_name = host.dns_provider
      if dns_provider_name.nil? || dns_provider_name.empty?
        STDERR.puts "#{cmd} : aucun `dns_provider` pour #{host.fqdn} (déclarez-le dans le .domain.yml)."
        return EXIT_USAGE
      end

      # Détection d'IP (OVH uniquement aujourd'hui) — MÊME logique que
      # DnsApply#for_host, volontairement DUPLIQUÉE ici pour ne pas modifier le
      # `beryl dns` éprouvé en prod. À factoriser si une 3ᵉ commande la réclame.
      compute = host.provider
      unless compute == "ovh"
        STDERR.puts "#{cmd} : détection d'IP non câblée pour provider=#{compute} (OVH seulement aujourd'hui)."
        return EXIT_USAGE
      end
      service = host.ovh_service_name
      if service.nil?
        STDERR.puts "#{cmd} : host OVH sans `ovh.service_name`."
        return EXIT_USAGE
      end

      if dry_run
        STDERR.puts
        STDERR.puts "Plan dns-alias pour #{label}.#{zone}"
        STDERR.puts "─" * 60
        STDERR.puts "  A/AAAA  #{label}.#{zone} → IP de #{host.fqdn}  (#{dns_provider_name})"
        STDERR.puts "  détection d'IP live OVH + ensure_record + refresh_zone (au run réel)."
        STDERR.puts "  PAS de reverse PTR, PAS de rename panel (≠ beryl dns)."
        return EXIT_OK
      end

      ovh = Beryl::CLI::Credentials.ovh_client
      plan = Beryl::CLI::DnsSetup.build_plan(ovh, service, label, zone)
      ipv4 = plan.ipv4
      ipv6 = plan.ipv6

      begin
        Beryl::CLI::DnsApply.forward_via_dns_provider(host, zone, label, ipv4, ipv6, log)
      rescue ex
        STDERR.puts "#{cmd} : échec du forward (#{dns_provider_name}) — #{ex.message}"
        return EXIT_RUNTIME
      end
      log.call("alias #{label}.#{zone} posé → #{ipv4}#{ipv6 ? " / #{ipv6}" : ""}")
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
    rescue ex
      STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
      EXIT_RUNTIME
    end
  end
end
