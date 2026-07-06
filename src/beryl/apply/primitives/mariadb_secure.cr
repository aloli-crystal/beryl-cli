require "../primitive"

module Beryl::Apply
  # Primitive `mariadb-secure` : durcit un MariaDB fraîchement installé —
  # l'équivalent automatisé et idempotent de `mysql_secure_installation` :
  #   * `skip-networking` (plus d'écoute TCP, socket Unix seul) ;
  #   * mot de passe root (SANS casser l'auth `unix_socket` de l'OS-root,
  #     pour que beryl puisse rejouer via le socket) ;
  #   * suppression des users anonymes et de la base `test`.
  #
  # Le mot de passe vient du COFFRE (ENV) — jamais dans la recette ni en
  # argv (SQL passé par fichier 0600, pas via `-e`).
  #
  #     - mariadb-secure:
  #         root_password_env: MARIADB_ROOT_PASSWORD
  #         socket: /var/run/mysql/mysql.sock   # optionnel
  #         conf_path: /usr/local/etc/mysql/conf.d/zz-beryl-hardening.cnf  # optionnel
  #         service: mysql-server               # optionnel (restart si conf posée)
  class MariadbSecure < Primitive
    DEFAULT_SOCKET = "/var/run/mysql/mysql.sock"
    DEFAULT_CONF   = "/usr/local/etc/mysql/conf.d/zz-beryl-hardening.cnf"
    TMP_SQL        = "/tmp/beryl-mariadb-secure.sql"

    def name : String
      "mariadb-secure"
    end

    # SQL de durcissement. `unix_socket OR mysql_native_password` PRÉSERVE
    # l'accès OS-root par socket (donc les re-runs beryl marchent) tout en
    # posant un mot de passe. Pur, exposé pour test. Le mot de passe est
    # échappé pour SQL (`'` doublée).
    def self.build_sql(password : String) : String
      esc = password.gsub("'", "''")
      <<-SQL
      ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('#{esc}');
      DROP USER IF EXISTS ''@'localhost';
      DROP USER IF EXISTS ''@'%';
      DROP DATABASE IF EXISTS test;
      FLUSH PRIVILEGES;
      SQL
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      var = required_string(params, "root_password_env")
      pwd = ENV[var]?
      raise PrimitiveError.new("variable `#{var}` absente de l'environnement (coffre) — mdp root MariaDB introuvable.") if pwd.nil? || pwd.empty?

      socket = string(params, "socket") || DEFAULT_SOCKET
      conf_path = string(params, "conf_path") || DEFAULT_CONF

      conf_present = shell.exec(
        "test -f #{Process.quote(conf_path)} && grep -q '^skip-networking' #{Process.quote(conf_path)}",
        raise_on_error: false,
      ).success?

      return StepResult.applied("durcissement MariaDB (dry-run)") if dry_run

      # 1. skip-networking (socket only). Effectif au prochain (re)start.
      restart_needed = false
      unless conf_present
        shell.write_file(conf_path, "[mysqld]\nskip-networking\n", "0644")
        restart_needed = true
      end

      # 2. SQL de durcissement, via socket en OS-root (auth unix_socket),
      #    lu depuis un fichier 0600 → jamais dans argv/`ps`.
      shell.write_file(TMP_SQL, self.class.build_sql(pwd), "0600")
      res = shell.exec(
        "mysql --socket=#{Process.quote(socket)} -u root < #{Process.quote(TMP_SQL)}; " \
        "__rc=$?; rm -f #{Process.quote(TMP_SQL)}; exit $__rc",
        raise_on_error: false,
      )
      raise PrimitiveError.new("SQL de durcissement MariaDB échoué : #{res.stderr.strip}") unless res.success?

      # 3. Restart si l'écoute réseau vient d'être coupée.
      if restart_needed && (svc = string(params, "service"))
        shell.exec("service #{Process.quote(svc)} restart")
      end

      note = restart_needed ? " + skip-networking (redémarré)" : ""
      StepResult.applied("MariaDB durci (mdp root, anonymes/test supprimés)#{note}")
    end
  end

  Primitive.register(MariadbSecure.new)
end
