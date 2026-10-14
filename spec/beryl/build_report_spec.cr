require "file_utils"
require "../spec_helper"
require "../../src/beryl/build_report"

private alias BR = Beryl::BuildReport

private LOGS_RUN  = "/usr/local/poudriere/data/logs/bulk/fbsd151amd64-default/2026-10-14_22h45m38s"
private LOGS_FAIL = "/usr/local/poudriere/data/logs/bulk/fbsd151amd64-default/2026-10-15_03h00m05s"

private def epoch(*args) : Int64
  Time.utc(*args).to_unix
end

# Échantillon RÉEL (14 oct. 2026, noms d'overlays neutralisés) : build en
# cours, lu par le script distant.
private def running_output : String
  status = ["-", "default", "fbsd151amd64", "2026-10-14_22h45m38s", "parallel_build",
            "68", "0", "3", "64", "0", "0", "0", "1", "00:15:51", LOGS_RUN].join('\t')
  <<-OUT
  @@NOW #{epoch(2026, 10, 14, 23, 1, 30)}
  @@FILE .beryl-build-15.lock #{epoch(2026, 10, 14, 22, 45, 0)} 0
  @@FILE .beryl-build-15.log #{epoch(2026, 10, 14, 23, 0, 0)} 21633
  @@FILE .beryl-build-15.overlays #{epoch(2026, 10, 13, 14, 41, 0)} 95
  @@BEGIN .beryl-build-15.overlays
  maison 2c8175fc1bca02ea902de27d492c0e017d546b9a
  partenaire cce6262c6eb45a86418614696c5450e365a9cd2a

  @@BEGIN .beryl-build-15.log.events
  [00:00:02] Logs: #{LOGS_RUN}
  [00:07:46] [01] [00:00:00] Building   lang/crystal | crystal-1.21.0
  [00:14:03] [01] [00:06:17] Finished   lang/crystal | crystal-1.21.0: Success
  [00:14:03] [01] [00:00:00] Building   sysutils/partiduo-agent-devel | partiduo-agent-devel-0.1.12_4
  [00:14:03] [02] [00:00:00] Building   finance/partiduo-admin-devel | partiduo-admin-devel-0.1.12_2
  [00:14:24] [01] [00:00:21] Finished   sysutils/partiduo-agent-devel | partiduo-agent-devel-0.1.12_4: Success
  @@BEGIN .beryl-build-15.log.tail
  [00:14:24] [01] [00:00:21] Finished   sysutils/partiduo-agent-devel | partiduo-agent-devel-0.1.12_4: Success

  @@BEGIN poudriere-status
  #{status}
  @@END
  OUT
end

