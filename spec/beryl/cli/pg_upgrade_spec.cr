require "../../spec_helper"
require "../../support/fake_shell"
require "../../../src/beryl/cli/pg_upgrade"

# FakeShell à réponses SUCCESSIVES pour certains motifs (ex. `pkg query`
# avant / après un `pkg delete`) : chaque appel consomme la réponse suivante,
# la dernière restant acquise. Les autres motifs suivent FakeShell.
class ScriptedShell < FakeShell
  @seqs = [] of {Regex, Array(String)}

  def stub_seq(pattern : Regex, outputs : Array(String)) : Nil
    @seqs << {pattern, outputs.dup}
  end

  def exec(command : String, raise_on_error : Bool = true) : SSH::Result
    if seq = @seqs.find { |(re, _)| re.matches?(command) }
      commands << command
      outs = seq[1]
      reply = outs.size > 1 ? outs.shift : outs.first
      return SSH::Result.new(reply, "", 0)
    end
    super
  end
end

private alias PgU = Beryl::CLI::PgUpgrade

# Commandes qui modifient le serveur : aucune ne doit passer en dry-run.
private MUTATING = /pkg (create|delete|install|add)|service \S+ (stop|start)|initdb|pg_upgrade|rm -rf|mkdir|tar x|pg_dumpall|sysrc \S+=|vacuumdb|\bmv\b|\bcp\b/

private OLD_FAMILY = "postgresql18-client\npostgresql18-contrib\npostgresql18-server\nrubygem-pg\nnginx\n"

