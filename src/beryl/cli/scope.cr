require "../config"
require "./info"

# Portée des commandes « un serveur » (rescue, bootstrap, dns, reboot…) : un
# serveur, ou plusieurs — liste `a,b,c`, groupe, domaine, société, comme
# `apply` ou `info` (`Info.scoped_hosts`). Plusieurs serveurs : la commande est
# REJOUÉE pour chacun, l'un après l'autre, avec les mêmes options (questions,
# confirmations, essai à blanc et journal restent ceux de la commande), puis
# un résumé.
#
# Tolère les espaces après les virgules : le shell coupe `ah, be, ga` en
# `ah,` `be,` `ga`, recollés en `ah,be,ga`.
module Beryl::CLI::Scope
  extend self

  # Avertissements du serveur en cours (échec secondaire qui ne fait pas
  # échouer la commande, ex. reverse IPv6 refusé par `dns`) : la commande les
  # signale par `warn`, `run_each` les reprend dans son résumé. Sans portée
  # multiple, personne ne les lit (la commande les a déjà affichés).
  @@warnings = [] of String

  def warn(message : String) : Nil
    @@warnings << message
  end

  # Vrai pendant le rejeu d'une portée multiple : une commande peut alors
  # SAUTER un serveur hors de son ressort (avertissement) au lieu d'échouer ;
  # nommé seul, il garde son erreur.
  @@fanning = false

  def fanning? : Bool
    @@fanning
  end

  # Recolle les positionnels de tête coupés aux virgules par le shell
  # (`["ah,", "be,", "ga", "x"]` → `["ah,be,ga", "x"]`). Pur.
  def join_list(positional : Array(String)) : Array(String)
    return positional if positional.empty?
    head = positional[0]
    i = 1
    while i < positional.size && (head.ends_with?(',') || positional[i].starts_with?(','))
      head += positional[i]
      i += 1
    end
    [head] + positional[i..]
  end

  # Éléments d'une portée (`a,b,,c ` → `[a, b, c]`). Pur.
  def parts(scope : String) : Array(String)
    scope.split(',').map(&.strip).reject(&.empty?)
  end

  # Si la portée désigne PLUSIEURS serveurs (ou une liste), rejoue la commande
  # pour chacun via le bloc (qui reçoit les arguments, la portée remplacée par
  # `société/domaine/serveur`) et renvoie le code final ; nil si la portée est
  # UN serveur ou n'est pas reconnue — la commande suit alors son cours normal
  # (et donne son erreur habituelle). Élément inconnu dans une liste : erreur.
  #
  # `fresh_only` (commandes qui EFFACENT les disques : wipe, bootstrap) : sur
  # plusieurs serveurs, tous doivent être encore `installed: false` ; un seul
  # serveur installé dans la portée → refus de TOUTE la portée, avant de
  # commencer (une confusion `anciens`/`production` n'efface rien). Un serveur
  # nommé seul reste possible, installé ou non.
  def fan_out(cmd : String, config_root : String, args : Array(String), positional : Array(String),
              fresh_only : Bool = false, & : Array(String) -> Int32) : Int32?
    joined = join_list(positional)
    raw = joined.first?
    return unless raw
    list = raw.includes?(',')
    root = Beryl::Config::Root.load(config_root)
    unless list
      return if single_host?(root, raw)
      hosts = Beryl::CLI::Info.scoped_hosts(root, raw)
      return if hosts.size < 2
    end
    if list && !(unknown = parts(raw).select { |p| Beryl::CLI::Info.scoped_hosts(root, p).empty? }).empty?
      STDERR.puts "beryl #{cmd} : élément(s) inconnu(s) dans la liste #{raw} : #{unknown.join(", ")} " \
                  "(ni serveur, ni groupe, ni domaine, ni société)."
      return 1
    end
    hosts = Beryl::CLI::Info.scoped_hosts(root, raw)
    if fresh_only && !(installed = hosts.select(&.installed?)).empty?
      STDERR.puts "beryl #{cmd} : refusé sur la portée #{raw} — #{installed.size} serveur(s) déjà installé(s) : " \
                  "#{installed.map(&.short_name).join(", ")}. Sur plusieurs serveurs, #{cmd} n'efface que des serveurs " \
                  "pas encore installés (installed: false) ; pour un serveur installé, nommez-le seul."
      return 1
    end
    refs = hosts.map { |h| Beryl::CLI::AccountUtils.host_ref(h) }
    base = without_scope(args, positional.size - joined.size + 1, positional)
    run_each(cmd, raw, refs, base) { |a| yield a }
  end

  # Rejoue la commande pour chaque serveur, à la suite ; résumé à la fin. Code :
  # 0 si tout a réussi, sinon celui du premier échec.
  def run_each(cmd : String, scope : String, refs : Array(String), base : Array(String),
               & : Array(String) -> Int32) : Int32
    STDERR.puts "[beryl #{cmd}] portée #{scope} → #{refs.size} serveur(s) : #{refs.map { |r| r.split('/').last }.join(", ")}"
    warned = {} of String => Array(String)
    @@fanning = true
    results = refs.map_with_index do |ref, i|
      STDERR.puts
      STDERR.puts "──── beryl #{cmd} #{ref} (#{i + 1}/#{refs.size}) ────"
      @@warnings.clear
      code = yield(base + [ref])
      warned[ref] = @@warnings.dup unless @@warnings.empty?
      {ref, code}
    end
    @@warnings.clear
    @@fanning = false
    failed = results.reject { |_, code| code == 0 }
    STDERR.puts
    if failed.empty?
      STDERR.puts "[beryl #{cmd}] #{refs.size} serveur(s) : tous réussis#{warned.empty? ? "." : ", avec avertissement(s) : #{warnings_line(warned)}"}"
      0
    else
      STDERR.puts "[beryl #{cmd}] #{refs.size - failed.size}/#{refs.size} réussi(s) ; en échec : " +
                  failed.map { |ref, code| "#{ref.split('/').last} (code #{code})" }.join(", ")
      STDERR.puts "[beryl #{cmd}] avertissement(s) : #{warnings_line(warned)}" unless warned.empty?
      failed.first[1]
    end
  end

  # `no (reverse IPv6), be (…)` : serveur court + avertissements. Pur.
  def warnings_line(warned : Hash(String, Array(String))) : String
    warned.map { |ref, msgs| "#{ref.split('/').last} (#{msgs.join(" ; ")})" }.join(", ")
  end

  # `args` sans les `count` premiers positionnels (la portée, éventuellement
  # coupée en plusieurs morceaux par le shell). Pur.
  def without_scope(args : Array(String), count : Int32, positional : Array(String)) : Array(String)
    drop = positional.first(count)
    out = args.dup
    drop.each { |tok| (i = out.index(tok)) && out.delete_at(i) }
    out
  end

  # La portée nomme-t-elle UN serveur (y compris `société/domaine/serveur`) ?
  # Un nom ambigu (deux sociétés) aussi : la commande donnera son erreur.
  private def single_host?(root : Beryl::Config::Root, raw : String) : Bool
    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    root.resolve(parsed[:host], account_hint: parsed[:account], domain_hint: parsed[:domain])
    true
  rescue Beryl::Config::Root::AmbiguousHost
    true
  rescue
    false
  end
end