# Build en ÉCHEC : un paquet `Failed`, un dépendant sauté, un ignoré, bilan
# poudriere en fin de journal ; `.overlays` plus ancien que le journal.
private def failed_output : String
  <<-OUT
  @@NOW #{epoch(2026, 10, 15, 4, 0, 0)}
  @@FILE .beryl-build-15.log #{epoch(2026, 10, 15, 3, 41, 12)} 30411
  @@FILE .beryl-build-15.overlays #{epoch(2026, 10, 13, 14, 41, 0)} 95
  @@BEGIN .beryl-build-15.overlays
  maison 2c8175fc1bca02ea902de27d492c0e017d546b9a
  @@BEGIN .beryl-build-15.log.events
  [00:00:01] Logs: #{LOGS_FAIL}
  [00:00:40] Building 5 packages using up to 2 builders
  [00:00:39] Ignoring   misc/vieux | vieux-1.0: is marked as broken: ne compile plus
  [00:01:00] [01] [00:00:00] Building   lang/crystal | crystal-1.21.0
  [00:01:00] [02] [00:00:00] Building   www/site-maison | site-maison-2.3
  [00:04:02] [02] [00:03:02] Finished   www/site-maison | site-maison-2.3: Failed: \e[0;35mbuild\e[0m
  [00:04:02] [02] [00:00:00] Skipping   www/site-maison-doc | site-maison-doc-2.3: Dependent port www/site-maison | site-maison-2.3 failed
  [00:21:00] [01] [00:20:00] Finished   lang/crystal | crystal-1.21.0: Success
  [00:41:10] [fbsd151amd64-default] [2026-10-15_03h00m05s] [committing] Time: 00:41:09
  [00:41:10] Queued: 5 Inspected: 0 Ignored: 1 Built: 1 Failed: 1 Skipped: 1 Fetched: 0 Remaining: 1
  [00:41:11] Error: Build failed in phase: build
  @@BEGIN .beryl-build-15.log.tail
  [00:41:10] Failed ports: www/site-maison:build
  [00:41:10] Skipped ports: www/site-maison-doc
  [00:41:11] Error: Build failed in phase: build
  @@BEGIN poudriere-status
  @@END
  OUT
end

# Build TERMINÉ avec succès (lock absent, ligne finale du script).
private def success_output : String
  status = ["-", "default", "fbsd151amd64", "2026-10-14_22h45m38s", "done",
            "68", "0", "3", "65", "0", "0", "0", "0", "00:20:12", LOGS_RUN].join('\t')
  <<-OUT
  @@NOW #{epoch(2026, 10, 15, 8, 0, 0)}
  @@FILE .beryl-build-15.log #{epoch(2026, 10, 14, 23, 6, 0)} 23001
  @@FILE .beryl-build-15.overlays #{epoch(2026, 10, 14, 23, 6, 0)} 95
  @@BEGIN .beryl-build-15.overlays
  maison 3d9e0a1b2c3d4e5f60718293a4b5c6d7e8f90123
  partenaire cce6262c6eb45a86418614696c5450e365a9cd2a
  @@BEGIN .beryl-build-15.log.events
  [00:00:02] Logs: #{LOGS_RUN}
  [00:07:46] [01] [00:00:00] Building   lang/crystal | crystal-1.21.0
  [00:14:03] [01] [00:06:17] Finished   lang/crystal | crystal-1.21.0: Success
  [00:14:03] [02] [00:00:00] Building   finance/partiduo-admin-devel | partiduo-admin-devel-0.1.12_2
  [00:19:40] [02] [00:05:37] Finished   finance/partiduo-admin-devel | partiduo-admin-devel-0.1.12_2: Success
  [00:19:50] [01] [00:00:00] Building   www/zz-petit | zz-petit-1.0
  [00:19:58] [01] [00:00:08] Finished   www/zz-petit | zz-petit-1.0: Success
  poudriere-build 15.1 OK (2026-10-14T23:06:00Z)
  @@BEGIN .beryl-build-15.log.tail
  poudriere-build 15.1 OK (2026-10-14T23:06:00Z)
  @@BEGIN poudriere-status
  #{status}
  @@END
  OUT
end

describe Beryl::BuildReport do
  describe ".seconds" do
    it "lit les durées poudriere, jours compris" do
      BR.seconds("00:06:17").should eq(377)
      BR.seconds("1D:02:00:00").should eq(93600)
      BR.seconds("n/a").should be_nil
      BR.seconds(nil).should be_nil
    end
  end

  describe ".human" do
    it "rend une durée en français" do
      BR.human(21).should eq("21 s")
      BR.human(377).should eq("6 min 17 s")
      BR.human(3900).should eq("1 h 05 min")
      BR.human(93600).should eq("1 j 02 h")
      BR.human(nil).should eq("?")
    end
  end

  describe ".parse_log" do
    it "suit chaque paquet : en construction, terminé, durée" do
      info = BR.parse_log(BR.parse_remote(running_output).sections[".beryl-build-15.log.events"])
      info.logs_dir.should eq(LOGS_RUN)
      info.ok.should be_false
      by = info.packages.to_h { |p| {p.pkgname, p} }
      by["crystal-1.21.0"].result.should eq("success")
      by["crystal-1.21.0"].duration.should eq(377)
      by["partiduo-agent-devel-0.1.12_4"].duration.should eq(21)
      admin = by["partiduo-admin-devel-0.1.12_2"]
      admin.result.should eq("building")
      admin.origin.should eq("finance/partiduo-admin-devel")
      admin.started.should eq(14 * 60 + 3)
      admin.builder.should eq(2)
    end

    it "échecs (couleurs retirées), sautés, ignorés, bilan, erreurs" do
      info = BR.parse_log(BR.parse_remote(failed_output).sections[".beryl-build-15.log.events"])
      by = info.packages.to_h { |p| {p.pkgname, p} }
      by["site-maison-2.3"].result.should eq("failed")
      by["site-maison-2.3"].detail.should eq("build")
      by["site-maison-2.3"].duration.should eq(182)
      by["site-maison-doc-2.3"].result.should eq("skipped")
      by["site-maison-doc-2.3"].detail.to_s.should contain("Dependent port www/site-maison")
      by["vieux-1.0"].result.should eq("ignored")
      info.to_build.should eq(5)
      info.total_time.should eq(41 * 60 + 9)
      c = info.final_counters.not_nil!
      {c.queued, c.built, c.failed, c.skipped, c.ignored, c.remaining}.should eq({5, 1, 1, 1, 1, 1})
      info.errors.should eq(["[00:41:11] Error: Build failed in phase: build"])
    end

    it "un plantage (Crashed) compte comme un échec ; « Nothing to do » comme inspecté" do
      info = BR.parse_log(<<-LOG)
        [00:02:00] [01] [00:01:00] Crashed    devel/x | x-1: Failed: stage
        [00:02:00] [02] [00:00:01] Finished   devel/y | y-2: Nothing to do
        =>> Building   devel/z | z-3
        LOG
      info.packages.map { |p| {p.pkgname, p.result} }.should eq([{"x-1", "failed"}, {"y-2", "inspected"}, {"z-3", "building"}])
      info.packages.first.detail.should eq("plantage (stage)")
    end
  end

  describe ".parse_status" do
    it "lit le mode script (-H) et l'affichage normal, sans l'en-tête" do
      normal = <<-OUT
        SET PORTS   JAIL         BUILD                STATUS         QUEUE INSPECT IGNORE BUILT FAIL SKIP FETCH REMAIN TIME     LOGS
        -   default fbsd151amd64 2026-10-14_22h45m38s parallel_build    68       0      3    64    0    0     0      1 00:15:51 #{LOGS_RUN}
        OUT
      rows = BR.parse_status(normal)
      rows.size.should eq(1)
      rows.first.status.should eq("parallel_build")
      rows.first.built.should eq(64)
      rows.first.remaining.should eq(1)
      rows.first.logs.should eq(LOGS_RUN)
      BR.parse_status(BR.parse_remote(running_output).sections["poudriere-status"]).first.time.should eq("00:15:51")
    end
  end

  describe ".pick_row" do
    it "retient la ligne du build du journal, pas celle d'une autre jail ou d'un vieux build" do
      rows = [
        BR::StatusRow.new("-", "default", "fbsd150amd64", "2026-07-01_03h00m00s", "done", 1, 0, 0, 1, 0, 0, 0, 0, "00:01:00", nil),
        BR::StatusRow.new("-", "default", "fbsd151amd64", "2026-10-14_22h45m38s", "done", 1, 0, 0, 1, 0, 0, 0, 0, "00:20:00", nil),
      ]
      BR.pick_row(rows, "15", LOGS_RUN, false).not_nil!.jail.should eq("fbsd151amd64")
      BR.pick_row(rows, "14", LOGS_RUN, false).should be_nil
      # Build terminé dont le bulk n'a pas démarré : aucune ligne fiable.
      BR.pick_row(rows, "15", nil, false).should be_nil
    end
  end

  describe ".report" do
    it "build EN COURS (échantillon réel)" do
      r = BR.report(BR.parse_remote(running_output), "15", "/usr/local/poudriere/data/packages")
      r.state.should eq(BR::State::Running)
      r.build.should eq("2026-10-14_22h45m38s")
      r.phase.should eq("parallel_build")
      r.elapsed.should eq(15 * 60 + 51)
      r.started_at.should eq(epoch(2026, 10, 14, 22, 45, 0))
      r.counters_source.should eq("poudriere status")
      r.counters.not_nil!.built.should eq(64)
      r.overlays.should eq([{"maison", "2c8175fc1bca02ea902de27d492c0e017d546b9a"},
                            {"partenaire", "cce6262c6eb45a86418614696c5450e365a9cd2a"}])
      BR.exit_code([r]).should eq(0)
    end

    it "build en ÉCHEC : journal plus récent que .overlays, sans ligne OK" do
      r = BR.report(BR.parse_remote(failed_output), "15", "/pk")
      r.state.should eq(BR::State::Failed)
      r.ended_at.should eq(epoch(2026, 10, 15, 3, 41, 12))
      r.duration.should eq(41 * 60 + 9)
      r.counters_source.should eq("bilan du journal")
      r.build.should eq("2026-10-15_03h00m05s")
      failed = r.by_result("failed")
      failed.map(&.error_log).should eq(["#{LOGS_FAIL}/logs/errors/site-maison-2.3.log"])
      BR.exit_code([r]).should eq(1)
    end

    it "build TERMINÉ avec succès" do
      r = BR.report(BR.parse_remote(success_output), "15")
      r.state.should eq(BR::State::Success)
      r.duration.should eq(20 * 60 + 12)
      r.phase.should eq("done")
      BR.exit_code([r]).should eq(0)
    end

    it "succès si .overlays est plus récent que le journal (ancien journal sans ligne OK)" do
      text_out = failed_output.sub("@@FILE .beryl-build-15.overlays #{epoch(2026, 10, 13, 14, 41, 0)}",
        "@@FILE .beryl-build-15.overlays #{epoch(2026, 10, 15, 3, 42, 0)}")
      BR.report(BR.parse_remote(text_out), "15").state.should eq(BR::State::Success)
    end

    it "JAMAIS construit : aucun fichier" do
      remote = BR.parse_remote("@@NOW 1\n@@BEGIN poudriere-status\n@@END\n")
      BR.majors(remote).should be_empty
      reports = BR.reports(remote, "15")
      reports.first.state.should eq(BR::State::Never)
      BR.exit_code(reports).should eq(0)
      BR.render("pkg.example.net", "/pk", reports, location: Time::Location::UTC).should contain("Majeur 15 — jamais construit")
    end

    it "lock présent avant le bulk : phase de préparation" do
      text_out = "@@NOW 1000\n@@FILE .beryl-build-15.lock 900 0\n@@FILE .beryl-build-15.log 990 10\n" \
                 "@@BEGIN .beryl-build-15.log.tail\nUpdating portstree \"default\"\n@@END\n"
      r = BR.report(BR.parse_remote(text_out), "15")
      r.state.should eq(BR::State::Running)
      r.phase.to_s.should contain("préparation")
      BR.render("h", "/pk", [r], location: Time::Location::UTC).should contain("Updating portstree")
    end
  end

  describe ".majors" do
    it "détecte tous les majeurs présents, triés" do
      remote = BR.parse_remote("@@FILE .beryl-build-16.log 1 1\n@@FILE .beryl-build-15.overlays 1 1\n@@FILE .beryl-build-15.lock 1 0\n")
      BR.majors(remote).should eq(["15", "16"])
    end
  end

  describe ".render" do
    it "build en cours : état, compteurs, paquet en construction avec sa durée, dernier succès" do
      reports = BR.reports(BR.parse_remote(running_output), nil, "/usr/local/poudriere/data/packages")
      text = BR.render("pkg.example.net", "/usr/local/poudriere/data/packages", reports, location: Time::Location::UTC)
      text.should contain("Majeur 15 — EN COURS depuis 16 min 30 s")
      text.should contain("build 2026-10-14_22h45m38s · jail fbsd151amd64 · phase parallel_build · bulk 15 min 51 s")
      text.should contain("file 68 · construits 64 · échecs 0 · ignorés 3 · sautés 0 · restants 1  (poudriere status)")
      text.should match(/En construction \(1\) :\n    finance\/partiduo-admin-devel  partiduo-admin-devel-0\.1\.12_2  depuis 1 min 48 s/)
      text.should match(/6 min 17 s  lang\/crystal\s+crystal-1\.21\.0\n\s+21 s  sysutils/)
      text.should contain("Dernier build réussi : 2026-10-13 14:41 — maison 2c8175f, partenaire cce6262")
    end

    it "échecs EN TÊTE avec leur journal, puis fin du journal du script" do
      reports = BR.reports(BR.parse_remote(failed_output), "15", "/pk")
      text = BR.render("pkg.example.net", "/pk", reports, location: Time::Location::UTC)
      text.should contain("Majeur 15 — ÉCHEC, terminé le 2026-10-15 03:41 (bulk 41 min 09 s)")
      text.should contain("✗ www/site-maison  site-maison-2.3 — phase build (après 3 min 02 s)")
      text.should contain("journal : #{LOGS_FAIL}/logs/errors/site-maison-2.3.log")
      text.index!("ÉCHECS").should be < text.index!("Construits")
      text.should contain("Sautés (1)")
      text.should contain("Ignorés (1)")
      text.should contain("Fin du journal (/pk/.beryl-build-15.log)")
    end

    it "tri par durée (défaut) ou par nom ; liste tronquée sans --all" do
      reports = BR.reports(BR.parse_remote(success_output), nil)
      by_duration = BR.render("h", "/pk", reports, location: Time::Location::UTC)
      by_duration.index!("lang/crystal").should be < by_duration.index!("finance/partiduo-admin-devel")
      by_name = BR.render("h", "/pk", reports, sort: "name", location: Time::Location::UTC)
      by_name.index!("finance/partiduo-admin-devel").should be < by_name.index!("lang/crystal")
      by_name.should contain("SUCCÈS, terminé le 2026-10-14 23:06 (bulk 20 min 12 s)")

      many = (1..12).map { |i| "[00:00:#{i.to_s.rjust(2, '0')}] [01] [00:00:#{i.to_s.rjust(2, '0')}] Finished   cat/p#{i} | p#{i}-1: Success" }.join('\n')
      remote = BR.parse_remote("@@NOW 10\n@@FILE .beryl-build-15.log 5 1\n@@BEGIN .beryl-build-15.log.events\n#{many}\npoudriere-build 15.1 OK\n@@END\n")
      short = BR.render("h", "/pk", BR.reports(remote, nil), location: Time::Location::UTC)
      short.should contain("… et 2 autres (--all)")
      short.should_not contain("cat/p1 ")
      BR.render("h", "/pk", BR.reports(remote, nil), all: true, location: Time::Location::UTC).should_not contain("--all")
    end
  end

  describe ".to_json" do
    it "sortie machine : état, compteurs, paquets, dernier succès" do
      reports = BR.reports(BR.parse_remote(failed_output), nil, "/pk")
      json = JSON.parse(BR.to_json("pkg.example.net", "/pk", reports))
      m = json["majors"][0]
      m["state"].should eq("failed")
      m["counters"]["failed"].should eq(1)
      m["packages"].as_a.find! { |p| p["result"] == "failed" }["error_log"].should eq("#{LOGS_FAIL}/logs/errors/site-maison-2.3.log")
      m["last_success"]["overlays"]["maison"].should eq("2c8175fc1bca02ea902de27d492c0e017d546b9a")
    end
  end

  describe ".remote_script" do
    it "rassemble fichiers, overlays, journal et poudriere status (joué avec sh et un faux poudriere)" do
      dir = File.tempname("beryl-build-status")
      bin = File.join(dir, "bin")
      pkgdir = File.join(dir, "packages")
      Dir.mkdir_p(bin)
      Dir.mkdir_p(pkgdir)
      File.write(File.join(bin, "poudriere"), "#!/bin/sh\nprintf '%s\\t' - default fbsd151amd64 B done 1 0 0 1 0 0 0 0 00:00:09; echo /l\n")
      File.chmod(File.join(bin, "poudriere"), 0o755)
      File.write(File.join(pkgdir, ".beryl-build-15.overlays"), "maison abc\n")
      File.write(File.join(pkgdir, ".beryl-build-15.log"),
        "bruit\n[00:00:01] [01] [00:00:01] Finished   cat/p | p-1: Success\npoudriere-build 15.1 OK (x)\n")
      buf = IO::Memory.new
      Process.run("sh", ["-c", BR.remote_script(pkgdir)], env: {"PATH" => "#{bin}:#{ENV["PATH"]}"}, output: buf, error: buf)
      remote = BR.parse_remote(buf.to_s)
      BR.majors(remote).should eq(["15"])
      remote.files[".beryl-build-15.overlays"].size.should eq(11)
      remote.sections[".beryl-build-15.log.events"].should_not contain("bruit")
      r = BR.report(remote, "15")
      r.state.should eq(BR::State::Success)
      r.packages.map(&.pkgname).should eq(["p-1"])
      r.duration.should be_nil # build du journal inconnu : la ligne de status n'est pas reprise
      BR.parse_status(remote.sections["poudriere-status"]).first.logs.should eq("/l")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "répertoire des paquets absent → @@NOPKGDIR ; --major restreint les fichiers" do
      BR.parse_remote("@@NOPKGDIR\n").pkgdir_missing.should be_true
      BR.remote_script("/pk", "15").should contain(".beryl-build-15.lock")
      BR.remote_script("/pk", "15").should_not contain(".beryl-build-*")
    end
  end
end
