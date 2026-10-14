require "option_parser"
require "socket"
require "../config"
require "../providers"
require "./account_utils"

module Beryl::CLI
  # `beryl dns-record <zone> <sous-domaine> <TYPE> <cible>` — pose (ou corrige)
  # UN enregistrement DNS quelconque dans une zone gérée par beryl, via le
  # `dns_provider` déclaré pour ce domaine et les identifiants du coffre de
  # la société propriétaire. Complète `beryl dns` (enregistrements CANONIQUES
  # d'un host) et `beryl dns-alias` (alias A/AAAA vers un host) pour tout le
  # reste : CNAME de validation ACME, TXT de vérification, MX…
  #
  #   beryl dns-record aloli.net _acme-challenge.pkg CNAME _acme-challenge.pkg.quimeo.net
  #   beryl dns-record example.net @ TXT "v=spf1 -all"
  #
  # Idempotent (`ensure_record` : rien si l'enregistrement existe déjà avec
  # cette cible, mise à jour si la cible diffère), puis rafraîchit la zone.
  # Simulation par défaut, `--apply` pour exécuter.
  module DnsRecord
    EXIT_OK      =  0
    EXIT_USAGE   =  2
    EXIT_RUNTIME = 10

    TYPES = %w[A AAAA CNAME MX TXT]

    def self.run(config_root : String, args : Array(String)) : Int32
      account_hint : String? = nil
      dry_run = true
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl dns-record <zone> <sous-domaine|@> <#{TYPES.join("|")}> <cible> [options]\n\n" \
                   "Pose un enregistrement DNS dans une zone gérée par beryl (dns_provider du\n" \
                   "domaine, identifiants de la société). `@` = sommet de la zone."
        p.on("-a ACCOUNT", "--account=ACCOUNT", "Société propriétaire de la zone (si plusieurs la déclarent)") { |v| account_hint = v }
        p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      unless positional.size == 4
        STDERR.puts "beryl dns-record : 4 arguments attendus (zone, sous-domaine, type, cible). Voir `beryl dns-record --help`."
        return EXIT_USAGE
      end
      zone, raw_sub, raw_type, raw_target = positional
      type = raw_type.upcase
      sub = sub_domain(raw_sub)
      target = normalize_target(type, raw_target)

      root = Beryl::Config::Root.load(config_root)
      owners = root.accounts.values.select { |a| a.domain?(zone) }
      owners = owners.select { |a| a.name == account_hint } if account_hint
      if owners.empty?
        STDERR.puts "beryl dns-record : zone #{zone} inconnue#{account_hint ? " pour #{account_hint}" : ""} (aucune société ne déclare ce domaine)."
        return EXIT_USAGE
      end
      if owners.size > 1
        STDERR.puts "beryl dns-record : zone #{zone} déclarée par #{owners.map(&.name).join(", ")} — précisez --account."
        return EXIT_USAGE
      end
      account = owners.first
      domain = account.domain?(zone).not_nil!
      provider_name = domain.raw[YAML::Any.new("dns_provider")]?.try(&.as_s?)
      if provider_name.nil? || provider_name.empty?
        STDERR.puts "beryl dns-record : aucun `dns_provider` déclaré pour #{zone} (#{domain.source_path})."
        return EXIT_USAGE
      end

      fqdn = sub.empty? ? zone : "#{sub}.#{zone}"
      STDERR.puts
      STDERR.puts "Plan dns-record (#{account.name}, #{provider_name})"
      STDERR.puts "─" * 60
      STDERR.puts "  #{type.ljust(5)} #{fqdn} → #{target}"
      STDERR.puts "─" * 60
      if dry_run
        STDERR.puts "DRY-RUN : aucun appel API effectué. Ajoutez --apply pour exécuter."
        return EXIT_OK
      end

      provider = Beryl::Providers.find(provider_name)
      unless provider && provider.capable_of?(:dns)
        STDERR.puts "beryl dns-record : `#{provider_name}` n'est pas un DNS provider (capability :dns absente)."
        return EXIT_USAGE
      end
      root.env_file.apply_all_to_env(account.name, overwrite: true)
      dns = provider.as(Beryl::DnsProvider)
      dns.ensure_record(zone, type, sub, target)
      dns.refresh_zone(zone)
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl dns-record] ✓ #{type} #{fqdn} → #{target} (zone #{zone} rafraîchie)"
      EXIT_OK
    rescue ex : ArgumentError
      STDERR.puts "beryl dns-record : #{ex.message}"
      EXIT_USAGE
    rescue ex
      STDERR.puts "beryl dns-record : échec — #{ex.class}: #{ex.message}"
      EXIT_RUNTIME
    end

    # Sous-domaine relatif à la zone : `@` (ou vide) = sommet de la zone.
    def self.sub_domain(raw : String) : String
      s = raw.strip
      s == "@" ? "" : s
    end

    # Valide la cible selon le type et la normalise : une cible CNAME ou MX
    # est un nom ABSOLU, d'où le point final ajouté s'il manque (sinon la
    # zone le compléterait : `x.example.net.zone.`). Lève `ArgumentError`.
    def self.normalize_target(type : String, raw : String) : String
      t = raw.strip
      raise ArgumentError.new("type #{type} non géré (types : #{TYPES.join(", ")})") unless TYPES.includes?(type)
      raise ArgumentError.new("cible vide") if t.empty?
      case type
      when "A"
        raise ArgumentError.new("#{t} n'est pas une adresse IPv4") unless Socket::IPAddress.valid_v4?(t)
        t
      when "AAAA"
        raise ArgumentError.new("#{t} n'est pas une adresse IPv6") unless Socket::IPAddress.valid_v6?(t)
        t
      when "CNAME"
        t.ends_with?('.') ? t : "#{t}."
      when "MX"
        # Format de la valeur MX : « <priorité> <serveur> ».
        parts = t.split
        unless parts.size == 2 && parts[0].to_i?
          raise ArgumentError.new("MX attendu sous la forme « <priorité> <serveur> » (ex. \"10 mx.example.net\")")
        end
        server = parts[1].ends_with?('.') ? parts[1] : "#{parts[1]}."
        "#{parts[0]} #{server}"
      else
        t
      end
    end
  end
end
