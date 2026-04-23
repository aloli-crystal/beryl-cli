require "../cli/credentials"

module Beryl::Providers
  # Provider OVHcloud pour beryl. Encapsule la détection des credentials
  # (via `Beryl::CLI::Credentials.ovh_client`) et le listing des clés
  # SSH enregistrées dans le compte.
  #
  # Le client OVH est injectable via le constructeur pour les tests.
  # En production, on laisse le défaut `nil` et `client` résout à
  # la demande via `Credentials.ovh_client`.
  class Ovh < Beryl::Provider
    def initialize(@injected_client : OvhApi::Client? = nil)
    end

    private def client : OvhApi::Client
      @injected_client || Beryl::CLI::Credentials.ovh_client
    end

    def name : String
      "ovh"
    end

    def display_name : String
      "OVHcloud"
    end

    def available? : Bool
      ENV["OVH_APPLICATION_KEY"]? && ENV["OVH_APPLICATION_SECRET"]? && ENV["OVH_CONSUMER_KEY"]? ? true : false
    end

    def list_ssh_keys : Array(Beryl::SshKeyInfo)
      c = client
      names = c.ssh_keys.list
      names.map do |name|
        # L'API OVH oblige un GET supplémentaire par clé pour
        # récupérer le contenu. Coûteux si beaucoup de clés, mais
        # simple et suffisant pour le volume typique (1 à 5 clés).
        full = c.ssh_keys.get(name)
        Beryl::SshKeyInfo.new(id: name, name: name, public_key: full.key)
      end
    end

    # Côté YAML, OVH attend `ovh.ssh_key_name: <label>`. Le label est
    # directement le `keyName` OVH. Consommé par `beryl rescue` qui
    # passe cette valeur à `client.dedicated_servers.prepare_rescue`.
    def ssh_key_yaml_fragment(key_id : String) : Hash(String, String | Array(String))
      result = {} of String => String | Array(String)
      result["ssh_key_name"] = key_id
      result
    end

    def credentials_env_vars : Array(Beryl::EnvVarSpec)
      [
        Beryl::EnvVarSpec.new(
          name: "OVH_APPLICATION_KEY",
          description: "Clé applicative (générée à l'URL d'aide)",
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_APPLICATION_SECRET",
          description: "Secret applicatif (donné une fois à la génération)",
          secret: true,
        ),
        # OVH_CONSUMER_KEY est marquée `optional` côté prompt : elle
        # n'est PAS demandée à l'utilisateur. Le hook
        # `bootstrap_credentials_if_needed` la génère automatiquement
        # via `POST /auth/credential` avec les access rules exactes,
        # une fois que APP_KEY + APP_SECRET sont dispos. L'utilisateur
        # n'a qu'à valider l'URL dans son navigateur.
        Beryl::EnvVarSpec.new(
          name: "OVH_CONSUMER_KEY",
          description: "Consumer key (générée auto par beryl init)",
          optional: true,
          secret: true,
        ),
        Beryl::EnvVarSpec.new(
          name: "OVH_ENDPOINT",
          description: "Datacenter (eu|ca|us|kimsufi_eu|kimsufi_ca|soyoustart_eu|soyoustart_ca)",
          optional: true,
          default: "eu",
        ),
      ]
    end

    def credentials_help_url : String
      "https://eu.api.ovh.com/createApp/ (pour générer l'APP_KEY + APP_SECRET initiaux)"
    end

    # Détails affichés pendant `beryl init` : beryl génère la consumer
    # key automatiquement via `POST /auth/credential`, l'opérateur n'a
    # donc qu'à cocher « autoriser » dans le navigateur. Les routes
    # listées ci-dessous sont injectées automatiquement par le hook
    # `bootstrap_credentials_if_needed` — documentation uniquement.
    def credentials_help_details : String?
      lines = [] of String
      lines << "Beryl générera la consumer key lui-même avec ces droits :"
      required_access_rules.each { |r| lines << "  #{r[:verb].ljust(5)} #{r[:path]}" }
      lines << "Après création, ouvrez l'URL de validation dans le navigateur."
      lines.join("\n")
    end

    # Routes OVH que beryl appelle. Injectées dans la `consumer_key`
    # au moment de la création via `POST /auth/credential`. Les `*`
    # sont des wildcards supportés par OVH (pattern "tout sous ce
    # préfixe").
    def required_access_rules : Array({verb: String, path: String})
      [
        {verb: "GET", path: "/dedicated/server/*"},
        {verb: "PUT", path: "/dedicated/server/*"},
        {verb: "POST", path: "/dedicated/server/*"},
        {verb: "GET", path: "/me/sshKey/*"},
        {verb: "GET", path: "/domain/zone/*"},
        {verb: "POST", path: "/domain/zone/*/record"},
        {verb: "POST", path: "/domain/zone/*/refresh"},
        {verb: "PUT", path: "/ip/*/reverse"},
        {verb: "POST", path: "/ip/*/reverse"},
        {verb: "PUT", path: "/services/*"}, # displayName rename (avril 2026)
      ]
    end

    # Génère la consumer key OVH si absente (ou si force_regen).
    # Utilise `POST /auth/credential` du shard ovh-api 0.4.0 avec
    # la liste exacte des access rules de `required_access_rules`.
    #
    # Flux utilisateur :
    #   1. Requête API → retourne une URL de validation
    #   2. Beryl ouvre le navigateur (macOS `open`, Linux `xdg-open`)
    #   3. L'utilisateur clique « autoriser » dans OVH
    #   4. Beryl attend une confirmation (Entrée)
    #   5. La consumer_key est stockée dans env
    def bootstrap_credentials_if_needed(
      env : Hash(String, String),
      force_regen : Bool = false,
      interactive : Bool = true,
    ) : Hash(String, String)
      existing = env["OVH_CONSUMER_KEY"]?
      return env if existing && !existing.empty? && !force_regen

      app_key = env["OVH_APPLICATION_KEY"]?
      app_secret = env["OVH_APPLICATION_SECRET"]?
      endpoint = env["OVH_ENDPOINT"]? || "eu"
      if app_key.nil? || app_key.empty? || app_secret.nil? || app_secret.empty?
        raise "OVH_APPLICATION_KEY et OVH_APPLICATION_SECRET requis avant de générer la consumer key"
      end

      rules = required_access_rules.map do |r|
        OvhApi::Endpoints::AccessRule.new(method: r[:verb], path: r[:path])
      end

      STDERR.puts "[beryl init] OVH : génération d'une consumer key avec #{rules.size} access rule(s)..."
      temp_client = OvhApi::Client.new(
        application_key: app_key,
        application_secret: app_secret,
        endpoint: endpoint_symbol(endpoint),
      )
      result = temp_client.auth.request_consumer_key(rules)

      STDERR.puts "[beryl init] OVH : ouvrez cette URL dans votre navigateur pour valider :"
      STDERR.puts "             #{result.validation_url}"
      STDERR.puts "             (Après « Authorize », OVH affiche un message déconcertant"
      STDERR.puts "              « Authorize %!s(<nil>) » — c'est un bug d'affichage chez eux,"
      STDERR.puts "              la clé est bien créée et stockée par beryl.)"

      if interactive
        STDERR.print "[beryl init] OVH : Tapez Entrée une fois la clé validée côté OVH... "
        STDERR.flush
        STDIN.gets
      else
        STDERR.puts "[beryl init] OVH : --non-interactive → la clé est enregistrée telle quelle."
        STDERR.puts "             Elle sera utilisable une fois validée côté OVH."
      end

      # Interroge OVH pour confirmer la validation et afficher la
      # date d'expiration. Si l'appel échoue (clé pas encore validée,
      # API qui hoquette…), on continue — la clé est déjà stockée,
      # l'info d'expiration n'est qu'un confort.
      report_credential_expiration(app_key, app_secret, endpoint, result.consumer_key)

      updated = env.dup
      updated["OVH_CONSUMER_KEY"] = result.consumer_key
      updated
    end

    # Fait un `GET /auth/currentCredential` avec la nouvelle consumer
    # key et affiche la durée de validité restante. Silencieux sur
    # erreur (la clé peut être en `pendingValidation` si l'utilisateur
    # a tapé Entrée trop vite, l'API OVH peut hoqueter, etc.) — on ne
    # bloque pas le flux pour une info annexe.
    private def report_credential_expiration(
      app_key : String,
      app_secret : String,
      endpoint : String,
      consumer_key : String,
    ) : Nil
      signed_client = OvhApi::Client.new(
        application_key: app_key,
        application_secret: app_secret,
        consumer_key: consumer_key,
        endpoint: endpoint_symbol(endpoint),
      )
      info = signed_client.auth.current_credential
      if days = info.days_until_expiration
        date = info.expiration.not_nil!.to_s("%d/%m/%Y")
        STDERR.puts "[beryl init] OVH : consumer key valide pendant #{days} jour(s) (jusqu'au #{date})."
        STDERR.puts "             Relancez `beryl init ovh --regen-credentials` pour renouveler."
      else
        STDERR.puts "[beryl init] OVH : consumer key en validité illimitée."
      end
    rescue
      # Silencieux : info annexe, pas de friction pour l'utilisateur.
    end

    # Convertit la String `OVH_ENDPOINT` en Symbol attendu par
    # `OvhApi::Client`. Les String pures sont interprétées comme
    # URLs par le shard, donc on doit mapper explicitement les noms
    # courts vers leurs symboles.
    private def endpoint_symbol(endpoint : String) : Symbol
      case endpoint
      when "eu"            then :eu
      when "ca"            then :ca
      when "us"            then :us
      when "kimsufi_eu"    then :kimsufi_eu
      when "kimsufi_ca"    then :kimsufi_ca
      when "soyoustart_eu" then :soyoustart_eu
      when "soyoustart_ca" then :soyoustart_ca
      else
        raise "OVH_ENDPOINT invalide : #{endpoint.inspect} (eu|ca|us|kimsufi_*|soyoustart_*)"
      end
    end

    def owns?(host_name : String) : Bool
      # Quand un client est injecté (cas test), on l'utilise sans
      # vérifier `available?` (les env vars ne sont pas forcément
      # posées en spec).
      return false unless @injected_client || available?
      client.dedicated_servers.list.includes?(host_name)
    rescue
      false
    end
  end
end