# Hôte type : PostgreSQL 18 (client + server + contrib) en service sur
# /var/db/postgres/data18 (checksums actifs), 19 au dépôt, un dépendant
# (rubygem-pg) déjà reconstruit contre postgresql19-client.
private def happy_shell(shell = ScriptedShell.new) : ScriptedShell
  shell.stub(/^pkg query '%n'$/, OLD_FAMILY)
  shell.stub(/sysrc -n postgresql_(profiles|user|data)/, "", exit_code: 1)
  shell.stub(/pkg rquery -U '%v %n'/, "19.1 postgresql19-server")
  %w[postgresql19-server postgresql19-client postgresql19-contrib rubygem-pg].each do |n|
    shell.stub(/^pkg rquery -U '%n' #{n}$/, n)
  end
  shell.stub(/^pkg query '%rn' postgresql18-client$/, "postgresql18-contrib\npostgresql18-server\nrubygem-pg\n")
  shell.stub(/^pkg rquery -U '%dn' rubygem-pg$/, "ruby32\npostgresql19-client\n")
  shell.stub(/^echo ~postgres$/, "/var/db/postgres")
  shell.stub(%r{^cat /var/db/postgres/data18/PG_VERSION}, "18\n")
  shell.stub(%r{^test -e /var/db/postgres/data19$}, exit_code: 1)
  shell.stub(/pg_controldata/, "Bytes per WAL segment:                16777216\nData page checksum version:           1\n")
  shell.stub(/psql -XAt -d template1/, "UTF8|C|C.UTF-8|c|\n")
  shell.stub(/^du -sk /, "1048576\t/var/db/postgres/data18\n")
  shell.stub(/^df -kP /, "zroot/var/db 100000000 1000 50000000 1% /var/db\n")
  shell
end

private def migration(shell, out_io = IO::Memory.new, err_io = IO::Memory.new, **opts)
  PgU::Migration.new(shell, PgU::Options.new(**opts), "loulou.example.net", out_io, err_io,
    Time.local(2026, 10, 14, 18, 30, 0))
end

private def idx(shell : FakeShell, re : Regex) : Int32
  shell.commands.index { |c| re.matches?(c) } || raise "commande attendue absente : #{re.source}\n#{shell.commands.join("\n")}"
end

describe Beryl::CLI::PgUpgrade do
  describe "fonctions pures" do
    it "major_key range 9.6 (96) avant 10 et 17" do
      (PgU.major_key("96") < PgU.major_key("10")).should be_true
      (PgU.major_key("17") < PgU.major_key("19")).should be_true
    end

    it "lit l'état des data checksums dans pg_controldata" do
      PgU.parse_checksums("Data page checksum version:           1\n").should be_true
      PgU.parse_checksums("Data page checksum version:           0\n").should be_false
      PgU.parse_checksums("rien\n").should be_nil
    end

    it "lit la taille des segments WAL" do
      PgU.parse_wal_segment("Bytes per WAL segment:                16777216\n").should eq(16777216_i64)
    end

    it "parse une ligne df -kP" do
      PgU.parse_df("zroot/var 100 10 90 10% /var").should eq({"zroot/var", 90_i64})
      PgU.parse_df("Filesystem 1024-blocks Used Avail").should be_nil
    end

    it "initdb : --data-checksums si l'ancien cluster en a" do
      loc = PgU::Locale.new("UTF8", "C", "C.UTF-8")
      PgU.initdb_flags(loc, true, "19", 16777216_i64).should eq(
        ["--encoding=UTF8", "--lc-collate=C", "--lc-ctype=C.UTF-8", "--data-checksums"])
    end

    it "initdb : --no-data-checksums sans checksums (cible >= 18, défaut inversé)" do
      loc = PgU::Locale.new("UTF8", "C", "C")
      PgU.initdb_flags(loc, false, "19", nil).should contain("--no-data-checksums")
    end

    it "initdb : aucun flag de checksums sans checksums pour une cible < 18" do
      loc = PgU::Locale.new("UTF8", "C", "C")
      flags = PgU.initdb_flags(loc, false, "17", nil)
      flags.any?(&.includes?("checksums")).should be_false
    end

    it "initdb : reproduit le fournisseur ICU / builtin et une taille WAL non standard" do
      icu = PgU.initdb_flags(PgU::Locale.new("UTF8", "C", "C", "i", "fr-FR"), true, "19", 64_i64 * 1024 * 1024)
      icu.should contain("--locale-provider=icu")
      icu.should contain("--icu-locale=fr-FR")
      icu.should contain("--wal-segsize=64")
      PgU.initdb_flags(PgU::Locale.new("UTF8", "C", "C", "b", "C.UTF-8"), true, "19", nil)
        .should contain("--builtin-locale=C.UTF-8")
    end

    it "valide les options (services, chemins, --to)" do
      PgU.validate(PgU::Options.new).should be_nil
      PgU.validate(PgU::Options.new(stop_services: ["app;rm"])).should_not be_nil
      PgU.validate(PgU::Options.new(dump_dir: "relatif")).should_not be_nil
      PgU.validate(PgU::Options.new(dump_dir: "/var")).should_not be_nil
      PgU.validate(PgU::Options.new(new_data: "/var/db/../x")).should_not be_nil
      PgU.validate(PgU::Options.new(to: "19.1")).should_not be_nil
    end
  end

  describe "dry-run" do
    it "détecte 18 → 19, affiche le plan et n'exécute rien de mutant" do
      shell = happy_shell
      buf = IO::Memory.new
      migration(shell, buf, stop_services: ["monappli"]).run.should eq(PgU::EXIT_OK)
      shell.ran?(MUTATING).should be_false
      shell.writes.should be_empty
      plan = buf.to_s
      plan.should contain("PostgreSQL 18 → 19")
      plan.should contain("/var/db/postgres/data19")
      plan.should contain("--data-checksums")
      plan.should contain("rubygem-pg")
      plan.should contain("service monappli stop")
      plan.should contain("pg_dumpall > /var/db/postgres/pg_dumpall-18-20261014-183000.sql")
      plan.should contain("--missing-stats-only")
    end

    it "reprend un cluster sans checksums avec --no-data-checksums" do
      shell = happy_shell
      shell.stub(/pg_controldata/, "Data page checksum version:           0\n")
      buf = IO::Memory.new
      migration(shell, buf).run.should eq(PgU::EXIT_OK)
      buf.to_s.should contain("--no-data-checksums")
    end

    it "suit postgresql_data de rc.conf et prévoit de le repointer" do
      shell = happy_shell
      shell.stub(/sysrc -n postgresql_data/, "/data/pg/data18\n")
      shell.stub(%r{^cat /data/pg/data18/PG_VERSION}, "18\n")
      shell.stub(%r{^test -e /data/pg/data19$}, exit_code: 1)
      buf = IO::Memory.new
      migration(shell, buf).run.should eq(PgU::EXIT_OK)
      buf.to_s.should contain("sysrc postgresql_data=/data/pg/data19")
    end

    it "rien à faire (code 0) quand le dépôt n'a pas plus récent, sans --to" do
      shell = happy_shell
      shell.stub(/pkg rquery -U '%v %n'/, "18.3 postgresql18-server")
      migration(shell).run.should eq(PgU::EXIT_OK)
      shell.ran?(/pg_controldata/).should be_false
    end
  end

  describe "refus" do
    it "aucun serveur installé" do
      shell = happy_shell
      shell.stub(/^pkg query '%n'$/, "nginx\npostgresql18-client\n")
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err).run.should eq(PgU::EXIT_REFUSED)
      err.to_s.should contain("aucun serveur PostgreSQL")
    end

    it "cible égale ou inférieure à la version installée" do
      migration(happy_shell, to: "18").run.should eq(PgU::EXIT_REFUSED)
      migration(happy_shell, to: "17").run.should eq(PgU::EXIT_REFUSED)
    end

    it "paquet cible absent du dépôt" do
      err = IO::Memory.new
      migration(happy_shell, IO::Memory.new, err, to: "20").run.should eq(PgU::EXIT_REFUSED)
      err.to_s.should contain("postgresql20-server")
    end

    it "dépendant pas encore reconstruit : explique DEFAULT_VERSIONS" do
      shell = happy_shell
      shell.stub(/^pkg rquery -U '%dn' rubygem-pg$/, "ruby32\npostgresql18-client\n")
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err).run.should eq(PgU::EXIT_REFUSED)
      err.to_s.should contain("rubygem-pg (construit contre postgresql18)")
      err.to_s.should contain("DEFAULT_VERSIONS+= pgsql=19")
      shell.ran?(MUTATING).should be_false
    end

    it "dépendant absent du dépôt" do
      shell = happy_shell
      shell.stub(/^pkg rquery -U '%dn' rubygem-pg$/, "")
      shell.stub(/^pkg rquery -U '%n' rubygem-pg$/, "")
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err).run.should eq(PgU::EXIT_REFUSED)
      err.to_s.should contain("rubygem-pg (absent du dépôt)")
    end

    it "nouveau data dir déjà présent" do
      shell = happy_shell
      shell.stub(%r{^test -e /var/db/postgres/data19$}, exit_code: 0)
      migration(shell).run.should eq(PgU::EXIT_REFUSED)
    end

    it "ancien serveur arrêté" do
      shell = happy_shell
      shell.stub(/^service postgresql status$/, exit_code: 1)
      migration(shell).run.should eq(PgU::EXIT_REFUSED)
    end

    it "data checksums illisibles" do
      shell = happy_shell
      shell.stub(/pg_controldata/, "", exit_code: 1)
      migration(shell).run.should eq(PgU::EXIT_REFUSED)
    end

    it "espace insuffisant en mode copie, accepté en --link" do
      shell = happy_shell
      shell.stub(/^df -kP /, "zroot/var/db 4000000 1000 1500000 1% /var/db\n") # 1,4 Go libres, 2 Go requis
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err).run.should eq(PgU::EXIT_REFUSED)
      err.to_s.should contain("espace insuffisant")
      migration(shell, link: true).run.should eq(PgU::EXIT_OK)
    end

    it "profils postgresql multiples" do
      shell = happy_shell
      shell.stub(/sysrc -n postgresql_profiles/, "a b\n")
      migration(shell).run.should eq(PgU::EXIT_REFUSED)
    end

    it "service client inconnu" do
      shell = happy_shell
      shell.stub(/^test -x \/etc\/rc.d\/fantome/, exit_code: 1)
      migration(shell, stop_services: ["fantome"]).run.should eq(PgU::EXIT_REFUSED)
    end

    it "postgresql_data personnalisé sans numéro de version : --new-data exigé" do
      shell = happy_shell
      shell.stub(/sysrc -n postgresql_data/, "/data/pg\n")
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err).run.should eq(PgU::EXIT_REFUSED)
      err.to_s.should contain("--new-data")
    end
  end

  describe "--apply" do
    it "enchaîne les étapes dans l'ordre de UPDATING, gardes comprises" do
      shell = happy_shell
      shell.stub_seq(/^pkg query '%n'$/, [OLD_FAMILY])
      buf = IO::Memory.new
      migration(shell, buf, apply: true, stop_services: ["monappli"]).run.should eq(PgU::EXIT_OK)

      order = [
        /pg_dumpall'? > \/var\/db\/postgres\/pg_dumpall-18-20261014-183000\.sql/,
        /^service monappli stop$/,
        /^service postgresql stop$/,
        %r{pkg create -o /var/db/postgres/pg-upgrade-postgresql18-pkg postgresql18-client postgresql18-contrib postgresql18-server rubygem-pg},
        %r{tar xf /var/db/postgres/pg-upgrade-postgresql18-pkg/postgresql18-server-\[0-9\]\*\.pkg -C /tmp/pg-upgrade},
        /^pkg delete -f -y postgresql18-client postgresql18-contrib postgresql18-server$/,
        /^pkg install -y postgresql19-client postgresql19-contrib postgresql19-server$/,
        /^pkg install -f -y rubygem-pg$/,
        %r{initdb --encoding=UTF8 --lc-collate=C --lc-ctype=C.UTF-8 --data-checksums -D /var/db/postgres/data19 -U postgres},
        /postgresql\.conf postgresql\.auto\.conf pg_hba\.conf/,
        /pg_upgrade .*--check/,
        %r{pg_upgrade -b /tmp/pg-upgrade/usr/local/bin -d /var/db/postgres/data18 -B /usr/local/bin -D /var/db/postgres/data19 -U postgres'$},
        /^service postgresql start$/,
        /vacuumdb --all --analyze-in-stages --missing-stats-only/,
        /^service monappli start$/,
      ]
      positions = order.map { |re| idx(shell, re) }
      positions.should eq(positions.sort)

      # Le client n'est pas extrait (pas de binaire serveur), ni de retour arrière.
      shell.ran?(/tar xf \S*postgresql18-client/).should be_false
      shell.ran?(/^pkg add /).should be_false
      shell.ran?(/sysrc postgresql_data=/).should be_false
      # Commandes postgres sous `su -l` en une seule ligne (csh).
      shell.commands.select(&.includes?("su -l postgres")).none?(&.includes?("\n")).should be_true

      state = shell.writes.find! { |w| w.path == "/var/db/postgres/pg-upgrade.state" }
      state.content.should contain("old_data=/var/db/postgres/data18")
      state.content.should contain("new_data=/var/db/postgres/data19")
      state.mode.should eq("0600")
      buf.to_s.should contain("--cleanup")
    end

    it "pkg install -r : dépôt du plan de pkg (nouveaux), dépôt d'origine (dépendants)" do
      shell = happy_shell
      shell.stub_seq(/^pkg query '%n'$/, [OLD_FAMILY])
      shell.stub(/^pkg install -n /, stdout: "New packages to be INSTALLED:\n" \
                                             "\tgmp: 6.3.0 [aloli]\n" \
                                             "\tpostgresql19-client: 19.1 [FreeBSD-ports]\n" \
                                             "\tpostgresql19-contrib: 19.1 [FreeBSD-ports]\n" \
                                             "\tpostgresql19-server: 19.1 [aloli]\n")
      shell.stub(/^pkg query '%n %R' /, stdout: "rubygem-pg FreeBSD-ports\n")
      migration(shell, apply: true).run.should eq(PgU::EXIT_OK)
      shell.ran?(/^pkg install -r FreeBSD-ports -y postgresql19-client postgresql19-contrib && pkg install -r aloli -y postgresql19-server$/).should be_true
      shell.ran?(/^pkg install -f -r FreeBSD-ports -y rubygem-pg$/).should be_true
      shell.ran?(/install .*gmp/).should be_false
    end

    it "--no-dump : pas de pg_dumpall" do
      shell = happy_shell
      migration(shell, apply: true, dump: false).run.should eq(PgU::EXIT_OK)
      shell.ran?(/pg_dumpall/).should be_false
    end

    it "--link : pg_upgrade --link, check compris" do
      shell = happy_shell
      migration(shell, apply: true, link: true).run.should eq(PgU::EXIT_OK)
      shell.ran?(/pg_upgrade .*--link --check/).should be_true
      shell.ran?(/pg_upgrade .*--link'$/).should be_true
    end

    it "repointe postgresql_data AVANT le démarrage quand il est personnalisé" do
      shell = happy_shell
      shell.stub(/sysrc -n postgresql_data/, "/data/pg/data18\n")
      shell.stub(%r{^cat /data/pg/data18/PG_VERSION}, "18\n")
      shell.stub(%r{^test -e /data/pg/data19$}, exit_code: 1)
      migration(shell, apply: true).run.should eq(PgU::EXIT_OK)
      (idx(shell, /^sysrc postgresql_data=\/data\/pg\/data19$/) < idx(shell, /^service postgresql start$/)).should be_true
    end

    it "conf de l'ancien cluster refusée par le nouveau serveur : confs d'initdb restaurées, migration poursuivie" do
      shell = happy_shell
      shell.stub(/postgres -D \S+ -C data_directory/, exit_code: 1)
      migration(shell, apply: true).run.should eq(PgU::EXIT_OK)
      shell.ran?(/mv \$f\.initdb \$f/).should be_true
    end

    it "sauvegarde en échec : refus, rien d'arrêté" do
      shell = happy_shell
      shell.stub(/pg_dumpall/, exit_code: 1, stderr: "connection refused")
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err, apply: true, stop_services: ["monappli"]).run.should eq(PgU::EXIT_REFUSED)
      shell.ran?(/service \S+ stop/).should be_false
      err.to_s.should contain("rien n'a été modifié")
    end

    it "échec de pg_upgrade --check : retour arrière complet vers 18" do
      shell = happy_shell
      # Après `pkg delete` + `pkg install`, pkg voit la famille 19.
      shell.stub_seq(/^pkg query '%n'$/, [
        OLD_FAMILY,
        "postgresql19-client\npostgresql19-contrib\npostgresql19-server\nnginx\n",
        "nginx\n",
      ])
      shell.stub(/pg_upgrade .*--check/, exit_code: 1, stderr: "lc_collate values for database \"postgres\" do not match")
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err, apply: true, stop_services: ["monappli"]).run.should eq(PgU::EXIT_FAILED)

      shell.ran?(/pg_upgrade .*-U postgres'$/).should be_false # le vrai pg_upgrade n'a pas tourné
      rb = [
        /^pkg delete -f -y postgresql19-client postgresql19-contrib postgresql19-server rubygem-pg$/,
        %r{^pkg add \S+/postgresql18-client-\[0-9\]\*\.pkg \S+/postgresql18-contrib-\S+ \S+/postgresql18-server-\S+ \S+/rubygem-pg-\S+$},
        %r{^rm -rf /var/db/postgres/data19$},
      ]
      positions = rb.map { |re| idx(shell, re) }
      positions.should eq(positions.sort)
      # L'ancien serveur relancé APRÈS le retour arrière des paquets, puis le service client.
      start_pg = shell.commands.rindex!("service postgresql start")
      (start_pg > positions.last).should be_true
      (shell.commands.rindex!("service monappli start") > start_pg).should be_true
      shell.writes.should be_empty
      err.to_s.should contain("retour arrière effectué")
    end

    it "échec du pkg install des nouveaux : retour arrière sans rm du data dir (pas encore créé)" do
      shell = happy_shell
      shell.stub_seq(/^pkg query '%n'$/, [OLD_FAMILY, "nginx\n", "nginx\n"])
      shell.stub(/^pkg install -y postgresql19/, exit_code: 1)
      migration(shell, apply: true).run.should eq(PgU::EXIT_FAILED)
      shell.ran?(/initdb/).should be_false
      shell.ran?(/^rm -rf \/var\/db\/postgres\/data19/).should be_false
      shell.ran?(/^pkg add .*postgresql18-server/).should be_true
      shell.ran?(/rubygem-pg-\[0-9\]/).should be_false # dépendants pas touchés
      shell.ran?(/^service postgresql start$/).should be_true
    end

    it "échec de pg_upgrade --link : pg_control.old remis en place" do
      shell = happy_shell
      shell.stub(/pg_upgrade .*--link'$/, exit_code: 1)
      migration(shell, apply: true, link: true).run.should eq(PgU::EXIT_FAILED)
      shell.ran?(%r{mv /var/db/postgres/data18/global/pg_control\.old /var/db/postgres/data18/global/pg_control}).should be_true
    end

    it "nouveau serveur qui ne démarre pas : PAS de retour arrière automatique" do
      shell = happy_shell
      shell.stub(/^service postgresql start$/, exit_code: 1)
      err = IO::Memory.new
      migration(shell, IO::Memory.new, err, apply: true).run.should eq(PgU::EXIT_FAILED)
      shell.ran?(/^pkg add /).should be_false
      shell.ran?(%r{^rm -rf /var/db/postgres/data19}).should be_false
      err.to_s.should contain("PAS de retour arrière")
    end
  end

  describe "--cleanup" do
    state = "old_major=18\nnew_major=19\nold_data=/var/db/postgres/data18\nnew_data=/var/db/postgres/data19\n" \
            "pkg_dir=/var/db/postgres/pg-upgrade-postgresql18-pkg\nhome=/var/db/postgres\npg_user=postgres\n"

    cleanup_shell = -> do
      shell = FakeShell.new
      shell.stub(%r{^cat /var/db/postgres/pg-upgrade.state}, state)
      shell.stub(/^pkg query '%n'$/, "postgresql19-client\npostgresql19-server\n")
      shell.stub(/show data_directory/, "/var/db/postgres/data19\n")
      shell
    end

    it "dry-run : liste sans supprimer" do
      shell = cleanup_shell.call
      buf = IO::Memory.new
      migration(shell, buf, cleanup: true).run.should eq(PgU::EXIT_OK)
      shell.ran?(/rm -rf/).should be_false
      buf.to_s.should contain("rm -rf /var/db/postgres/data18")
    end

    it "--apply : supprime ancien data dir, paquets, /tmp/pg-upgrade, état — garde le dump" do
      shell = cleanup_shell.call
      migration(shell, cleanup: true, apply: true).run.should eq(PgU::EXIT_OK)
      shell.ran?(%r{^rm -rf /var/db/postgres/data18 /var/db/postgres/pg-upgrade-postgresql18-pkg /tmp/pg-upgrade /var/db/postgres/delete_old_cluster.sh /var/db/postgres/pg-upgrade.state$}).should be_true
      shell.ran?(/pg_dumpall/).should be_false
    end

    it "refuse si la nouvelle version n'est pas celle installée" do
      shell = cleanup_shell.call
      shell.stub(/^pkg query '%n'$/, "postgresql18-server\n")
      migration(shell, cleanup: true, apply: true).run.should eq(PgU::EXIT_REFUSED)
      shell.ran?(/rm -rf/).should be_false
    end

    it "refuse si le serveur en service n'utilise pas le nouveau data dir" do
      shell = cleanup_shell.call
      shell.stub(/show data_directory/, "/var/db/postgres/data18\n")
      migration(shell, cleanup: true, apply: true).run.should eq(PgU::EXIT_REFUSED)
      shell.ran?(/rm -rf/).should be_false
    end

    it "refuse sans migration enregistrée" do
      shell = cleanup_shell.call
      shell.stub(%r{^cat /var/db/postgres/pg-upgrade.state}, "", exit_code: 1)
      migration(shell, cleanup: true, apply: true).run.should eq(PgU::EXIT_REFUSED)
    end
  end
end
