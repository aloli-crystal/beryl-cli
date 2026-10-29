require "../config"
require "../encryption"
require "../zfs_keys"
require "./config_git"

# Accès des commandes aux clés ZFS d'un serveur (`Beryl::ZfsKeys`) : où
# elles sont (fichier du poste, coffre de la société), comment les lire
# (coffre d'abord, fichier en repli, divergence = erreur) et comment les
# ranger dans le coffre. Partagé par bootstrap, zpool-create, unlock,
# tang-enroll et `beryl keys`.
module Beryl::CLI::KeyStore
  extend self

  # Fichier de clé du poste : `<racine>/<société>/<domaine>/<host>.key`.
  def file_path(config_root : String, host : Beryl::Config::ResolvedHost) : String
    Beryl::Encryption.key_path(config_root, host.account_name, host.domain_name, host.short_name)
  end

  # Variable du coffre (`[tang]`) du serveur.
  def var(host : Beryl::Config::ResolvedHost) : String
    Beryl::ZfsKeys.vault_var(host.short_name)
  end

  # Coffre chiffré de la société du serveur.
  def vault_path(host : Beryl::Config::ResolvedHost) : String
    File.join(host.account.path, Beryl::Config::EnvFile::VAULT_FILENAME)
  end

  # Clé du serveur, coffre puis fichier ; nil si aucune. Lève
  # `Encryption::InvalidKey` ou `ZfsKeys::Conflict`.
  def resolve(config_root : String, host : Beryl::Config::ResolvedHost) : Beryl::ZfsKeys::Found?
    Beryl::ZfsKeys.resolve(host.env_file, host.account_name, var(host), file_path(config_root, host))
  end

  # Clé à utiliser pour CRÉER des datasets chiffrés (bootstrap,
  # zpool-create) : l'existante (coffre ou fichier) si le serveur en a une,
  # sinon une nouvelle, écrite dans le fichier du poste (0400). Renvoie
  # {clé, nouvelle ?}. Le rangement dans le coffre est fait à part
  # (`ensure_in_vault`), seulement quand la commande agit (`--apply`).
  def obtain_or_create(config_root : String, host : Beryl::Config::ResolvedHost) : {String, Bool}
    if found = resolve(config_root, host)
      return {found.hex, false}
    end
    {Beryl::Encryption.write_new(file_path(config_root, host)), true}
  end

  # Range la clé dans le coffre `[tang]` de la société (ajout seulement ;
  # déjà là → rien) et commite le coffre chiffré. Coffre absent ou
  # illisible : avertissement, la clé reste dans le seul fichier du poste
  # (on ne crée pas de coffre : il remplacerait au chargement les
  # credentials de `.env.yml`). Renvoie vrai si la clé est dans le coffre.
  # Une AUTRE clé déjà rangée pour ce serveur lève `ZfsKeys::Conflict`.
  def ensure_in_vault(host : Beryl::Config::ResolvedHost, hex : String, no_commit : Bool = false,
                      vault : Beryl::ZfsKeys::Vault? = nil, &log : String ->) : Bool
    vault ||= Beryl::ZfsKeys::Vault.new(vault_path(host))
    v = var(host)
    unless vault.exists?
      log.call "⚠ coffre #{vault.path} absent : la clé ZFS n'est que dans le fichier du poste. " \
               "Créez le coffre (`beryl env edit --create #{host.account_name}`) puis " \
               "`beryl keys import #{host.account_name} --apply`."
      return false
    end
    case vault.store(v, hex)
    in .added?
      log.call "clé ZFS rangée dans le coffre #{host.account_name} [#{Beryl::ZfsKeys::SECTION}] #{v} " \
               "(empreinte #{Beryl::ZfsKeys.fingerprint(hex)})"
      Beryl::CLI::ConfigGit.commit([vault.path], "keys : clé ZFS de #{host.short_name} rangée dans le coffre [tang]", no_commit)
    in .unchanged?
      log.call "clé ZFS déjà dans le coffre #{host.account_name} [#{Beryl::ZfsKeys::SECTION}] #{v}"
    end
    true
  rescue ex : Beryl::ZfsKeys::Conflict
    raise ex
  rescue ex : Secrets::Error | IO::Error | File::Error
    log.call "⚠ coffre #{vault.try(&.path)} non mis à jour (#{ex.message}) : la clé ZFS n'est que dans le fichier du poste. " \
             "Relancez `beryl keys import #{host.account_name} --apply`."
    false
  end
end
