require "../primitive"

module Beryl::Apply
  # Primitive `postgresql-database` : garantit qu'une base PostgreSQL existe,
  # avec son rôle propriétaire. Le rôle est créé SANS mot de passe : l'appli
  # se connecte par le socket Unix sous l'utilisateur système du même nom
  # (authentification locale du cluster). Idempotente : skip si rôle et base
  # existent déjà. Capacité ÉTROITE : jamais de suppression, jamais de
  # changement de propriétaire (une base existante appartenant à un autre rôle
  # → échec explicite, à trancher par l'opérateur).
  #
  #     - postgresql-database:
  #         name: partiduo_admin
  #         owner: partiduo-admin
  #         encoding: UTF8          # défaut
  class PostgresqlDatabase < Primitive
    # Noms acceptés : pas de guillemet ni d'espace (ils passent dans du SQL et
    # dans des arguments shell).
    NAME_RE = /\A[A-Za-z_][A-Za-z0-9_-]{0,62}\z/

    def name : String
      "postgresql-database"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      db = checked(params, "name")
      owner = checked(params, "owner")
      encoding = params["encoding"]?.try(&.as_s?) || "UTF8"
      raise PrimitiveError.new("`postgresql-database` : encodage invalide « #{encoding} »") unless encoding.matches?(/\A[A-Za-z0-9_]+\z/)

      role = query(shell, "SELECT 1 FROM pg_roles WHERE rolname = '#{owner}'")
      # Serveur injoignable : normal en dry-run sur un serveur neuf (PostgreSQL
      # installé et démarré plus haut dans le même apply), une erreur sinon.
      if role.nil?
        return StepResult.applied("rôle #{owner} + base #{db} : à créer (dry-run, PostgreSQL pas encore démarré)") if dry_run
        raise PrimitiveError.new("PostgreSQL injoignable (psql en échec) : serveur démarré ?")
      end
      role_ok = role == "1"
      current_owner = query(shell, "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '#{db}'") || ""
      if !current_owner.empty? && current_owner != owner
        raise PrimitiveError.new("base #{db} : appartient à « #{current_owner} », pas à « #{owner} » — non modifiée")
      end
      return StepResult.skipped("rôle #{owner} et base #{db} déjà présents") if role_ok && !current_owner.empty?

      todo = [] of String
      todo << "rôle #{owner}" unless role_ok
      todo << "base #{db}" if current_owner.empty?
      return StepResult.applied("#{todo.join(" + ")} : à créer (dry-run)") if dry_run

      as_postgres(shell, "createuser #{Process.quote(owner)}") unless role_ok
      if current_owner.empty?
        as_postgres(shell, "createdb --owner=#{Process.quote(owner)} --encoding=#{encoding} #{Process.quote(db)}")
      end
      StepResult.applied("#{todo.join(" + ")} : créé(s)")
    end

    private def checked(params : Hash(String, YAML::Any), key : String) : String
      value = required_string(params, key).strip
      unless value.matches?(NAME_RE)
        raise PrimitiveError.new("`postgresql-database` : #{key} invalide « #{value} » (lettres, chiffres, _ et -)")
      end
      value
    end

    # La valeur (première colonne, première ligne), "" si aucune ligne, nil si
    # le serveur ne répond pas (PostgreSQL arrêté, cluster absent).
    private def query(shell : Shell, sql : String) : String?
      cmd = "su -m postgres -c #{Process.quote("psql -d postgres -tAc #{Process.quote(sql)}")}"
      res = shell.exec(cmd, raise_on_error: false)
      res.success? ? res.stdout.strip : nil
    end

    private def as_postgres(shell : Shell, command : String)
      shell.exec("su -m postgres -c #{Process.quote(command)}")
    end
  end

  # Primitive `postgresql-role` : garantit qu'un rôle PostgreSQL existe, sans
  # mot de passe (connexion par le socket Unix), avec au besoin le droit de
  # créer des bases (`createdb: true`, pour un outil qui crée lui-même ses
  # bases). Idempotente ; ne retire jamais un droit ni un rôle, mais AJOUTE
  # `CREATEDB` à un rôle existant qui ne l'a pas.
  #
  #     - postgresql-role:
  #         name: partiduo
  #         createdb: true
  class PostgresqlRole < Primitive
    def name : String
      "postgresql-role"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      role = required_string(params, "name").strip
      unless role.matches?(PostgresqlDatabase::NAME_RE)
        raise PrimitiveError.new("`postgresql-role` : nom invalide « #{role} » (lettres, chiffres, _ et -)")
      end
      createdb = params["createdb"]?.try(&.as_bool?) == true
      res = shell.exec(psql("SELECT rolcreatedb FROM pg_roles WHERE rolname = '#{role}'"), raise_on_error: false)
      unless res.success?
        return StepResult.applied("rôle #{role} : à créer (dry-run, PostgreSQL pas encore démarré)") if dry_run
        raise PrimitiveError.new("PostgreSQL injoignable (psql en échec) : serveur démarré ?")
      end
      current = res.stdout.strip
      if current.empty?
        return StepResult.applied("rôle #{role}#{createdb ? " (CREATEDB)" : ""} : à créer (dry-run)") if dry_run
        flags = createdb ? "--createdb --no-superuser" : "--no-createdb --no-superuser"
        shell.exec("su -m postgres -c #{Process.quote("createuser #{flags} #{Process.quote(role)}")}")
        return StepResult.applied("rôle #{role}#{createdb ? " (CREATEDB)" : ""} : créé")
      end
      if createdb && current != "t"
        return StepResult.applied("rôle #{role} : ajout de CREATEDB (dry-run)") if dry_run
        shell.exec(psql("ALTER ROLE \"#{role}\" CREATEDB"))
        return StepResult.applied("rôle #{role} : CREATEDB ajouté")
      end
      StepResult.skipped("rôle #{role} déjà présent#{createdb ? " (CREATEDB)" : ""}")
    end

    private def psql(sql : String) : String
      "su -m postgres -c #{Process.quote("psql -d postgres -tAc #{Process.quote(sql)}")}"
    end
  end

  Primitive.register(PostgresqlDatabase.new)
  Primitive.register(PostgresqlRole.new)
end
