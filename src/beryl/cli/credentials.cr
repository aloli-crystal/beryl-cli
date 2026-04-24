# Note : les shards ovh-api et scaleway-api utilisent des noms de
# fichiers en underscore (`src/ovh_api.cr`, `src/scaleway_api.cr`),
# mais leur répertoire dans `lib/` garde le tiret (`lib/ovh-api/`,
# `lib/scaleway-api/`). Crystal exige la même casse des deux côtés ;
# on passe donc par la forme longue `<shard-dir>/<file>`.
require "ovh-api/ovh_api"
require "scaleway-api/scaleway_api"
require "dedibox-api/dedibox_api"

# Helpers pour construire les clients d'API des hébergeurs à partir de
# variables d'environnement. Séparés de la sous-commande `rescue` pour
# pouvoir être réutilisés par d'autres sous-commandes futures (création
# de serveur, reverse DNS, etc.).
module Beryl::CLI::Credentials
  # Construit un `OvhApi::Client` à partir des variables d'environnement :
  #
  # * `OVH_APPLICATION_KEY`     (requis)
  # * `OVH_APPLICATION_SECRET`  (requis)
  # * `OVH_CONSUMER_KEY`        (requis)
  # * `OVH_ENDPOINT`            (optionnel, défaut : `eu`)
  #
  # Lève `Beryl::CLI::Credentials::MissingCredentials` si l'une des
  # variables obligatoires est absente, avec un message francophone
  # utilisable directement en sortie CLI.
  def self.ovh_client : OvhApi::Client
    OvhApi::Client.new(
      application_key: fetch_env("OVH_APPLICATION_KEY"),
      application_secret: fetch_env("OVH_APPLICATION_SECRET"),
      consumer_key: fetch_env("OVH_CONSUMER_KEY"),
      endpoint: resolve_ovh_endpoint(ENV["OVH_ENDPOINT"]? || "eu"),
    )
  end

  # Convertit la chaîne d'ENV en symbole attendu par `OvhApi::Client`.
  # Accepte aussi bien "eu", "ca", "us", "kimsufi_eu", etc. Lève si le
  # nom n'est pas dans `OvhApi::ENDPOINTS`.
  private def self.resolve_ovh_endpoint(value : String) : Symbol
    case value
    when "eu"            then :eu
    when "ca"            then :ca
    when "us"            then :us
    when "kimsufi_eu"    then :kimsufi_eu
    when "kimsufi_ca"    then :kimsufi_ca
    when "soyoustart_eu" then :soyoustart_eu
    when "soyoustart_ca" then :soyoustart_ca
    else
      raise MissingCredentials.new(
        "OVH_ENDPOINT invalide : #{value.inspect}. Valeurs acceptées : " \
        "eu, ca, us, kimsufi_eu, kimsufi_ca, soyoustart_eu, soyoustart_ca."
      )
    end
  end

  # Construit un `ScalewayApi::Client` à partir des variables
  # d'environnement :
  #
  # * `SCW_SECRET_KEY`          (requis)
  # * `SCW_DEFAULT_ZONE`        (optionnel, défaut : `fr-par-2`)
  # * `SCW_DEFAULT_PROJECT_ID`  (optionnel ; pas nécessaire pour un
  #                              simple reboot en rescue, mais utile
  #                              pour les opérations de création)
  def self.scaleway_client : ScalewayApi::Client
    ScalewayApi::Client.new(
      secret_key: fetch_env("SCW_SECRET_KEY"),
      default_zone: ENV["SCW_DEFAULT_ZONE"]? || ScalewayApi::DEFAULT_ZONE,
      default_project_id: ENV["SCW_DEFAULT_PROJECT_ID"]?,
    )
  end

  # Construit un `DediboxApi::Client` à partir de la variable
  # d'environnement `DEDIBOX_TOKEN` (Bearer token généré depuis
  # https://console.online.net/fr/api/access). Pas de signature
  # HMAC, pas d'endpoint à choisir — beaucoup plus simple qu'OVH.
  def self.dedibox_client : DediboxApi::Client
    DediboxApi::Client.new(token: fetch_env("DEDIBOX_TOKEN"))
  end

  # Levée quand une variable d'environnement obligatoire est manquante.
  class MissingCredentials < Exception
  end

  private def self.fetch_env(name : String) : String
    value = ENV[name]?
    if value.nil? || value.empty?
      raise MissingCredentials.new(
        "variable d'environnement #{name} manquante ou vide. " \
        "Exportez les crédentials de l'hébergeur avant d'invoquer beryl."
      )
    end
    value
  end
end
