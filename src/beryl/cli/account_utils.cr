require "../providers"
require "../config"

# Helpers partagés entre `beryl init`, `beryl add-provider`, `beryl
# add-domain` pour (a) résoudre la société courante depuis un
# argument CLI (forme path-like `société/objet` ou flag `--account`)
# et (b) choisir la société par défaut quand il n'y en a qu'une.
module Beryl::CLI::AccountUtils
  # Sépare un argument `<société>/<objet>` en {account, object}.
  # Retourne `{nil, raw}` si aucun `/` n'est présent.
  def self.split_account_path(raw : String) : NamedTuple(account: String?, object: String)
    if idx = raw.index('/')
      {account: raw[0...idx], object: raw[(idx + 1)..]}
    else
      {account: nil.as(String?), object: raw}
    end
  end

  # Résolution de la société à utiliser pour une commande :
  #
  #   - priorité 1 : path-like (si l'argument contient un `/`)
  #   - priorité 2 : flag explicite `--account=`
  #   - priorité 3 : auto-détection si une seule société existe
  #   - sinon : nil (erreur côté appelant)
  def self.resolve_account(
    config_root : String,
    path_account : String?,
    account_flag : String?,
  ) : String?
    return path_account if path_account && !path_account.empty?
    return account_flag if account_flag && !account_flag.empty?

    # Auto-détection si une seule société existe.
    root = Beryl::Config::Root.load(config_root)
    return nil if root.accounts.empty?
    return root.account_names.first if root.accounts.size == 1

    # Plusieurs sociétés et aucun hint : on rend nil, le caller
    # explique à l'utilisateur (liste des accounts + flag à utiliser).
    nil
  end

  # Liste des fournisseurs implémentés dans ce build de beryl.
  # Utilisé par `beryl init` et `add-provider` pour guider le prompt.
  def self.implemented_providers : Array(Beryl::Provider)
    Beryl::Providers.all.select(&.implemented?)
  end

  # Liste des fournisseurs configurés pour une société (présents
  # dans `.env.yml[account]`). Lecture seule, pour l'affichage.
  def self.providers_of(config_root : String, account : String) : Array(String)
    env = Beryl::Config::EnvFile.load(File.join(config_root, ".env.yml"))
    env.providers_for(account)
  end

  # Prompt simple avec défaut. `default` affiché entre crochets si
  # non vide. Ctrl-D ou EOF → lève `Aborted`.
  def self.ask(prompt : String, default : String = "") : String
    full_prompt = default.empty? ? prompt : "#{prompt} [#{default}] "
    STDERR.print full_prompt
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    answer = line.chomp.strip
    answer.empty? ? default : answer
  end

  def self.ask_yes_no(prompt : String, default_yes : Bool = true) : Bool
    hint = default_yes ? "[O/n]" : "[o/N]"
    full = "#{prompt} #{hint} "
    STDERR.print full
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    a = line.chomp.strip.downcase
    return default_yes if a.empty?
    a.starts_with?("o") || a.starts_with?("y")
  end

  # Masque un secret pour l'affichage : 4 premiers + *** + 4 derniers
  # si la valeur est assez longue, `***` sinon.
  def self.mask_secret(value : String) : String
    return "***" if value.size < 12
    "#{value[0, 4]}#{"*" * (value.size - 8)}#{value[-4, 4]}"
  end

  # Exception de sortie utilisateur (Ctrl-D, Ctrl-C logique).
  class Aborted < Exception
  end
end
