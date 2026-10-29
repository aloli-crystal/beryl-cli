require "digest/sha256"
require "secrets"
require "./encryption"
require "./config/env_file"

module Beryl
  # Clés de chiffrement ZFS des serveurs : fichier du poste ET coffre de la
  # société.
  #
  # La clé d'un serveur (64 caractères hex, cf. `Beryl::Encryption`) vit
  # historiquement dans `~/.config/beryl/<société>/<domaine>/<host>.key`
  # (0400, ignoré par git) : perdre le poste, c'est perdre les données dès
  # que Tang ne répond plus. Elle est donc AUSSI rangée dans le coffre
  # chiffré `age` de la société (`<société>/.env.toml.age`, versionné),
  # section `[tang]`, une variable par serveur :
  #
  #     [tang]
  #     WEB1 = "<64 hex>"
  #     DB_MAIN = "<64 hex>"
  #
  # Nom de la variable : nom court du serveur en majuscules, tout caractère
  # hors [A-Z0-9] → `_` (même convention que les secrets propres à un
  # serveur, `Beryl::Apply.host_secret_name`).
  #
  # Règles :
  #
  #   - lecture : coffre d'abord, fichier en repli ; les deux présents et
  #     DIFFÉRENTS → `Conflict`, jamais de choix silencieux (une mauvaise
  #     clé ne déverrouille rien, mais une clé écrasée par la mauvaise
  #     détruit le seul exemplaire de la bonne) ;
  #   - écriture : ajout seulement ; une valeur déjà présente et différente
  #     → `Conflict` ; identique → rien à faire ;
  #   - la section `[tang]` n'est JAMAIS chargée dans `ENV`
  #     (`EnvFile::ENV_EXCLUDED_SECTIONS`).
  module ZfsKeys
    # Section du coffre qui range les clés.
    SECTION = "tang"

    # Deux exemplaires d'une même clé qui diffèrent (coffre ≠ fichier), ou
    # tentative d'écraser une clé différente dans le coffre.
    class Conflict < Beryl::Encryption::Error
    end

    # Clé trouvée et sa provenance (« coffre », « fichier », « --key-file »…).
    record Found, hex : String, origin : String

    # Issue d'un rangement dans le coffre.
    enum StoreResult
      Added     # variable ajoutée, coffre réécrit
      Unchanged # même valeur déjà présente, coffre intact
    end

    # Variable du coffre d'un serveur : `web-1` → `WEB_1`. Pur.
    def self.vault_var(host_short : String) : String
      host_short.upcase.gsub(/[^A-Z0-9]/, "_")
    end

    # Empreinte courte d'une clé, pour vérifier une copie (papier, coffre)
    # sans montrer la clé : 16 premiers caractères du SHA-256 de la clé hex,
    # par groupes de 4. Ne permet pas de retrouver la clé. Pur.
    def self.fingerprint(hex : String) : String
      groups(Digest::SHA256.hexdigest(hex)[0, 16])
    end

    # `abcd1234…` → `abcd 1234 …` (lisible, recopiable sans erreur). Pur.
    def self.groups(hex : String, size : Int32 = 4) : String
      hex.chars.each_slice(size).map(&.join).join(" ")
    end

    # Réconcilie les deux exemplaires possibles. nil si aucun ; `Conflict`
    # s'ils diffèrent. Pur.
    def self.reconcile(vault_hex : String?, file_hex : String?, var : String, file_path : String) : Found?
      if vault_hex && file_hex && vault_hex != file_hex
        raise Conflict.new(
          "clé ZFS divergente : coffre [#{SECTION}] #{var} (empreinte #{fingerprint(vault_hex)}) " \
          "≠ fichier #{file_path} (empreinte #{fingerprint(file_hex)}). beryl ne choisit pas : " \
          "trouvez celle qui ouvre les pools (`beryl unlock <host> --key-file <fichier> --apply`), " \
          "puis corrigez l'autre exemplaire à la main (`beryl env edit <société>` ou le fichier)."
        )
      end
      if vault_hex
        Found.new(vault_hex, "coffre")
      elsif file_hex
        Found.new(file_hex, "fichier")
      end
    end

    # Clé d'un serveur : coffre de la société (déjà déchiffré par le loader
    # dans `env_file`) puis fichier `file_path`. Lève `InvalidKey` (format,
    # permissions du fichier) ou `Conflict`.
    def self.resolve(env_file : Beryl::Config::EnvFile, account : String, var : String, file_path : String) : Found?
      raw = env_file.for_account_provider(account, SECTION)[var]?
      vault_hex = raw ? Beryl::Encryption.parse_hex(raw, "coffre [#{SECTION}] #{var}") : nil
      file_hex = Beryl::Encryption.exists?(file_path) ? Beryl::Encryption.read(file_path) : nil
      reconcile(vault_hex, file_hex, var, file_path)
    end

    # Insère `var = "<hex>"` dans la section `[tang]` du TOML en clair
    # (section créée à la fin si absente), sans toucher au reste ni aux
    # commentaires. Même valeur déjà là → texte inchangé ; valeur
    # différente → `Conflict`. Pur.
    def self.insert(plaintext : String, var : String, hex : String) : {String, StoreResult}
      if existing = Beryl::Config::EnvFile.parse_vault_toml(plaintext)[SECTION]?.try(&.[var]?)
        current = Beryl::Encryption.parse_hex(existing, "coffre [#{SECTION}] #{var}")
        return {plaintext, StoreResult::Unchanged} if current == hex
        raise Conflict.new(
          "le coffre porte déjà une AUTRE clé pour #{var} (empreinte #{fingerprint(current)}, " \
          "reçue #{fingerprint(hex)}) — refus d'écraser. Vérifiez laquelle ouvre les pools."
        )
      end
      line = "#{var} = \"#{hex}\"\n"
      lines = plaintext.lines(chomp: false)
      if idx = lines.index { |l| l.strip == "[#{SECTION}]" }
        lines.insert(idx + 1, line)
        {lines.join, StoreResult::Added}
      else
        base = plaintext.empty? || plaintext.ends_with?('\n') ? plaintext : plaintext + "\n"
        {"#{base}\n[#{SECTION}]\n#{line}", StoreResult::Added}
      end
    end

    # Coffre chiffré d'une société, vu des clés ZFS. Le (dé)chiffrement est
    # injectable : par défaut la clé maîtresse du poste (`secrets`) et le
    # roster `Secrets::Recipients` ; les tests passent une identité age
    # jetable.
    class Vault
      getter path : String

      def initialize(@path : String,
                     @decrypt : Proc(String, String) = ->(ct : String) { Secrets::Vault.decrypt(ct, Secrets::MasterKey.read.identity) },
                     @encrypt : Proc(String, String) = ->(pt : String) { Secrets::Vault.encrypt(pt, Secrets::Recipients.encryption_keys) })
      end

      def exists? : Bool
        File.exists?(@path)
      end

      # Clé rangée pour `var`, nil si absente.
      def read_key(var : String) : String?
        raw = Beryl::Config::EnvFile.parse_vault_toml(@decrypt.call(File.read(@path)))[SECTION]?.try(&.[var]?)
        raw ? Beryl::Encryption.parse_hex(raw, "coffre [#{SECTION}] #{var}") : nil
      end

      # Range la clé : déchiffre, insère (`ZfsKeys.insert`), relit le
      # résultat, chiffre et remplace le coffre d'un bloc (fichier
      # temporaire 0600 puis `rename` : un coffre à moitié écrit perdrait
      # TOUS les secrets de la société).
      def store(var : String, hex : String) : StoreResult
        updated, result = ZfsKeys.insert(@decrypt.call(File.read(@path)), var, hex)
        return result if result.unchanged?
        got = Beryl::Config::EnvFile.parse_vault_toml(updated)[SECTION]?.try(&.[var]?)
        raise Beryl::Encryption::Error.new("coffre résultant illisible pour #{var} — rien n'est écrit") unless got == hex
        tmp = "#{@path}.tmp-#{Random::Secure.hex(4)}"
        begin
          File.open(tmp, "w", perm: 0o600) { |f| f.print(@encrypt.call(updated)) }
          File.chmod(tmp, 0o600)
          File.rename(tmp, @path)
        ensure
          File.delete?(tmp)
        end
        result
      end
    end
  end
end
