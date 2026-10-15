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
  # Conventions du port FreeBSD : acme.sh tourne en utilisateur `acme`
  # (`user:`), home `/var/db/acme/.acme.sh` (`home:`), certificats laissés
  # dans `/var/db/acme/certs` (`cert_home:`) — `fullchain`/`key` ne servent
  # qu'à copier ailleurs si une recette l'exige.
  #
  #     - acme-cert:
  #         domains: [www.example.net, example.net]   # 1er = primaire, suivants = SAN
  #         method: dns
  #         dns_provider: dns_ovh
  #         reloadcmd: "/usr/local/bin/sudo /usr/sbin/service nginx reload"
  #
  #     # Wildcard (DNS-01, sans coupure) — le wildcard NE couvre PAS l'apex
  #     # ni les sous-sous-domaines : listez les deux, un seul niveau.
  #     - acme-cert:
  #         domains: [example.net, "*.example.net"]
  #         method: dns
  #         dns_provider: dns_ovh
  #         reloadcmd: "/usr/local/bin/sudo /usr/sbin/service nginx reload"
  class AcmeCert < Primitive
    ACME_BIN = "/usr/local/sbin/acme.sh"
    # Conventions du port FreeBSD security/acme.sh (pkg-plist, pkg-message,
    # account.conf.sample) : home ~acme/.acme.sh, certificats ~acme/certs,
    # acme.sh exécuté par l'utilisateur `acme` (créé par le paquet).
    DEFAULT_HOME      = "/var/db/acme/.acme.sh"
    DEFAULT_CERT_HOME = "/var/db/acme/certs"
    DEFAULT_USER      = "acme"
    SCRIPT_PATH       = "/tmp/beryl-acme-cert.sh"

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
    def self.issue_script(domains : Array(String), fullchain : String?, key : String?,
                          reloadcmd : String?, home : String, server : String,
                          method : String, webroot : String?, stop_service : String?,
                          keylength : String, pre_hook : String?, post_hook : String?,
                          dns_provider : String? = nil,
                          dns_env : Hash(String, String) = {} of String => String,
                          cert_home : String = DEFAULT_CERT_HOME,
                          aliases : Hash(String, String) = {} of String => String) : String
      dflags = domain_flags(domains, aliases)
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
      # Copie vers des chemins explicites (`fullchain`/`key`) seulement si la
      # recette en donne ; sinon le certificat reste dans CERT_HOME (convention
      # du port) et `--install-cert` n'enregistre que le `reloadcmd`.
      copy = (fc = fullchain) && (k = key) ? " --fullchain-file #{Process.quote(fc)} --key-file #{Process.quote(k)}" : ""
      mkdirs = (fc = fullchain) && (k = key) ? "mkdir -p \"$(dirname #{Process.quote(fc)})\" \"$(dirname #{Process.quote(k)})\"" : "true"
      install = copy.empty? && reload.empty? ? "" : "#{Process.quote(ACME_BIN)} --install-cert -d #{Process.quote(domains.first)}#{ecc} --home #{Process.quote(home)} --cert-home #{Process.quote(cert_home)}#{copy}#{reload}"
      <<-SH
        #!/bin/sh
        set -u
        #{exports}#{mkdirs}
        #{guard}
        #{Process.quote(ACME_BIN)} --issue --server #{Process.quote(server)} #{dflags} #{challenge} --home #{Process.quote(home)} --cert-home #{Process.quote(cert_home)} --keylength #{Process.quote(keylength)}#{hooks}
        rc=$?
        if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit "$rc"; fi
        #{install}
        SH
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      domains = string_array(params, "domains")
      raise PrimitiveError.new("`acme-cert` : `domains` requis (au moins un domaine)") if domains.empty?
      fullchain = string(params, "fullchain")
      key = string(params, "key")
      if fullchain.nil? != key.nil?
        raise PrimitiveError.new("`acme-cert` : `fullchain` et `key` vont ensemble (les deux ou aucun)")
      end
      reloadcmd = string(params, "reloadcmd")
      home = string(params, "home") || DEFAULT_HOME
      cert_home = string(params, "cert_home") || DEFAULT_CERT_HOME
      aliases = parse_aliases(params)
      unknown = aliases.keys - domains
      unless unknown.empty?
        raise PrimitiveError.new("`acme-cert` : `challenge_aliases` cite #{unknown.join(", ")}, absent(s) de `domains`")
      end
      user = string(params, "user") || DEFAULT_USER
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
      cert_file = fullchain || self.class.cert_home_fullchain(cert_home, domains.first, keylength)
      secs = renew_days * 86_400
      check = shell.exec(
        "test -f #{Process.quote(cert_file)} && openssl x509 -in #{Process.quote(cert_file)} -noout -checkend #{secs}",
        raise_on_error: false,
      )
      if check.success?
        return StepResult.skipped("cert #{domains.first} déjà valide (> #{renew_days} j) — #{cert_file}")
      end

      if dry_run
        via = method == "dns" ? " via DNS-01 (#{dns_provider})" : ""
        return StepResult.applied("émettrait le cert Let's Encrypt (#{server}) pour #{names}#{via} → #{cert_file} (dry-run)")
      end

      script = self.class.issue_script(domains, fullchain, key, reloadcmd, home, server, method,
        webroot, stop_service, keylength, pre_hook, post_hook, dns_provider, dns_env, cert_home, aliases)
      # 0700 + suppression après coup : le script peut porter les credentials DNS.
      # Exécuté par `user` (défaut `acme`, convention du port) : le script lui
      # appartient le temps de l'exécution.
      shell.write_file(SCRIPT_PATH, script, "0700")
      runner = if user == "root"
                 "sh #{SCRIPT_PATH}"
               else
                 shell.exec("chown #{Process.quote(user)} #{SCRIPT_PATH}")
                 "su -m #{Process.quote(user)} -c #{Process.quote("sh #{SCRIPT_PATH}")}"
               end
      res = shell.exec(runner, raise_on_error: false)
      shell.exec("rm -f #{SCRIPT_PATH}", raise_on_error: false)
      if res.success?
        StepResult.applied("cert émis + installé pour #{names} → #{cert_file}")
      else
        StepResult.failed("acme-cert #{names} : #{self.class.failure_summary(res.stdout, res.stderr, res.exit_code)} (journal : #{LOG_PATH})")
      end
    end

    # Journal d'acme.sh selon la convention du port (`LOG_FILE` de
    # account.conf, posé par la recette `acme`) : cité dans le message d'échec.
    LOG_PATH = "/var/log/acme.sh.log"

    # `-d` de chaque domaine, avec le « mode alias DNS » d'acme.sh (wiki
    # DNS-alias-mode) : un domaine dont la zone n'est pas accessible avec nos
    # identifiants DNS est validé via un CNAME `_acme-challenge.<domaine>` →
    # `_acme-challenge.<alias>` posé une fois ; acme.sh écrit alors le TXT
    # dans la zone de l'alias. Dès qu'un alias existe, les autres domaines
    # reçoivent `--challenge-alias no` (mélange documenté, section 5).
    # Pur, exposé pour test.
    def self.domain_flags(domains : Array(String), aliases : Hash(String, String)) : String
      domains.map do |d|
        flag = "-d #{Process.quote(d)}"
        if (a = aliases[d]?)
          "#{flag} --challenge-alias #{Process.quote(a)}"
        elsif aliases.empty?
          flag
        else
          "#{flag} --challenge-alias no"
        end
      end.join(' ')
    end

    # Fullchain tel que rangé par acme.sh dans CERT_HOME : `<domaine>_ecc/`
    # pour une clé EC, `<domaine>/` sinon. Pur, exposé pour test.
    def self.cert_home_fullchain(cert_home : String, domain : String, keylength : String) : String
      dir = keylength.starts_with?("ec") ? "#{domain}_ecc" : domain
      "#{cert_home}/#{dir}/fullchain.cer"
    end

    # Résumé lisible d'un échec acme.sh : ses lignes d'ERREUR (les 5
    # dernières), pas sa dernière ligne qui n'est qu'un lien vers le wiki.
    # Repli : les 3 dernières lignes non vides. Pur, exposé pour test.
    def self.failure_summary(stdout : String, stderr : String, exit_code : Int32) : String
      lines = (stdout + "\n" + stderr).lines.map(&.strip).reject(&.empty?)
      lines = lines.reject(&.includes?("How-to-debug-acme.sh"))
      # Préfixe d'horodatage d'acme.sh (`[Mon Oct  5 15:21:47 CEST 2026] `) retiré.
      lines = lines.map(&.sub(/\A\[[^\]]*\d{4}\]\s*/, ""))
      errors = lines.select(&.matches?(/error|fail|invalid|denied|unauthori[sz]ed|forbidden|not (?:set|found|valid)|refused|timeout/i))
      picked = errors.empty? ? lines.last(3) : errors.last(5)
      picked.empty? ? "échec (code #{exit_code})" : picked.join(" | ")
    end

    # `challenge_aliases: [{domain: pkg.example.org, alias: pkg.example.net}]`
    # → { "pkg.example.org" => "pkg.example.net" }.
    private def parse_aliases(params : Hash(String, YAML::Any)) : Hash(String, String)
      out = {} of String => String
      params["challenge_aliases"]?.try(&.as_a?).try &.each do |e|
        h = e.as_h? || raise PrimitiveError.new("`acme-cert` : chaque entrée de `challenge_aliases` est { domain, alias }")
        d = h[YAML::Any.new("domain")]?.try(&.as_s?)
        a = h[YAML::Any.new("alias")]?.try(&.as_s?)
        raise PrimitiveError.new("`acme-cert` : `challenge_aliases` exige `domain` et `alias`") unless d && a
        out[d] = a
      end
      out
    end
  end

  Primitive.register(AcmeCert.new)
end
