require "../primitive"

module Beryl::Apply
  # Primitive `dns-record` : pose (ou corrige) UN enregistrement DNS chez le
  # fournisseur de la zone (`dns_provider` du domaine), avec les identifiants
  # du coffre de la société — comme `beryl dns-record`, mais depuis une
  # recette : le nom d'un service vit avec la recette qui le sert.
  #
  #     - dns-record:
  #         name: connect.example.net     # nom complet, dans une zone de la société
  #         type: A                       # A, AAAA ou CNAME
  #         target: "{{ public_ip }}"     # vide → étape sautée (ex. pas d'IPv6)
  #
  # Exécutée sur le POSTE (appel d'API), pas sur l'hôte. Idempotente chez le
  # fournisseur (même cible : rien ne change) ; la zone est rafraîchie.
  class DnsRecord < Primitive
    TYPES = %w[A AAAA CNAME]

    def name : String
      "dns-record"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      fqdn = required_string(params, "name").strip.downcase.rchop('.')
      type = required_string(params, "type").strip.upcase
      target = string(params, "target").to_s.strip
      return StepResult.skipped("#{type} #{fqdn} : cible vide — rien à poser") if target.empty?
      raise PrimitiveError.new("type #{type} non géré (#{TYPES.join(", ")})") unless TYPES.includes?(type)
      hook = context.dns || raise PrimitiveError.new("dns-record : pose DNS indisponible hors `beryl apply`")
      StepResult.applied(hook.call(fqdn, type, target, dry_run))
    end
  end

  Primitive.register(DnsRecord.new)
end
