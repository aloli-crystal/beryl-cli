require "http/client"
require "json"
require "../primitive"

module Beryl::Apply
  # Primitive `github-ssh-key` : lit la clé PUBLIQUE d'un serveur et
  # l'ajoute au compte GitHub associé au PAT fourni (`POST /user/keys`) —
  # typiquement pour qu'un serveur puisse cloner/fetch un dépôt privé
  # (déploiement Capistrano). Idempotente : ne re-poste pas une clé déjà
  # présente. Le PAT vient du COFFRE (ENV), jamais de la recette.
  #
  #     - github-ssh-key:
  #         pubkey_path: /home/deploy/.ssh/id_ed25519.pub
  #         token_env: GITHUB_QUIMEOIT_TOKEN
  #         title: "deploy@serveur.quimeo.net"   # optionnel (défaut = commentaire de la clé)
  #
  # L'appel HTTP part de BERYL (le PAT reste côté opérateur, jamais sur le
  # serveur). PAT requis : scope `write:public_key` (classic) ou permission
  # « Git SSH keys : write » (fine-grained).
  class GithubSshKey < Primitive
    API = "https://api.github.com/user/keys"

    def name : String
      "github-ssh-key"
    end

    # Partie « matériel » d'une ligne de clé publique (2ᵉ champ, le base64),
    # pour comparer sans tenir compte du commentaire. Pur, exposé pour test.
    def self.key_material(pubkey : String) : String
      pubkey.split(/\s+/).reject(&.empty?)[1]? || ""
    end

    # Corps JSON du POST. Pur, exposé pour test.
    def self.payload(title : String, pubkey : String) : String
      {title: title, key: pubkey.strip}.to_json
    end

    # Vrai si le matériel de `pubkey` figure déjà dans la liste JSON
    # renvoyée par `GET /user/keys`. Pur, exposé pour test.
    def self.already_present?(list_json : String, pubkey : String) : Bool
      mat = key_material(pubkey)
      return false if mat.empty?
      JSON.parse(list_json).as_a.any? { |k| key_material(k["key"].as_s) == mat }
    rescue
      false
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      path = required_string(params, "pubkey_path")
      var = required_string(params, "token_env")
      token = ENV[var]?
      raise PrimitiveError.new("variable `#{var}` absente de l'environnement (coffre) — PAT GitHub introuvable.") if token.nil? || token.empty?

      res = shell.exec("cat #{Process.quote(path)}", raise_on_error: false)
      raise PrimitiveError.new("clé publique introuvable : #{path} (lancez `user-ssh-key` d'abord).") unless res.success?
      pubkey = res.stdout.strip
      raise PrimitiveError.new("#{path} ne ressemble pas à une clé publique SSH.") if self.class.key_material(pubkey).empty?

      # Titre : param, sinon le commentaire (3ᵉ champ) de la clé.
      title = string(params, "title") || pubkey.split(/\s+/).reject(&.empty?)[2]? || "beryl"

      return StepResult.applied("ajout clé « #{title} » au compte GitHub (dry-run)") if dry_run

      headers = HTTP::Headers{
        "Authorization" => "Bearer #{token}",
        "Accept"        => "application/vnd.github+json",
        "User-Agent"    => "beryl",
      }

      list = HTTP::Client.get(API, headers: headers)
      raise PrimitiveError.new("GitHub GET /user/keys → HTTP #{list.status_code} : #{list.body}") unless list.status_code == 200
      if self.class.already_present?(list.body, pubkey)
        return StepResult.skipped("clé déjà présente sur le compte GitHub")
      end

      post = HTTP::Client.post(API, headers: headers, body: self.class.payload(title, pubkey))
      case post.status_code
      when 201
        StepResult.applied("clé « #{title} » ajoutée au compte GitHub")
      when 422
        StepResult.skipped("clé déjà en usage côté GitHub (422)")
      else
        raise PrimitiveError.new("GitHub POST /user/keys → HTTP #{post.status_code} : #{post.body}")
      end
    end
  end

  Primitive.register(GithubSshKey.new)
end
