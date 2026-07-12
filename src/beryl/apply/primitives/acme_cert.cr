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
  # `--standalone` occupe brièvement le port 80 : renseignez `stop_service`
  # (ex. `nginx`) pour libérer le port le temps de l'émission — le service
  # est RESTAURÉ en `trap EXIT`, même si acme.sh échoue. Alternative sans
  # coupure : `method: webroot` + `webroot: <racine servie sur :80>`.
  #
  # Pré-requis (recette `acme`) : acme.sh + socat installés. DNS : chaque
  # domaine doit pointer sur l'hôte AVANT l'émission (validation http-01).
  #
  #     - acme-cert:
  #         domains: [pkg.quimeo.net, pkg.aloli.net]   # 1er = primaire, suivants = SAN
  #         fullchain: /usr/local/etc/ssl/acme/{{ hostname }}/fullchain.pem
  #         key:       /usr/local/etc/ssl/acme/{{ hostname }}/privkey.pem
  #         reloadcmd: "service nginx reload"
  #         stop_service: nginx
  class AcmeCert < Primitive
    ACME_BIN     = "/usr/local/sbin/acme.sh"
    DEFAULT_HOME = "/usr/local/etc/acme.sh"

    def name : String
      "acme-cert"
    end

    # Script d'émission + installation (lancé sur l'hôte). Pur, exposé pour
    # test. Pas de `set -e` : on capture le code de retour de `--issue` (0 =
    # émis, 2 = inchangé/déjà valide côté acme.sh — tous deux acceptables).
    def self.issue_script(domains : Array(String), fullchain : String, key : String,
                          reloadcmd : String?, home : String, server : String,
                          method : String, webroot : String?, stop_service : String?,
                          keylength : String) : String
      dflags = domains.map { |d| "-d #{Process.quote(d)}" }.join(' ')
      challenge = method == "webroot" ? "-w #{Process.quote(webroot || "")}" : "--standalone"
      ecc = keylength.starts_with?("ec") ? " --ecc" : ""
      reload = reloadcmd ? " --reloadcmd #{Process.quote(reloadcmd)}" : ""
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
      FC=#{Process.quote(fullchain)}
      KEY=#{Process.quote(key)}
      mkdir -p "$(dirname "$FC")" "$(dirname "$KEY")"
      #{guard}
      #{Process.quote(ACME_BIN)} --issue --server #{Process.quote(server)} #{dflags} #{challenge} --home #{Process.quote(home)} --keylength #{Process.quote(keylength)}
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
      keylength = string(params, "keylength") || "ec-256"
      renew_days = (string(params, "renew_days") || "30").to_i? || 30

      if method == "webroot" && (webroot.nil? || webroot.empty?)
        raise PrimitiveError.new("`acme-cert` : `method: webroot` exige `webroot: <racine>`")
      end
      unless method == "webroot" || method == "standalone"
        raise PrimitiveError.new("`acme-cert` : `method` doit valoir `standalone` ou `webroot` (reçu #{method.inspect})")
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
        return StepResult.applied("émettrait le cert Let's Encrypt (#{server}) pour #{names} → #{fullchain} (dry-run)")
      end

      script = self.class.issue_script(domains, fullchain, key, reloadcmd, home, server, method, webroot, stop_service, keylength)
      shell.write_file("/tmp/beryl-acme-cert.sh", script, "0755")
      res = shell.exec("sh /tmp/beryl-acme-cert.sh", raise_on_error: false)
      if res.success?
        StepResult.applied("cert émis + installé pour #{names} → #{fullchain}")
      else
        StepResult.failed("acme-cert #{names} : #{res.stderr.strip.lines.last? || "échec (code #{res.exit_code})"}")
      end
    end
  end

  Primitive.register(AcmeCert.new)
end
