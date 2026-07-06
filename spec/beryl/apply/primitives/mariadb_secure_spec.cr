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
      sql.should contain("DROP USER IF EXISTS ''@'localhost'")
      sql.should contain("DROP DATABASE IF EXISTS test")
      sql.should contain("FLUSH PRIVILEGES")
    end
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

  it "lève si la variable coffre du mdp est absente" do
    ENV.delete("ABSENT_PW")
    expect_raises(Beryl::Apply::Primitive::PrimitiveError, /absente/) do
      Beryl::Apply::MariadbSecure.new.apply(FakeShell.new, y({"root_password_env" => "ABSENT_PW"}), false, ctx)
    end
  end
end
