require "digest/sha1"
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
  #
  # Idempotence : état lu en LECTURE SEULE par le socket (OS-root), comparé
  # ici — rien de secret n'est envoyé au serveur pour cette vérification :
  #   * ligne `root@localhost` de `mysql.global_priv` (JSON) : `unix_socket`
  #     présent ET empreinte `mysql_native_password` du mot de passe du
  #     coffre (calculée localement) ;
  #   * aucun user anonyme, pas de base `test` ;
  #   * `skip-networking` dans `conf_path`.
  # Tout est déjà en place → Skipped (sinon « applied » à chaque passage, et
  # les `service-restart: { if_changed: true }` qui suivent relançaient).
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
    #
    # Users anonymes : TOUS, quel que soit l'hôte. L'installation en crée
    # aussi un au nom de la machine (`''@'too'`, vu le 8 nov. 2026), que
    # `''@'localhost'` / `''@'%'` seuls laissaient en place. Bloc anonyme
    # MariaDB (`WHILE … EXECUTE IMMEDIATE`), d'où le `DELIMITER` du client :
    # un à la fois, relu à chaque tour, plutôt qu'un curseur sur la table que
    # chaque `DROP USER` modifie (un échec lève une erreur : pas de boucle
    # infinie).
    def self.build_sql(password : String) : String
      esc = password.gsub("'", "''")
      <<-SQL
        ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('#{esc}');
        DELIMITER //
        BEGIN NOT ATOMIC
          DECLARE anon_host VARCHAR(255);
          WHILE (SELECT COUNT(*) FROM mysql.global_priv WHERE User = '') > 0 DO
            SELECT Host INTO anon_host FROM mysql.global_priv WHERE User = '' LIMIT 1;
            EXECUTE IMMEDIATE CONCAT('DROP USER ''''@', QUOTE(anon_host));
          END WHILE;
        END //
        DELIMITER ;
        DROP DATABASE IF EXISTS test;
        FLUSH PRIVILEGES;
        SQL
    end

    # Vrai si la sortie de `state_query` décrit un MariaDB déjà durci avec ce
    # mot de passe. L'ordre des méthodes dans le JSON (`auth_or`) varie selon
    # les versions : on cherche seulement leur présence. Pur.
    def self.hardened?(output : String, password : String) : Bool
      lines = output.lines.map(&.strip)
      return false unless lines.size == 3
      priv, anonymous, test_db = lines
      priv.includes?("unix_socket") && priv.includes?(native_hash(password)) &&
        anonymous == "0" && test_db == "0"
    end

    # Empreinte `mysql_native_password` (= `PASSWORD()` de MariaDB) :
    # `*` + SHA1(SHA1(mdp)) en hexadécimal majuscule. Pure.
    def self.native_hash(password : String) : String
      "*" + Digest::SHA1.digest(Digest::SHA1.digest(password)).hexstring.upcase
    end

    # Lecture de l'état (une valeur par ligne, `mysql -N -B`) : JSON `Priv`
    # de root@localhost, nombre d'users anonymes, présence de la base `test`.
    def self.state_query(socket : String) : String
      sql = "SELECT Priv FROM mysql.global_priv WHERE User='root' AND Host='localhost'; " \
            "SELECT COUNT(*) FROM mysql.global_priv WHERE User=''; " \
            "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='test';"
      "mysql --socket=#{Process.quote(socket)} -u root -N -B -e #{Process.quote(sql)}"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      var = required_string(params, "root_password_env")
      pwd = Apply.secret(var, context)
      raise PrimitiveError.new("variable `#{var}` absente de l'environnement (coffre) — mdp root MariaDB introuvable.") if pwd.nil? || pwd.empty?

      socket = string(params, "socket") || DEFAULT_SOCKET
      conf_path = string(params, "conf_path") || DEFAULT_CONF

      conf_present = shell.exec(
        "test -f #{Process.quote(conf_path)} && grep -q '^skip-networking' #{Process.quote(conf_path)}",
        raise_on_error: false,
      ).success?

      # MariaDB arrêté ou absent (premier passage) : sonde en échec → à faire.
      state = shell.exec(self.class.state_query(socket), raise_on_error: false)
      if conf_present && state.success? && self.class.hardened?(state.stdout, pwd)
        return StepResult.skipped("MariaDB déjà durci (mdp root, unix_socket, ni anonymes ni base test, skip-networking)")
      end

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
        shell.exec(Primitive.service_command(svc, "restart"))
      end

      note = restart_needed ? " + skip-networking (redémarré)" : ""
      StepResult.applied("MariaDB durci (mdp root, anonymes/test supprimés)#{note}")
    end
  end

  Primitive.register(MariadbSecure.new)
end
