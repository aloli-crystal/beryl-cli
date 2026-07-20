require "../primitive"

module Beryl::Apply
  # Primitive `acme-cert` : émet et installe un certificat Let's Encrypt
  # (via acme.sh, cf. recette `acme`) pour un ou plusieurs domaines, de
  # façon IDEMPOTENTE — beryl n'a pas de primitive « exec » générique, mais
  # celle-ci encapsule le geste d'émission stateful.
  #
  # Idempotent : si le fullchain existe déjà ET reste valide au-delà de
  # `renew_days`, la primitive skippe (le renouvellement courant est porté
  # par le cron de la recette `acme`, via le `reloadcmd` enregistré ici à
  # l'installation). Sinon elle émet + installe.
  #
  # TROIS méthodes de validation (`method:`) :
  #
  # * `standalone` (défaut) — acme.sh ouvre lui-même le port 80. Renseignez
  #   `stop_service` (ex. `nginx`) pour le libérer le temps de l'émission :
  #   le service est RESTAURÉ en `trap EXIT`, même si acme.sh échoue.
  # * `webroot` + `webroot: <racine servie sur :80>` — sans coupure.
  # * `dns` + `dns_provider: <plugin dnsapi>` — validation DNS-01 : **aucun
  #   port requis, donc AUCUNE coupure**, et **seule méthode qui gère les
  #   WILDCARDS** (`*.example.com`). Le renouvellement par le cron `acme` est
  #   entièrement automatique (acme.sh persiste les credentials DNS).
  #
  # Pré-requis (recette `acme`) : acme.sh + socat installés. En http-01
  # (`standalone`/`webroot`) chaque domaine doit pointer sur l'hôte AVANT
  # l'émission ; en `dns` seul l'accès à l'API DNS est nécessaire.
  #
  #     - acme-cert:
  #         domains: [pkg.quimeo.net, pkg.aloli.net]   # 1er = primaire, suivants = SAN
  #         fullchain: /usr/local/etc/ssl/acme/{{ hostname }}/fullchain.pem
  #         key:       /usr/local/etc/ssl/acme/{{ hostname }}/privkey.pem
  #         reloadcmd: "service nginx reload"
  #         stop_service: nginx
  #
  #     # Wildcard (DNS-01, sans coupure) — le wildcard NE couvre PAS l'apex
  #     # ni les sous-sous-domaines : listez les deux, un seul niveau.
  #     - acme-cert:
  #         domains: [quimeo.review, "*.quimeo.review"]
  #         method: dns
  #         dns_provider: dns_ovh
  #         fullchain: /usr/local/etc/ssl/acme/review/fullchain.pem
  #         key:       /usr/local/etc/ssl/acme/review/privkey.pem
  #         reloadcmd: "service nginx reload"
  class AcmeCert < Primitive
    ACME_BIN     = "/usr/local/sbin/acme.sh"
    DEFAULT_HOME = "/usr/local/etc/acme.sh"
    SCRIPT_PATH  = "/tmp/beryl-acme-cert.sh"

    # Traduction credentials beryl → variables attendues par les plugins
    # `dnsapi` d'acme.sh : les NOMS diffèrent (beryl est explicite, acme.sh
    # abrège). Clé = variable acme.sh, valeur = variable beryl.
    # Pour câbler un nouveau provider DNS, ajoutez son entrée ici.
    DNS_CREDENTIAL_MAP = {
      "dns_ovh" => {
        "OVH_AK" => "OVH_APPLICATION_KEY",
        "OVH_AS" => "OVH_APPLICATION_SECRET",
        "OVH_CK" => "OVH_CONSUMER_KEY",
      },
      "dns_gandi_livedns" => {
        "GANDI_LIVEDNS_KEY" => "GANDI_PAT",
      },
    }

    def name : String
      "acme-cert"
    end

    # Endpoint OVH au format acme.sh. beryl stocke `eu`/`ca`/`us` (ou
    # `kimsufi_eu`…), acme.sh attend `ovh-eu`/`kimsufi-eu`… Pur, testable.
    def self.ovh_end_point(raw : String?) : String
      ep = (raw || "eu").strip
      return ep if ep.starts_with?("ovh-") || ep.starts_with?("kimsufi-") || ep.starts_with?("soyoustart-")
      ep.includes?('_') ? ep.tr("_", "-") : "ovh-#{ep}"
    end

    # Credentials DNS à exporter pour le plugin `dnsapi`, lus depuis
    # l'environnement (renseigné par `apply_all_credentials_to_env!` du host).
    # Renvoie un hash vide si le provider n'est pas câblé / rien en env.
    def self.dns_credentials(provider : String, env = ENV) : Hash(String, String)
      out = {} of String => String
      if map = DNS_CREDENTIAL_MAP[provider]?
        map.each do |acme_var, beryl_var|
          v = env[beryl_var]?
          out[acme_var] = v if v && !v.empty?
        end
      end
      # L'endpoint OVH est dérivé (valeur reformatée), pas juste renommé.
      out["OVH_END_POINT"] = ovh_end_point(env["OVH_ENDPOINT"]?) if provider == "dns_ovh" && !out.empty?
      out
    end

    # Script d'émission + installation (lancé sur l'hôte). Pur, exposé pour
    # test. Pas de `set -e` : on capture le code de retour de `--issue` (0 =
    # émis, 2 = inchangé/déjà valide côté acme.sh — tous deux acceptables).
    def self.issue_script(domains : Array(String), fullchain : String, key : String,
                          reloadcmd : String?, home : String, server : String,
                          method : String, webroot : String?, stop_service : String?,
                          keylength : String, pre_hook : String?, post_hook : String?,
                          dns_provider : String? = nil,
                          dns_env : Hash(String, String) = {} of String => String) : String
      dflags = domains.map { |d| "-d #{Process.quote(d)}" }.join(' ')
      challenge =
        case method
        when "webroot" then "-w #{Process.quote(webroot || "")}"
        when "dns"     then "--dns #{Process.quote(dns_provider || "")}"
        else                "--standalone"
        end
      ecc = keylength.starts_with?("ec") ? " --ecc" : ""
      reload = reloadcmd ? " --reloadcmd #{Process.quote(reloadcmd)}" : ""
      # Credentials du plugin dnsapi : exportés dans le script (écrit en 0700
      # puis SUPPRIMÉ après exécution). acme.sh les persiste ensuite dans son
      # `account.conf` → les renouvellements du cron n'en ont plus besoin.
      exports = dns_env.keys.sort.map { |k| "export #{k}=#{Process.quote(dns_env[k])}\n" }.join
      # Hooks PERSISTÉS par acme.sh (rejoués à chaque renouvellement du cron) :
      # ils libèrent puis restaurent le service qui tient le port 80, ce que le
      # trap `stop_service` (émission ponctuelle) ne fait pas au renouvellement.
      # Inutiles en `method: dns` (aucun port n'est mobilisé).
      hooks = String.build do |s|
        s << " --pre-hook " << Process.quote(pre_hook) if pre_hook
        s << " --post-hook " << Process.quote(post_hook) if post_hook
      end
      guard = if ss = stop_service
                <<-GUARD
                trap 'service #{Process.quote(ss)} onestart >/dev/null 2>&1 || true' EXIT
                service #{Process.quote(ss)} onestop >/dev/null 2>&1 || true
                GUARD
              else
                "true"
              end
      <<-SH
      #!/bin/sh
      set -u
      #{exports}FC=#{Process.quote(fullchain)}
      KEY=#{Process.quote(key)}
      mkdir -p "$(dirname "$FC")" "$(dirname "$KEY")"
      #{guard}
      #{Process.quote(ACME_BIN)} --issue --server #{Process.quote(server)} #{dflags} #{challenge} --home #{Process.quote(home)} --keylength #{Process.quote(keylength)}#{hooks}
      rc=$?
      if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit "$rc"; fi
      #{Process.quote(ACME_BIN)} --install-cert -d #{Process.quote(domains.first)}#{ecc} --home #{Process.quote(home)} --fullchain-file "$FC" --key-file "$KEY"#{reload}
      SH
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      domains = string_array(params, "domains")
      raise PrimitiveError.new("`acme-cert` : `domains` requis (au moins un domaine)") if domains.empty?
      fullchain = required_string(params, "fullchain")
      key = required_string(params, "key")
      reloadcmd = string(params, "reloadcmd")
      home = string(params, "home") || DEFAULT_HOME
      server = string(params, "server") || "letsencrypt"
      method = string(params, "method") || "standalone"
      webroot = string(params, "webroot")
      stop_service = string(params, "stop_service")
      dns_provider = string(params, "dns_provider")
      keylength = string(params, "keylength") || "ec-256"
      pre_hook = string(params, "pre_hook")
      post_hook = string(params, "post_hook")
      renew_days = (string(params, "renew_days") || "30").to_i? || 30

      dns_env = {} of String => String
      case method
      when "standalone"
        # rien à valider
      when "webroot"
        if webroot.nil? || webroot.empty?
          raise PrimitiveError.new("`acme-cert` : `method: webroot` exige `webroot: <racine>`")
        end
      when "dns"
        dp = dns_provider
        if dp.nil? || dp.empty?
          raise PrimitiveError.new("`acme-cert` : `method: dns` exige `dns_provider:` (ex. `dns_ovh`)")
        end
        # Garde-fou : en DNS-01 aucun port n'est mobilisé — couper un service
        # serait une coupure gratuite (typiquement un copier-coller depuis une
        # conf `standalone`).
        if stop_service
          raise PrimitiveError.new(
            "`acme-cert` : `method: dns` ne mobilise aucun port — retirez `stop_service` " \
            "(le DNS-01 n'impose aucune coupure)")
        end
        dns_env = self.class.dns_credentials(dp)
        if dns_env.empty?
          raise PrimitiveError.new(
            "`acme-cert` : `dns_provider: #{dp}` — aucun credential DNS dans l'environnement. " \
            "Vérifiez que la société a ce provider configuré (`beryl add-provider`), ou câblez le " \
            "provider dans `AcmeCert::DNS_CREDENTIAL_MAP`.")
        end
      else
        raise PrimitiveError.new(
          "`acme-cert` : `method` doit valoir `standalone`, `webroot` ou `dns` (reçu #{method.inspect})")
      end

      names = domains.join(", ")

      # Idempotence : cert présent ET valide au-delà de la fenêtre de renouvellement.
      secs = renew_days * 86_400
      check = shell.exec(
        "test -f #{Process.quote(fullchain)} && openssl x509 -in #{Process.quote(fullchain)} -noout -checkend #{secs}",
        raise_on_error: false,
      )
      if check.success?
        return StepResult.skipped("cert #{domains.first} déjà valide (> #{renew_days} j) — #{fullchain}")
      end

      if dry_run
        via = method == "dns" ? " via DNS-01 (#{dns_provider})" : ""
        return StepResult.applied("émettrait le cert Let's Encrypt (#{server}) pour #{names}#{via} → #{fullchain} (dry-run)")
      end

      script = self.class.issue_script(domains, fullchain, key, reloadcmd, home, server, method,
        webroot, stop_service, keylength, pre_hook, post_hook, dns_provider, dns_env)
      # 0700 + suppression après coup : le script peut porter les credentials DNS.
      shell.write_file(SCRIPT_PATH, script, "0700")
      res = shell.exec("sh #{SCRIPT_PATH}", raise_on_error: false)
      shell.exec("rm -f #{SCRIPT_PATH}", raise_on_error: false)
      if res.success?
        StepResult.applied("cert émis + installé pour #{names} → #{fullchain}")
      else
        StepResult.failed("acme-cert #{names} : #{res.stderr.strip.lines.last? || "échec (code #{res.exit_code})"}")
      end
    end
  end

  Primitive.register(AcmeCert.new)
end
