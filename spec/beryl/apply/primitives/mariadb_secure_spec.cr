require "../../../spec_helper"
require "../../../support/fake_shell"

private def y(h)
  res = Hash(String, YAML::Any).new
  h.each { |k, v| res[k] = YAML::Any.new(v) }
  res
end

private def ctx
  Beryl::Apply::Context.new
end

describe Beryl::Apply::MariadbSecure do
  it "est enregistrée sous `mariadb-secure`" do
    Beryl::Apply::Primitive["mariadb-secure"]?.should_not be_nil
  end

  describe ".build_sql" do
    it "préserve l'auth unix_socket et échappe le mot de passe" do
      sql = Beryl::Apply::MariadbSecure.build_sql("p'wd")
      sql.should contain("IDENTIFIED VIA unix_socket OR mysql_native_password")
      sql.should contain("PASSWORD('p''wd')")
      sql.should contain("WHILE (SELECT COUNT(*) FROM mysql.global_priv WHERE User = '') > 0 DO")
      sql.should contain("EXECUTE IMMEDIATE CONCAT('DROP USER ''''@', QUOTE(anon_host));")
      sql.should contain("DELIMITER ;")
      sql.should contain("DROP DATABASE IF EXISTS test")
      sql.should contain("FLUSH PRIVILEGES")
    end
  end

  describe ".native_hash" do
    it "vaut PASSWORD() de MariaDB (mysql_native_password)" do
      Beryl::Apply::MariadbSecure.native_hash("password").should eq("*2470C0C06DEE42FD1618BB99005ADCA2EC9D1E19")
    end
  end

  describe ".hardened?" do
    hash = Beryl::Apply::MariadbSecure.native_hash("secret")
    priv = %({"access":549755813887,"plugin":"mysql_native_password","authentication_string":"#{hash}","auth_or":[{"plugin":"unix_socket"},{}]})

    it "vrai : unix_socket + empreinte du mdp, ni anonymes ni base test" do
      Beryl::Apply::MariadbSecure.hardened?("#{priv}\n0\n0\n", "secret").should be_true
    end

    it "faux : autre mot de passe" do
      Beryl::Apply::MariadbSecure.hardened?("#{priv}\n0\n0\n", "autre").should be_false
    end

    it "faux : unix_socket absent (root par mot de passe seul)" do
      Beryl::Apply::MariadbSecure.hardened?(%({"plugin":"mysql_native_password","authentication_string":"#{hash}"}\n0\n0\n), "secret").should be_false
    end

    it "faux : user anonyme ou base test restants" do
      Beryl::Apply::MariadbSecure.hardened?("#{priv}\n1\n0\n", "secret").should be_false
      Beryl::Apply::MariadbSecure.hardened?("#{priv}\n0\n1\n", "secret").should be_false
    end

    it "faux : sortie incomplète (root absent)" do
      Beryl::Apply::MariadbSecure.hardened?("0\n0\n", "secret").should be_false
    end
  end

  it "skip quand tout est déjà en place (aucune écriture, aucun SQL, aucun restart)" do
    ENV["TEST_MDB_PW"] = "secret"
    hash = Beryl::Apply::MariadbSecure.native_hash("secret")
    sh = FakeShell.new
    sh.stub(/grep -q '\^skip-networking'/, exit_code: 0)
    sh.stub(/mysql .* -N -B -e/, stdout: %({"plugin":"mysql_native_password","authentication_string":"#{hash}","auth_or":[{"plugin":"unix_socket"},{}]}\n0\n0\n))
    r = Beryl::Apply::MariadbSecure.new.apply(
      sh, y({"root_password_env" => "TEST_MDB_PW", "service" => "mysql-server"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    sh.writes.should be_empty
    sh.ran?(/beryl-mariadb-secure\.sql/).should be_false
    sh.ran?(/restart/).should be_false
    sh.ran?(/secret/).should be_false
  ensure
    ENV.delete("TEST_MDB_PW")
  end

  it "dry-run : skip si déjà durci, sinon applied sans rien écrire" do
    ENV["TEST_MDB_PW"] = "secret"
    sh = FakeShell.new
    sh.stub(/grep -q '\^skip-networking'/, exit_code: 0)
    sh.stub(/mysql .* -N -B -e/, stdout: %({"plugin":"mysql_native_password","authentication_string":"*AUTRE","auth_or":[{"plugin":"unix_socket"},{}]}\n0\n0\n))
    r = Beryl::Apply::MariadbSecure.new.apply(sh, y({"root_password_env" => "TEST_MDB_PW"}), true, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.writes.should be_empty
  ensure
    ENV.delete("TEST_MDB_PW")
  end

  it "pose skip-networking + joue le SQL par socket (pas d'argv) + restart" do
    ENV["TEST_MDB_PW"] = "secret"
    sh = FakeShell.new
    sh.stub(/grep -q '\^skip-networking'/, exit_code: 1) # conf absente
    r = Beryl::Apply::MariadbSecure.new.apply(
      sh, y({"root_password_env" => "TEST_MDB_PW", "service" => "mysql-server"}), false, ctx)
    r.outcome.should eq(Beryl::Apply::Outcome::Applied)
    sh.writes.any? { |w| w.path.ends_with?("hardening.cnf") && w.content.includes?("skip-networking") }.should be_true
    sh.writes.any? { |w| w.path == "/tmp/beryl-mariadb-secure.sql" }.should be_true
    sh.ran?(/mysql --socket=.* -u root < \/tmp\/beryl-mariadb-secure\.sql/).should be_true
    sh.ran?(/rm -f \/tmp\/beryl-mariadb-secure\.sql/).should be_true
    sh.ran?(/service .*mysql-server.* restart/).should be_true
    ENV.delete("TEST_MDB_PW")
  end

  it "prend le mdp propre au serveur (<SERVEUR>__VAR) avant celui de la société" do
    ENV["TEST_MDB_PW"] = "commun"
    ENV["QUIMEO_TWIN_BSD__TEST_MDB_PW"] = "propre"
    sh = FakeShell.new
    sh.stub(/grep -q '\^skip-networking'/, exit_code: 0)
    Beryl::Apply::MariadbSecure.new.apply(
      sh, y({"root_password_env" => "TEST_MDB_PW"}), false,
      Beryl::Apply::Context.new(vars: {"hostname" => "quimeo-twin-bsd"}))
    sql = sh.writes.find! { |w| w.path == "/tmp/beryl-mariadb-secure.sql" }.content
    sql.should contain("PASSWORD('propre')")
    sql.should_not contain("commun")
  ensure
    ENV.delete("TEST_MDB_PW")
    ENV.delete("QUIMEO_TWIN_BSD__TEST_MDB_PW")
  end

  it "lève si la variable coffre du mdp est absente" do
    ENV.delete("ABSENT_PW")
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /absente/) do
      Beryl::Apply::MariadbSecure.new.apply(FakeShell.new, y({"root_password_env" => "ABSENT_PW"}), false, ctx)
    end
  end
end
