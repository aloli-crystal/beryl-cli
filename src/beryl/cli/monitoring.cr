require "option_parser"
require "./scope"
require "./option_errors"
require "api-ovh/ovh_api"
require "../config"
require "./credentials"
require "./info"
require "./ovh_monitoring"

# Sous-commande `beryl monitoring <portée> [on|off] [--apply]` : monitoring
# OVH des serveurs dédiés (OVH pinge le serveur, ouvre un incident et peut
# faire intervenir un technicien s'il ne répond plus).
#
# * sans `on`/`off` : état de chaque serveur OVH de la portée (lecture seule) ;
# * `on` / `off` : essai à blanc par défaut, `--apply` pour agir.
#
# Portée : un serveur, un domaine ou une société, comme `beryl info`. Seuls
# les serveurs OVH (avec `ovh.service_name`) sont concernés.
#
# `beryl rescue` coupe ce monitoring tout seul et `boot-hd` / `bootstrap` le
# remettent en service, sauf `--no-monitoring` (cf. `Beryl::CLI::OvhMonitoring`).
module Beryl::CLI::Monitoring
  EXIT_OK        = 0
  EXIT_USAGE     = 1
  EXIT_API_ERROR = 7

  STATES = {"on", "off"}

  def self.run(config_root : String, args : Array(String)) : Int32
    dry_run = true
    positional = [] of String
    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl monitoring <portée> [on|off] [--apply]\n" \
                 "        Monitoring OVH des serveurs (ping + intervention). Sans on/off : état ; on/off : DRY-RUN, --apply pour agir.\n" \
                 "        Portée : serveur, domaine ou société. `beryl rescue` le coupe, `boot-hd`/`bootstrap` le remettent en service."
      p.on("--apply", "Applique réellement (sinon : dry-run, affiche ce qui changerait)") { dry_run = false }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    Beryl::CLI.handle_option_errors(parser).parse(args)
    # `a, b, c` (espaces après les virgules, coupés par le shell) → `a,b,c`.
    positional = Beryl::CLI::Scope.join_list(positional)

    state, scope = split_args(positional)
    unless scope
      STDERR.puts "beryl : portée non précisée. USAGE : beryl monitoring <portée> [on|off] [--apply]"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    hosts = Beryl::CLI::Info.scoped_hosts(root, scope).select { |h| h.provider == "ovh" && h.ovh_service_name }
    if hosts.empty?
      STDERR.puts "beryl : aucun serveur OVH dans la portée #{scope}."
      return EXIT_USAGE
    end

    code = EXIT_OK
    hosts.group_by(&.account_name).each do |account, group|
      root.env_file.apply_all_to_env(account.to_s, overwrite: true) if account
      client = Beryl::CLI::Credentials.ovh_client
      group.each do |h|
        sn = h.ovh_service_name.not_nil!
        begin
          puts line(h.fqdn, client, sn, state, dry_run)
        rescue ex : OvhApi::Error
          STDERR.puts "#{h.fqdn} : erreur API OVH — #{ex.message}"
          code = EXIT_API_ERROR
        end
      end
    end
    puts "\n(dry-run) Pour appliquer : beryl monitoring #{scope} #{state} --apply" if state && dry_run
    code
  rescue ex : Beryl::CLI::Credentials::MissingCredentials
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  end

  # {état demandé (on/off ou nil), portée} — dans n'importe quel ordre. Pur.
  def self.split_args(positional : Array(String)) : {String?, String?}
    state = positional.find { |a| STATES.includes?(a) }
    scope = positional.find { |a| !STATES.includes?(a) }
    {state, scope}
  end

  private def self.line(fqdn : String, client : OvhApi::Client, sn : String, state : String?, dry_run : Bool) : String
    current = Beryl::CLI::OvhMonitoring.state(client, sn)
    return "#{fqdn} : #{status_text(current)}" unless state
    wanted = state == "on"
    return "#{fqdn} : déjà #{wanted ? "actif" : "coupé"}" if current == wanted
    return "#{fqdn} : #{status_text(current)} → serait #{wanted ? "activé" : "coupé"}" if dry_run
    Beryl::CLI::OvhMonitoring.set(client, sn, wanted)
    "#{fqdn} : monitoring #{wanted ? "activé" : "coupé"}"
  end

  # Texte d'état d'un serveur. Pur.
  def self.status_text(enabled : Bool?) : String
    case enabled
    when true  then "monitoring actif"
    when false then "monitoring coupé"
    else            "état du monitoring illisible (champ `monitoring` absent de la réponse OVH)"
    end
  end
end
