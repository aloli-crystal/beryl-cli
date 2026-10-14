require "../primitive"

module Beryl::Apply
  # Primitive `postgresql-initdb` : initialise le cluster PostgreSQL via
  # `service postgresql oneinitdb`. PostgreSQL l'exige avant le premier start
  # (MariaDB s'auto-initialise, lui). Idempotente et auto-gardée : skip si
  # un data dir est déjà initialisé (`/var/db/postgres/data*/PG_VERSION`).
  # Capacité ÉTROITE : initialiser le cluster, rien d'autre.
  #
  #     - postgresql-initdb: {}
  class PostgresqlInitdb < Primitive
    def name : String
      "postgresql-initdb"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      # Pas de serveur PostgreSQL installé (ex. only: client) → rien à
      # initialiser, et `service postgresql oneinitdb` échouerait.
      unless shell.exec("test -f /usr/local/etc/rc.d/postgresql", raise_on_error: false).success?
        return StepResult.skipped("serveur PostgreSQL non installé — initdb ignoré")
      end

      return StepResult.skipped("cluster PostgreSQL déjà initialisé") if initialized?(shell)
      return StepResult.applied("initdb (dry-run)") if dry_run

      # `oneinitdb` et non `initdb` : convention de rc.subr pour un service PAS
      # ENCORE activé (postgresql_enable est posé à l'étape suivante). Avec
      # `initdb`, rc.subr se contente d'avertir (« Cannot 'initdb' postgresql…
      # use 'oneinitdb' ») et rend 0 sans rien faire.
      res = shell.exec("service postgresql oneinitdb 2>&1", raise_on_error: false)
      # `service … initdb` peut rendre 0 sans avoir rien créé : on VÉRIFIE
      # le résultat plutôt que de croire le code de retour (constaté sur un
      # serveur neuf le 6 oct. 2026 : succès annoncé, data dir absent).
      unless res.success? && initialized?(shell)
        detail = (res.stdout + res.stderr).strip.lines.last(5).join(" | ")
        return StepResult.failed("initdb n'a pas créé le cluster (code #{res.exit_code}) : #{detail.empty? ? "aucune sortie" : detail}")
      end
      StepResult.applied("cluster PostgreSQL initialisé")
    end

    private def initialized?(shell : Shell) : Bool
      shell.exec("ls /var/db/postgres/data*/PG_VERSION >/dev/null 2>&1", raise_on_error: false).success?
    end
  end

  Primitive.register(PostgresqlInitdb.new)
end
