require "json"

# État LISIBLE des builds de paquets d'un builder poudriere géré par la
# primitive `poudriere-build` (cf. `Beryl::Apply::PoudriereBuild`), utilisé
# par `beryl build-status`. Tout est PUR ici (aucun SSH) : script de lecture
# envoyé au builder, analyse de sa sortie, du journal de build, de
# `poudriere status`, calcul de l'état et rendu texte/JSON.
#
# Fichiers de la primitive, dans le répertoire des paquets :
#
# * `.beryl-build-<majeur>.lock` : présent pendant un build ;
# * `.beryl-build-<majeur>.log` : sortie du script de build (dont celle de
#   `poudriere bulk`), écrasé à chaque build ;
# * `.beryl-build-<majeur>.overlays` : une ligne `<overlay> <commit>` par
#   overlay, écrit seulement en fin de build RÉUSSI (sa date = fin du
#   dernier build réussi).
#
# Formats poudriere lus (src/share/poudriere/common.sh, `job_msg_status`) :
#
#     [00:07:46] [01] [00:00:00] Building   lang/crystal | crystal-1.21.0
#     [00:14:03] [01] [00:06:17] Finished   lang/crystal | crystal-1.21.0: Success
#     [00:20:11] [02] [00:03:02] Finished   www/foo | foo-1.2: Failed: build
#
# 1ʳᵉ durée = temps écoulé depuis le début du bulk, 2ᵉ = durée du paquet sur
# son builder. Journal d'erreur d'un paquet : `<LOGS>/logs/errors/<pkg>.log`.
module Beryl::BuildReport
  extend self

  # Lignes de fin de journal rapportées (dernières lignes du script).
  TAIL_LINES = 20

  # Paquets terminés affichés sans `--all` (les plus longs).
  TOP = 10

  # Durée poudriere : `[ND:]HH:MM:SS` (`calculate_duration`).
  DURATION = /(?:\d+D:)?\d+:\d\d:\d\d/

  # Ligne d'événement d'un paquet. Les préfixes `[écoulé]`, `[builder]` et
  # `[durée du paquet]` sont optionnels (absents hors builder, ou remplacés
  # par `=>>` quand poudriere n'affiche pas le temps écoulé).
  EVENT = /\A(?:\[(?<at>#{DURATION.source})\]\s+)?(?:=>>\s+)?(?:\[(?<builder>\d+)\]\s+)?(?:\[(?<job>#{DURATION.source})\]\s+)?(?<kind>Building|Finished|Crashed|Skipping|Ignoring)\s+(?<origin>\S+) \| (?<pkg>[^\s:]+)(?::\s*(?<msg>.*))?\z/

  # Motif `grep -E` côté builder : seules les lignes utiles du journal
  # voyagent (événements des paquets, chemin des journaux, bilan, erreurs,
  # fin du script). ASCII seulement (le journal peut être en C locale).
  LOG_PATTERN = "(Building|Finished|Crashed|Skipping|Ignoring) +[^ ]+ [|] |Logs: |Error:|Queued: [0-9]|Time: [0-9]|packages using up to|poudriere-build [^ ]+ OK|en cours [(]lock[)]"

  enum State
    Running
    Success
    Failed
    Never

    def label : String
      case self
      in Running then "en cours"
      in Success then "succès"
      in Failed  then "échec"
      in Never   then "jamais construit"
      end
    end
  end

  # Un paquet vu dans le journal du build.
  class Package
    include JSON::Serializable

    getter origin : String
    getter pkgname : String
    # building | success | failed | skipped | ignored | inspected
    property result : String = "building"
    # Phase en échec, raison d'un `Ignoring`, cause d'un `Skipping`…
    property detail : String? = nil
    # Temps écoulé du bulk au lancement du paquet (s).
    property started : Int32? = nil
    # Durée du paquet sur son builder (s).
    property duration : Int32? = nil
    property builder : Int32? = nil
    # Journal d'erreur poudriere (échecs seulement).
    property error_log : String? = nil

    def initialize(@origin : String, @pkgname : String)
    end
  end

  # Compteurs poudriere (colonnes de `poudriere status`).
  record Counters, queued : Int32?, built : Int32, failed : Int32, ignored : Int32,
    skipped : Int32, inspected : Int32, fetched : Int32, remaining : Int32? do
    include JSON::Serializable
  end

  # Une ligne de `poudriere status -H -f -l`.
  record StatusRow, set : String, ports : String, jail : String, build : String,
    status : String, queued : Int32?, inspected : Int32?, ignored : Int32?,
    built : Int32?, failed : Int32?, skipped : Int32?, fetched : Int32?,
    remaining : Int32?, time : String, logs : String?

  record FileStat, mtime : Int64, size : Int64

  # Ce que le journal de build apprend.
  class LogInfo
    getter packages = [] of Package
    property logs_dir : String? = nil
    property ok = false
    property lock_skip = false
    getter errors = [] of String
    property last_elapsed : Int32? = nil
    property total_time : Int32? = nil
    property final_counters : Counters? = nil
    property to_build : Int32? = nil
  end

  # Sortie du script de lecture, découpée.
  class Remote
    property now : Int64 = 0_i64
    property pkgdir_missing = false
    getter files = {} of String => FileStat
    getter sections = {} of String => String
  end

  # État d'un majeur, prêt à afficher.
  class Report
    getter major : String
    property state : State = State::Never
    property build : String? = nil
    property jail : String? = nil
    property phase : String? = nil
    property started_at : Int64? = nil
    property ended_at : Int64? = nil
    property duration : Int32? = nil
    property elapsed : Int32? = nil
    property counters : Counters? = nil
    property counters_source : String? = nil
    property packages = [] of Package
    property logs_dir : String? = nil
    property errors = [] of String
    property tail = [] of String
    property last_success_at : Int64? = nil
    property overlays = [] of {String, String}
    property lock_skip = false
    property now : Int64 = 0_i64
    property log_path : String? = nil

    def initialize(@major : String)
    end

    def running? : Bool
      state.running?
    end

    def by_result(result : String) : Array(Package)
      packages.select { |p| p.result == result }
    end
  end

  # ---------- script distant ----------

  # Script (sh POSIX, lecture seule) qui rassemble en UNE connexion : dates
  # et tailles des fichiers de la primitive, contenu de `.overlays`, lignes
  # utiles et fin du journal, `poudriere status`. `major` nil = tous les
  # majeurs présents. Multi-ligne : transporté par `Apply.sh_line` (base64),
  # donc sûr sous un shell de connexion csh.
  def remote_script(pkgdir : String, major : String? = nil) : String
    base = ".beryl-build-#{major || "*"}"
    <<-SH
      cd #{Process.quote(pkgdir)} 2>/dev/null || { echo '@@NOPKGDIR'; exit 0; }
      echo "@@NOW $(date +%s)"
      for f in #{base}.lock #{base}.log #{base}.overlays; do
        [ -e "$f" ] && echo "@@FILE $f $(stat -f '%m %z' "$f")"
      done
      for f in #{base}.overlays; do
        [ -f "$f" ] && { echo "@@BEGIN $f"; cat "$f"; echo; }
      done
      for f in #{base}.log; do
        [ -f "$f" ] || continue
        echo "@@BEGIN $f.events"
        grep -aE #{Process.quote(LOG_PATTERN)} "$f"
        echo "@@BEGIN $f.tail"
        tail -n #{TAIL_LINES} "$f"
        echo
      done
      echo '@@BEGIN poudriere-status'
      poudriere status -H -f -l 2>/dev/null
      echo '@@END'
      SH
  end

  # Sortie du script → fichiers + sections.
  def parse_remote(text : String) : Remote
    remote = Remote.new
    current : String? = nil
    buf = String::Builder.new
    flush = ->(name : String?) do
      if n = name
        remote.sections[n] = buf.to_s
      end
      buf = String::Builder.new
    end
    text.each_line do |line|
      if line.starts_with?("@@")
        parts = line.split
        case parts[0]
        when "@@NOPKGDIR"
          remote.pkgdir_missing = true
        when "@@NOW"
          remote.now = parts[1]?.try(&.to_i64?) || 0_i64
        when "@@FILE"
          if parts.size >= 4 && (m = parts[2].to_i64?) && (s = parts[3].to_i64?)
            remote.files[parts[1]] = FileStat.new(m, s)
          end
        when "@@BEGIN"
          flush.call(current)
          current = parts[1]?
        when "@@END"
          flush.call(current)
          current = nil
        end
        next
      end
      buf << line << '\n' if current
    end
    flush.call(current)
    remote
  end

  # Majeurs présents (d'après les fichiers trouvés), triés numériquement.
  def majors(remote : Remote) : Array(String)
    remote.files.keys.compact_map { |f| f.match(/\A\.beryl-build-(\d+)\.(?:lock|log|overlays)\z/).try(&.[1]) }
      .uniq.sort_by(&.to_i)
  end

  # ---------- analyse ----------

  def strip_ansi(text : String) : String
    text.gsub(/\e\[[0-9;]*[A-Za-z]/, "")
  end

  # "00:06:17" → 377 ; "1D:02:00:00" → 93600. nil si illisible.
  def seconds(text : String?) : Int32?
    return unless text
    days = 0
    rest = text
    if m = text.match(/\A(\d+)D:(.*)\z/)
      days = m[1].to_i
      rest = m[2]
    end
    parts = rest.split(':')
    return unless parts.size == 3 && parts.all?(&.to_i?)
    days * 86400 + parts[0].to_i * 3600 + parts[1].to_i * 60 + parts[2].to_i
  end

  # Lignes du journal (filtrées ou non) → paquets, chemin des journaux,
  # bilan, erreurs. Un paquet relancé (même nom) remplace le précédent.
  def parse_log(text : String) : LogInfo
    info = LogInfo.new
    by_pkg = {} of String => Package
    text.each_line do |raw|
      line = strip_ansi(raw).strip
      next if line.empty?
      if m = line.match(/\A\[(#{DURATION.source})\]/)
        info.last_elapsed = seconds(m[1])
      end
      if m = EVENT.match(line)
        pkgname = m["pkg"]
        pkg = by_pkg[pkgname]? || begin
          p = Package.new(m["origin"], pkgname)
          by_pkg[pkgname] = p
          info.packages << p
          p
        end
        msg = m["msg"]?.try(&.strip).presence
        pkg.builder = m["builder"]?.try(&.to_i)
        case m["kind"]
        when "Building"
          pkg.result = "building"
          pkg.started = seconds(m["at"]?)
          pkg.duration = nil
          pkg.detail = nil
        when "Finished"
          pkg.duration = seconds(m["job"]?)
          if msg && (f = msg.match(/\AFailed:\s*(.*)\z/))
            pkg.result = "failed"
            pkg.detail = f[1].strip.presence
          elsif msg == "Nothing to do"
            pkg.result = "inspected"
          else
            pkg.result = "success"
            pkg.detail = msg unless msg.nil? || msg == "Success"
          end
        when "Crashed"
          pkg.result = "failed"
          pkg.duration = seconds(m["job"]?)
          phase = msg.try { |x| x.sub(/\AFailed:\s*/, "") }
          pkg.detail = "plantage#{phase ? " (#{phase})" : ""}"
        when "Skipping"
          pkg.result = "skipped"
          pkg.detail = msg
        when "Ignoring"
          pkg.result = "ignored"
          pkg.detail = msg
        end
      elsif m = line.match(/Logs: (\S+)/)
        info.logs_dir = m[1]
      elsif line.matches?(/poudriere-build \S+ OK/)
        info.ok = true
      elsif line.includes?("en cours (lock)")
        info.lock_skip = true
      elsif line.includes?("Queued: ")
        n = ->(key : String) { line.match(/#{key}: (\d+)/).try(&.[1].to_i) }
        info.final_counters = Counters.new(n.call("Queued"), n.call("Built") || 0, n.call("Failed") || 0,
          n.call("Ignored") || 0, n.call("Skipped") || 0, n.call("Inspected") || 0,
          n.call("Fetched") || 0, n.call("Remaining"))
      elsif m = line.match(/Time: (#{DURATION.source})/)
        info.total_time = seconds(m[1])
      elsif m = line.match(/Building (\d+) packages using up to/)
        info.to_build = m[1].to_i
      elsif line.includes?("Error:")
        info.errors << line
      end
    end
    info
  end

  # `poudriere status -H` (tabulations) ou affichage normal (espaces).
  # L'en-tête et les lignes illisibles sont ignorés.
  def parse_status(text : String) : Array(StatusRow)
    text.each_line.compact_map do |raw|
      line = strip_ansi(raw).rstrip
      next if line.strip.empty?
      f = line.includes?('\t') ? line.split('\t') : line.split
      next if f.size < 14 || f[0] == "SET"
      i = ->(k : Int32) { f[k].to_i? }
      StatusRow.new(f[0], f[1], f[2], f[3], f[4], i.call(5), i.call(6), i.call(7), i.call(8),
        i.call(9), i.call(10), i.call(11), i.call(12), f[13], f[14]?.try(&.strip).presence)
    end.to_a
  end

  # `.overlays` → [{nom, commit}] dans l'ordre du fichier.
  def parse_overlays(text : String) : Array({String, String})
    text.each_line.compact_map do |line|
      parts = line.split
      {parts[0], parts[1]} if parts.size >= 2
    end.to_a
  end

  # Ligne de `poudriere status` correspondant au build : même nom de build
  # que le journal (`Logs: …/<BUILD>`), sinon — build en cours seulement —
  # la plus récente non terminée d'une jail du majeur (`fbsd<majeur><mineure><arch>`).
  def pick_row(rows : Array(StatusRow), major : String, logs_dir : String?, running : Bool) : StatusRow?
    mine = rows.select { |r| r.jail.matches?(/\Afbsd#{major}\d*[a-z]/) }
    if dir = logs_dir
      build = File.basename(dir)
      if row = mine.find { |r| r.build == build }
        return row
      end
    end
    return unless running
    mine.reject { |r| r.status.starts_with?("done") }.max_by?(&.build)
  end

  def counters_from_row(row : StatusRow) : Counters
    Counters.new(row.queued, row.built || 0, row.failed || 0, row.ignored || 0,
      row.skipped || 0, row.inspected || 0, row.fetched || 0, row.remaining)
  end

  # Compteurs recomptés depuis les événements du journal (dernier recours).
  def counters_from_packages(pkgs : Array(Package), to_build : Int32?) : Counters
    c = ->(r : String) { pkgs.count { |p| p.result == r } }
    built, failed, skipped = c.call("success"), c.call("failed"), c.call("skipped")
    remaining = to_build.try { |t| {t - built - failed - skipped, 0}.max }
    Counters.new(nil, built, failed, c.call("ignored"), skipped, c.call("inspected"), 0, remaining)
  end

  # Rapport d'un majeur à partir de la lecture distante.
  def report(remote : Remote, major : String, pkgdir : String = "") : Report
    r = Report.new(major)
    r.now = remote.now
    base = ".beryl-build-#{major}"
    lock = remote.files["#{base}.lock"]?
    logf = remote.files["#{base}.log"]?
    ovf = remote.files["#{base}.overlays"]?
    r.log_path = pkgdir.empty? ? "#{base}.log" : "#{pkgdir}/#{base}.log"
    log = parse_log(remote.sections["#{base}.log.events"]? || "")
    r.tail = (remote.sections["#{base}.log.tail"]? || "").lines.map { |l| strip_ansi(l).rstrip }.reject(&.empty?)
    r.overlays = parse_overlays(remote.sections["#{base}.overlays"]? || "")
    r.last_success_at = ovf.try(&.mtime)
    r.lock_skip = log.lock_skip
    r.errors = log.errors
    r.packages = log.packages

    r.state =
      if lock
        State::Running
      elsif logf.nil?
        ovf ? State::Success : State::Never
      elsif log.ok
        State::Success
      elsif ovf && ovf.mtime >= logf.mtime
        State::Success
      elsif log.lock_skip
        ovf ? State::Success : State::Never
      else
        State::Failed
      end

    rows = parse_status(remote.sections["poudriere-status"]? || "")
    row = pick_row(rows, major, log.logs_dir, !lock.nil?)
    r.logs_dir = log.logs_dir || row.try(&.logs)
    r.build = row.try(&.build) || log.logs_dir.try { |d| File.basename(d) }
    r.jail = row.try(&.jail)

    if row
      r.counters = counters_from_row(row)
      r.counters_source = "poudriere status"
    elsif fc = log.final_counters
      r.counters = fc
      r.counters_source = "bilan du journal"
    elsif !log.packages.empty?
      r.counters = counters_from_packages(log.packages, log.to_build)
      r.counters_source = "journal"
    end

    if dir = r.logs_dir
      r.packages.each { |p| p.error_log = "#{dir}/logs/errors/#{p.pkgname}.log" if p.result == "failed" }
    end

    case r.state
    when .running?
      r.started_at = lock.try(&.mtime)
      r.elapsed = seconds(row.try(&.time)) ||
                  log.last_elapsed.try { |e| logf ? e + {(remote.now - logf.mtime).to_i32, 0}.max : e }
      r.phase = row.try(&.status) ||
                (log.packages.empty? ? "préparation (arbres de ports, avant poudriere bulk)" : nil)
    when .success?, .failed?
      r.ended_at = logf.try(&.mtime) || ovf.try(&.mtime)
      r.duration = seconds(row.try(&.time)) || log.total_time
      r.phase = row.try(&.status)
    end
    r
  end

  # Tous les majeurs demandés (`major` nil = ceux présents).
  def reports(remote : Remote, major : String?, pkgdir : String = "") : Array(Report)
    list = major ? [major] : majors(remote)
    list.map { |m| report(remote, m, pkgdir) }
  end

  # 0 = succès / en cours / jamais construit ; 1 = un build en échec.
  def exit_code(reports : Array(Report)) : Int32
    reports.any?(&.state.failed?) ? 1 : 0
  end

  # ---------- rendu ----------

  # 377 → "6 min 17 s" ; 21 → "21 s" ; 3900 → "1 h 05 min".
  def human(secs : Int32 | Int64?) : String
    return "?" unless secs
    s = secs.to_i64
    s = 0_i64 if s < 0
    if s < 60
      "#{s} s"
    elsif s < 3600
      "#{s // 60} min #{(s % 60).to_s.rjust(2, '0')} s"
    elsif s < 86400
      "#{s // 3600} h #{((s % 3600) // 60).to_s.rjust(2, '0')} min"
    else
      "#{s // 86400} j #{((s % 86400) // 3600).to_s.rjust(2, '0')} h"
    end
  end

  def date(epoch : Int64?, location : Time::Location) : String
    return "?" unless epoch
    Time.unix(epoch).in(location).to_s("%Y-%m-%d %H:%M")
  end

  # Tri des paquets terminés : durée décroissante (défaut) ou origine.
  def sorted(pkgs : Array(Package), sort : String) : Array(Package)
    if sort == "name"
      pkgs.sort_by { |p| {p.origin, p.pkgname} }
    else
      pkgs.sort_by { |p| {-(p.duration || -1), p.origin} }
    end
  end

  # Rendu texte de tous les majeurs. `all` = liste complète des paquets
  # terminés (sinon les `TOP` premiers selon le tri).
  def render(label : String, pkgdir : String, reports : Array(Report), all : Bool = false,
             sort : String = "duration", location : Time::Location = Time::Location.local) : String
    String.build do |io|
      io << label << " — builds poudriere (" << pkgdir << ")\n"
      if reports.empty?
        io << "\n  Aucun build beryl trouvé (aucun fichier .beryl-build-*).\n"
      end
      reports.each { |r| render_one(io, r, all, sort, location) }
    end
  end

  private def render_one(io : IO, r : Report, all : Bool, sort : String, location : Time::Location) : Nil
    io << "\nMajeur " << r.major << " — "
    case r.state
    in .running?
      since = r.started_at.try { |s| r.now - s }
      io << "EN COURS depuis " << human(since) << '\n'
    in .success?
      io << "SUCCÈS, terminé le " << date(r.ended_at, location)
      io << " (bulk " << human(r.duration) << ")" if r.duration
      io << '\n'
    in .failed?
      io << "ÉCHEC, terminé le " << date(r.ended_at, location)
      io << " (bulk " << human(r.duration) << ")" if r.duration
      io << '\n'
    in .never?
      io << "jamais construit\n"
    end

    meta = [] of String
    r.build.try { |b| meta << "build #{b}" }
    r.jail.try { |j| meta << "jail #{j}" }
    r.phase.try { |p| meta << "phase #{p}" }
    meta << "bulk #{human(r.elapsed)}" if r.running? && r.elapsed
    io << "  " << meta.join(" · ") << '\n' unless meta.empty?
    if c = r.counters
      parts = [] of String
      parts << "file #{c.queued}" if c.queued
      parts << "construits #{c.built}" << "échecs #{c.failed}" << "ignorés #{c.ignored}" << "sautés #{c.skipped}"
      parts << "inspectés #{c.inspected}" if c.inspected > 0
      parts << "récupérés #{c.fetched}" if c.fetched > 0
      parts << "restants #{c.remaining}" if c.remaining
      io << "  " << parts.join(" · ") << "  (" << r.counters_source << ")\n"
    end
    io << "  journaux poudriere : " << r.logs_dir << '\n' if r.logs_dir
    io << "  ⚠ journal écrasé par un build planifié sauté (lock présent) : état déduit de .overlays\n" if r.lock_skip

    failed = r.by_result("failed")
    unless failed.empty?
      io << "\n  ÉCHECS (" << failed.size << ") :\n"
      w = failed.max_of(&.origin.size)
      failed.sort_by(&.origin).each do |p|
        io << "    ✗ " << p.origin.ljust(w) << "  " << p.pkgname
        io << " — phase " << p.detail if p.detail
        io << " (après " << human(p.duration) << ")" if p.duration
        io << '\n'
        io << "      journal : " << p.error_log << '\n' if p.error_log
      end
    end

    building = r.by_result("building")
    if r.running? && !building.empty?
      io << "\n  En construction (" << building.size << ") :\n"
      w = building.max_of(&.origin.size)
      building.sort_by { |p| p.started || 0 }.each do |p|
        io << "    " << p.origin.ljust(w) << "  " << p.pkgname
        if (e = r.elapsed) && (s = p.started)
          io << "  depuis " << human(e - s)
        end
        io << '\n'
      end
    end

    done = r.by_result("success")
    unless done.empty?
      list = sorted(done, sort)
      shown = all ? list : list.first(TOP)
      order = sort == "name" ? "par nom" : "les plus longs d'abord"
      io << "\n  Construits (" << done.size << ", " << order << ") :\n"
      w = shown.max_of(&.origin.size)
      shown.each do |p|
        io << "    " << human(p.duration).rjust(12) << "  " << p.origin.ljust(w) << "  " << p.pkgname << '\n'
      end
      io << "    … et " << (list.size - shown.size) << " autres (--all)\n" if shown.size < list.size
    end

    {"skipped" => "Sautés", "ignored" => "Ignorés"}.each do |result, title|
      pkgs = r.by_result(result)
      next if pkgs.empty?
      io << "\n  " << title << " (" << pkgs.size << ") :\n"
      shown = all ? pkgs : pkgs.first(TOP)
      w = shown.max_of(&.origin.size)
      shown.sort_by(&.origin).each do |p|
        io << "    " << p.origin.ljust(w) << "  " << p.pkgname
        io << " — " << p.detail if p.detail
        io << '\n'
      end
      io << "    … et " << (pkgs.size - shown.size) << " autres (--all)\n" if shown.size < pkgs.size
    end

    if r.state.failed?
      unless r.errors.empty?
        io << "\n  Erreurs :\n"
        r.errors.last(5).each { |l| io << "    " << l << '\n' }
      end
      unless r.tail.empty?
        io << "\n  Fin du journal (" << r.log_path << ") :\n"
        r.tail.last(10).each { |l| io << "    " << l << '\n' }
      end
    elsif r.running? && r.packages.empty? && !r.tail.empty?
      io << "\n  Dernières lignes du journal :\n"
      r.tail.last(5).each { |l| io << "    " << l << '\n' }
    end

    io << '\n'
    if at = r.last_success_at
      ov = r.overlays.map { |(n, c)| "#{n} #{c[0, 7]}" }.join(", ")
      io << "  Dernier build réussi : " << date(at, location)
      io << " — " << ov unless ov.empty?
      io << '\n'
    else
      io << "  Dernier build réussi : aucun\n"
    end
  end

  # Sortie machine (`--json`). Dates en secondes epoch (UTC).
  def to_json(label : String, pkgdir : String, reports : Array(Report)) : String
    JSON.build do |j|
      j.object do
        j.field "host", label
        j.field "pkgdir", pkgdir
        j.field "majors" do
          j.array do
            reports.each do |r|
              j.object do
                j.field "major", r.major
                j.field "state", r.state.to_s.underscore
                j.field "build", r.build
                j.field "jail", r.jail
                j.field "phase", r.phase
                j.field "started_at", r.started_at
                j.field "ended_at", r.ended_at
                j.field "duration", r.duration
                j.field "elapsed", r.elapsed
                j.field "counters", r.counters
                j.field "counters_source", r.counters_source
                j.field "logs_dir", r.logs_dir
                j.field "packages", r.packages
                j.field "errors", r.errors
                j.field "tail", r.state.failed? ? r.tail : [] of String
                j.field "last_success" do
                  j.object do
                    j.field "at", r.last_success_at
                    j.field "overlays" do
                      j.object { r.overlays.each { |(n, c)| j.field n, c } }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
