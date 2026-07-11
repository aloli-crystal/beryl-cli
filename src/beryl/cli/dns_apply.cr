require "../config"
require "../providers"
require "./credentials"
require "./dns_setup"

module Beryl::CLI
  # Cœur partagé du nommage DNS multi-provider (ADR-014), extrait de
  # `beryl dns` pour que `beryl scan --dns` ET `beryl dns` posent les
  # records EXACTEMENT de la même façon :
  #
  #   - forward A/AAAA  → via le **dns_provider** de la zone
  #     (`host.dns_provider`, ex. gandi) : `ensure_record` + `refresh_zone`.
  #   - reverse PTR     → via le **compute provider** propriétaire de l'IP
  #     (`host.provider`, ex. ovh) : `set_reverse` (Gandi ne sait pas).
  #
  # Avant l'extraction, `scan --dns` passait par `DnsSetup` (100% OVH) :
  # une zone hébergée chez Gandi (cas acme : dns_provider=gandi,
  # provider=ovh) faisait 404 « This service does not exist » sur
  # `GET /domain/zone/<zone>/record` — OVH ne connaît pas la zone
  # (constaté qsbg, 9 juin 2026). En passant par le dns_provider réel
  # de la zone, le forward marche quel que soit l'hébergeur DNS.
  #
  # La détection d'IP est compute-spécifique : OVH câblé (dédiés). Les
  # autres providers compute (scaleway/dedibox) gardent leurs propres
  # flux dans `scan` — refus explicite ici (principe : pas d'échec
  # silencieux).
  module DnsApply
    extend self

    # Issue d'une tentative de nommage. `beryl dns` la traduit en code
    # de sortie ; `scan --dns` s'en sert pour continuer en best-effort
    # (le DNS est SECONDAIRE par rapport au scan disques + write).
    enum Outcome
      Applied # forward posé (host joignable) ; secondaires éventuels en `warnings`
      DryRun  # plan affiché, aucun appel API
      Aborted # l'opérateur a refusé au prompt
      Usage   # config invalide (dns_provider manquant, IP non câblée…)
      Failed  # le forward (BLOQUANT) a échoué
    end

    # Résultat structuré. `short_name` est toujours renseigné (calculé
    # avant tout appel API) pour que `scan` puisse nommer le YAML même
    # quand le DNS échoue.
    struct Result
      getter outcome : Outcome
      getter short_name : String
      getter warnings : Array(String)

      def initialize(@outcome : Outcome, @short_name : String, @warnings : Array(String) = [] of String)
      end
    end

    # Pose / resynchronise le DNS de `host` (déjà résolu, credentials
    # déjà appliqués par l'appelant via `apply_all_credentials_to_env!`).
    #
    # `cmd` préfixe les messages (« beryl dns » ou « beryl scan ») pour
    # que la sortie reste juste selon l'appelant.
    #
    # Ne lève PAS sur un échec de forward : retourne `Outcome::Failed`.
    # L'appelant décide si c'est bloquant (`beryl dns`) ou best-effort
    # (`scan --dns`).
    # Pose le forward A/AAAA via le dns_provider RÉEL de la zone
    # (`host.dns_provider`), puis refresh. C'est la brique multi-provider
    # du forward, partagée : `for_host` l'utilise pour le chemin OVH, et
    # les flux compute-spécifiques de `scan` (scaleway/dedibox, qui font
    # leur propre détection d'IP) l'appellent au lieu de hardcoder OVH.
    #
    # Lève si `dns_provider` est absent / sans capability `:dns`, ou sur
    # échec d'un `ensure_record` — l'appelant décide du caractère bloquant
    # (dans `scan`, tout le DNS est best-effort).
    def forward_via_dns_provider(
      host : Beryl::Config::ResolvedHost,
      zone : String,
      short : String,
      ipv4 : String,
      ipv6 : String?,
      log : Proc(String, Nil),
    ) : Nil
      dns_provider_name = host.dns_provider
      if dns_provider_name.nil? || dns_provider_name.empty?
        raise "aucun `dns_provider` pour #{host.fqdn} (déclarez-le dans le .domain.yml)"
      end
      dns_prov = Beryl::Providers.find(dns_provider_name)
      unless dns_prov && dns_prov.capable_of?(:dns)
        raise "`#{dns_provider_name}` n'est pas un DNS provider (capability :dns absente)"
      end
      # `capable_of?(:dns)` garantit l'inclusion du mixin → cast sûr.
      fwd = dns_prov.as(Beryl::DnsProvider)
      fwd.ensure_record(zone, "A", short, ipv4)
      log.call("✓ A    #{short}.#{zone} → #{ipv4} (#{dns_provider_name})")
      if v6 = ipv6
        fwd.ensure_record(zone, "AAAA", short, v6)
        log.call("✓ AAAA #{short}.#{zone} → #{v6} (#{dns_provider_name})")
      end
      fwd.refresh_zone(zone)
    end

    def for_host(
      host : Beryl::Config::ResolvedHost,
      hostname_flag : String?,
      zone_flag : String?,
      dry_run : Bool,
      non_interactive : Bool,
      cmd : String = "beryl dns",
    ) : Result
      short : String = hostname_flag || host.fqdn.split('.').first
      zone : String = zone_flag || host.domain_name
      fqdn = "#{short}.#{zone}"

      # --- résolution des providers ---------------------------------------
      dns_provider_name = host.dns_provider
      if dns_provider_name.nil? || dns_provider_name.empty?
        STDERR.puts "#{cmd} : aucun `dns_provider` pour #{host.fqdn} (déclarez-le dans le .domain.yml)."
        return Result.new(Outcome::Usage, short)
      end
      compute_provider_name = host.provider
      if compute_provider_name.nil? || compute_provider_name.empty?
        STDERR.puts "#{cmd} : aucun `provider` (compute) pour #{host.fqdn}."
        return Result.new(Outcome::Usage, short)
      end

      dns_prov = Beryl::Providers.find(dns_provider_name)
      unless dns_prov && dns_prov.capable_of?(:dns)
        STDERR.puts "#{cmd} : `#{dns_provider_name}` n'est pas un DNS provider (capability :dns absente)."
        return Result.new(Outcome::Usage, short)
      end
      compute_prov = Beryl::Providers.find(compute_provider_name)
      unless compute_prov
        STDERR.puts "#{cmd} : provider compute `#{compute_provider_name}` inconnu."
        return Result.new(Outcome::Usage, short)
      end

      # --- détection d'IP (compute-spécifique : OVH pour l'instant) -------
      unless compute_provider_name == "ovh"
        STDERR.puts "#{cmd} : détection d'IP non câblée pour provider=#{compute_provider_name} " \
                    "(OVH seulement aujourd'hui). Scaleway/Dedibox à venir."
        return Result.new(Outcome::Usage, short)
      end
      maybe_service = host.ovh_service_name
      if maybe_service.nil?
        STDERR.puts "#{cmd} : host OVH sans `ovh.service_name`."
        return Result.new(Outcome::Usage, short)
      end
      service_name = maybe_service.not_nil!

      log = ->(m : String) { STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [#{cmd}] #{m}"; nil }

      ovh = Beryl::CLI::Credentials.ovh_client
      plan = Beryl::CLI::DnsSetup.build_plan(ovh, service_name, short, zone)
      ipv4 = plan.ipv4
      ipv6 = plan.ipv6

      # --- plan ------------------------------------------------------------
      STDERR.puts
      STDERR.puts "Plan DNS pour #{fqdn}"
      STDERR.puts "─" * 60
      # Labels « action (provider) » alignés sur la plus longue → les `:`
      # tombent en colonne, même si dns_provider ≠ compute_provider.
      fwd = "forward (#{dns_provider_name})"
      rev = "reverse (#{compute_provider_name})"
      w = [fwd.size, rev.size].max
      STDERR.puts "  #{fwd.ljust(w)} : A    #{short}.#{zone}  →  #{ipv4}"
      STDERR.puts "  #{fwd.ljust(w)} : AAAA #{short}.#{zone}  →  #{ipv6}" if ipv6
      STDERR.puts "  #{rev.ljust(w)} : #{ipv4}  →  #{fqdn}"
      STDERR.puts "  #{rev.ljust(w)} : #{ipv6}  →  #{fqdn}" if ipv6
      STDERR.puts "─" * 60

      if dry_run
        STDERR.puts "DRY-RUN : aucun appel API effectué."
        return Result.new(Outcome::DryRun, short)
      end
      unless non_interactive
        STDERR.print "Exécuter ces actions ? [o/N] : "
        ans = (gets || "").strip.downcase
        unless ans.starts_with?("o") || ans.starts_with?("y")
          STDERR.puts "Abandon."
          return Result.new(Outcome::Aborted, short)
        end
      end

      # `ensure_record`/`refresh_zone`/`set_reverse` vivent sur le mixin
      # DnsProvider. `Providers.find` rend `Provider+` → on caste après le
      # check de capability (`capable_of?(:dns)` garantit l'inclusion).
      dns_fwd = dns_prov.as(Beryl::DnsProvider)

      # --- exécution (résiliente par étape) --------------------------------
      # Le FORWARD est le but principal (host joignable par son nom) → un
      # échec là est bloquant. Le reverse est secondaire : ses échecs sont
      # collectés mais n'annulent pas le reste (ex. le reverse IPv6 OVH peut
      # 404 si l'IP devinée n'est pas la bonne).
      warnings = [] of String

      # 1. forward via le dns_provider de la zone (BLOQUANT)
      begin
        dns_fwd.ensure_record(zone, "A", short, ipv4)
        log.call("✓ A    #{fqdn} → #{ipv4}")
        if v6 = ipv6
          dns_fwd.ensure_record(zone, "AAAA", short, v6)
          log.call("✓ AAAA #{fqdn} → #{v6}")
        end
        dns_fwd.refresh_zone(zone)
      rescue ex
        STDERR.puts "#{cmd} : échec du forward (#{dns_provider_name}) — #{ex.message}"
        return Result.new(Outcome::Failed, short)
      end

      # 2. reverse via le compute provider (best-effort, propriétaire de l'IP)
      if compute_prov.capable_of?(:dns)
        rev = compute_prov.as(Beryl::DnsProvider)
        begin
          rev.set_reverse(ipv4, fqdn)
          log.call("✓ reverse #{ipv4} → #{fqdn}")
        rescue ex
          if reverse_already_set?(ex)
            log.call("✓ reverse #{ipv4} → #{fqdn} (déjà posé)")
          else
            warnings << "reverse IPv4 (#{compute_provider_name}) : #{ex.message}"
          end
        end
        if v6 = ipv6
          begin
            rev.set_reverse(v6, fqdn)
            log.call("✓ reverse #{v6} → #{fqdn}")
          rescue ex
            if reverse_already_set?(ex)
              log.call("✓ reverse #{v6} → #{fqdn} (déjà posé)")
            else
              warnings << "reverse IPv6 (#{compute_provider_name}) : #{ex.message}"
            end
          end
        end
      else
        warnings << "reverse non posé : `#{compute_provider_name}` n'expose pas le reverse DNS."
      end

      # --- bilan -----------------------------------------------------------
      if warnings.empty?
        log.call("terminé : #{fqdn} (forward + reverse)")
      else
        STDERR.puts
        STDERR.puts "#{cmd} : forward DNS posé ✓, mais des étapes SECONDAIRES ont échoué :"
        warnings.each { |msg| STDERR.puts "  ⚠ #{msg}" }
        STDERR.puts "  (Le host reste joignable par son nom — ces étapes sont secondaires.)"
        STDERR.puts "  → pour rejouer le reverse quand l'API répond : beryl dns #{fqdn}"
      end
      Result.new(Outcome::Applied, short, warnings)
    end

    # Vrai si l'exception est un « reverse déjà posé à la bonne valeur » :
    # OVH renvoie HTTP 409 « … is already setted » quand le reverse demandé
    # est DÉJÀ celui en place (le message inclut le reverse voulu). C'est
    # idempotent → succès, pas un échec.
    def self.reverse_already_set?(ex : Exception) : Bool
      msg = ex.message || ""
      msg.includes?("already setted") || msg.includes?("already set")
    end
  end
end
