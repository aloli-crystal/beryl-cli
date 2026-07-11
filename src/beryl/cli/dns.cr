require "option_parser"
require "./dns_apply"
require "./account_utils"

module Beryl::CLI
  # `beryl dns <host>` — pose / resynchronise les enregistrements DNS d'un
  # host DÉJÀ déclaré, indépendamment du scan. À lancer quand on a oublié
  # `scan --dns`, après un changement d'IP, ou pour reposer un reverse.
  #
  # MULTI-PROVIDER (ADR-014) — découple le DNS du compute :
  #   - forward A/AAAA  → via le **dns_provider** de la zone
  #     (`host.dns_provider`, ex. gandi) : `ensure_record` + `refresh_zone`.
  #   - reverse PTR     → via le **compute provider** propriétaire de l'IP
  #     (`host.provider`, ex. ovh) : `set_reverse` (Gandi ne sait pas).
  #   - rename panel    → via le compute provider (OVH displayName).
  #
  # La détection d'IP est compute-spécifique : OVH câblé (dédiés). Les
  # autres providers compute (scaleway/dedibox) suivront — refus explicite
  # d'ici là (principe : pas d'échec silencieux).
  module Dns
    EXIT_OK      =  0
    EXIT_USAGE   =  2
    EXIT_ABORTED =  6
    EXIT_RUNTIME = 10

    def self.run(config_root : String, args : Array(String)) : Int32
      dry_run = true
      non_interactive = false
      hostname_flag : String? = nil
      zone_flag : String? = nil
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: beryl dns <host> [options]\n\n" \
                   "Pose les records DNS d'un host : forward (A/AAAA) via le dns_provider\n" \
                   "de la zone, reverse (PTR) + rename via le compute provider."
        p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
        p.on("-H NAME", "--hostname=NAME", "Nom court (défaut : nom du host)") { |v| hostname_flag = v }
        p.on("-z ZONE", "--zone=ZONE", "Zone DNS (défaut : le domaine du host)") { |v| zone_flag = v }
        p.on("-a ACCOUNT", "--account=ACCOUNT", "Société (sinon déduite du chemin host)") { |v| account_hint = v }
        p.on("-d DOMAIN", "--domain=DOMAIN", "Domaine (sinon déduit)") { |v| domain_hint = v }
        p.on("-N", "--non-interactive", "Refuse toute invite (suppose oui)") { non_interactive = true }
        p.on("-h", "--help", "Affiche cette aide") { puts p; exit(0) }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      raw = positional.first?
      unless raw
        STDERR.puts "beryl dns : hôte non précisé. USAGE : beryl dns <société>/<host> [-n]"
        return EXIT_USAGE
      end
      parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
      host_name = parsed[:host]
      account_hint ||= parsed[:account]
      domain_hint ||= parsed[:domain]

      root = Beryl::Config::Root.load(config_root)
      host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)
      host.apply_all_credentials_to_env!

      # Cœur partagé avec `scan --dns` (voir Beryl::CLI::DnsApply) : forward
      # via le dns_provider de la zone, reverse + rename via le compute.
      result = Beryl::CLI::DnsApply.for_host(host, hostname_flag, zone_flag, dry_run, non_interactive)
      case result.outcome
      in DnsApply::Outcome::Usage   then EXIT_USAGE
      in DnsApply::Outcome::Aborted then EXIT_ABORTED
      in DnsApply::Outcome::Failed  then EXIT_RUNTIME
      in DnsApply::Outcome::DryRun  then EXIT_OK
      in DnsApply::Outcome::Applied then EXIT_OK
      end
    end
  end
end
