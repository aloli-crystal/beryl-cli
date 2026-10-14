require "json"
require "../xdg"

# Tâche de flotte pour `beryl os-upgrade <société|domaine> --apply` : CANARI
# puis PARALLÈLE LIMITÉ, état sur disque lisible par `--status`.
#
# Chaque serveur est traité par un processus ENFANT `beryl os-upgrade
# <fqdn> --apply [--reboot]` (le chemin un-serveur, déjà éprouvé) : sa sortie
# va dans son propre journal (pas d'entrelacement), il écrit son état dans
# `<fqdn>.json` (variable `BERYL_JOB_STATE`). L'orchestrateur :
#
# . CANARI : traite les serveurs UN PAR UN jusqu'au premier qui a réellement
#   quelque chose à installer (un serveur déjà à jour ne valide rien) ; s'il
#   échoue, le reste est ANNULÉ — un correctif qui casse le démarrage se voit
#   sur un serveur, pas sur quinze ;
# . puis le reste en PARALLÈLE (`--parallel N`) : un serveur qui plante ne
#   bloque aucun autre.
#
# Dossier d'une tâche : `$XDG_STATE_HOME/beryl/jobs/os-upgrade/<id>/`
# (`job.json`, `<fqdn>.json`, `<fqdn>.log`, `orchestrateur.log`). Rien de
# propre au Mac : la même tâche pourra tourner sur un bastion.
module Beryl::CLI::OsUpgradeJob
  extend self

  ENV_STATE = "BERYL_JOB_STATE"

  PENDING   = "en attente"
  RUNNING   = "en cours"
  UPGRADED  = "mis à jour"
  UPTODATE  = "à jour"
  FAILED    = "échec"
  CANCELLED = "annulé"

  FINAL = {UPGRADED, UPTODATE, FAILED, CANCELLED}

  struct HostRef
    include JSON::Serializable
    getter fqdn : String

    def initialize(@fqdn : String)
    end
  end

  struct Job
    include JSON::Serializable
    getter id : String
    getter scope : String
    getter created_at : Time
    getter reboot : Bool
    getter to : String?
    getter parallel : Int32
    getter hosts : Array(HostRef)
    property pid : Int64? = nil
    property finished_at : Time? = nil

    def initialize(@id, @scope, @created_at, @reboot, @to, @parallel, @hosts)
    end
  end

  struct HostState
    include JSON::Serializable
    getter state : String
    getter detail : String
    getter version : String?
    getter started_at : Time?
    getter updated_at : Time

    def initialize(@state, @detail, @version = nil, @started_at = nil, @updated_at = Time.utc)
    end
  end

  def jobs_root : String
    File.join(Beryl::Xdg.state_dir, "jobs", "os-upgrade")
  end

  def state_path(dir : String, fqdn : String) : String
    File.join(dir, "#{fqdn}.json")
  end

  def log_path(dir : String, fqdn : String) : String
    File.join(dir, "#{fqdn}.log")
  end

  # Crée la tâche (dossier + job.json + état « en attente » par serveur).
  def create(scope : String, fqdns : Array(String), reboot : Bool, to : String?, parallel : Int32) : String
    base = Time.local.to_s("%Y%m%d-%H%M%S")
    id = base
    n = 1
    while Dir.exists?(File.join(jobs_root, id)) # deux tâches dans la même seconde
      n += 1
      id = "#{base}-#{n}"
    end
    dir = File.join(jobs_root, id)
    Dir.mkdir_p(dir)
    job = Job.new(id, scope, Time.utc, reboot, to, parallel, fqdns.map { |f| HostRef.new(f) })
    write_json(File.join(dir, "job.json"), job.to_json)
    fqdns.each { |f| write_state(state_path(dir, f), HostState.new(PENDING, "")) }
    dir
  end

  def load(dir : String) : Job
    Job.from_json(File.read(File.join(dir, "job.json")))
  end

  def save(dir : String, job : Job) : Nil
    write_json(File.join(dir, "job.json"), job.to_json)
  end

  def read_state(path : String) : HostState?
    HostState.from_json(File.read(path))
  rescue
    nil
  end

  def write_state(path : String, st : HostState) : Nil
    write_json(path, st.to_json)
  end

  # Écriture ATOMIQUE (temp + rename) : `--status` ne lit jamais un JSON coupé.
  private def write_json(path : String, json : String) : Nil
    tmp = "#{path}.tmp"
    File.write(tmp, json)
    File.rename(tmp, path)
  end

  # Côté ENFANT : rapporte l'étape/le résultat si la variable est posée
  # (no-op hors tâche). `started_at` est conservé d'un rapport à l'autre.
  def report(state : String, detail : String, version : String? = nil) : Nil
    path = ENV[ENV_STATE]? || return
    prev = read_state(path)
    write_state(path, HostState.new(state, detail, version || prev.try(&.version), prev.try(&.started_at) || Time.utc))
  rescue
    # Le rapport ne doit jamais faire échouer la mise à jour elle-même.
  end

  # ── Orchestrateur ────────────────────────────────────────────────────────

  # `child_cmd` : commande de base de l'enfant (exécutable + options globales),
  # le fqdn et les options d'os-upgrade sont ajoutés ici.
  def run(dir : String, child_cmd : Array(String)) : Int32
    job = load(dir)
    job.pid = Process.pid.to_i64
    save(dir, job)
    hosts = job.hosts.map(&.fqdn)
    say "tâche #{job.id} : #{hosts.size} serveur(s), canari puis #{job.parallel} en parallèle#{job.reboot ? ", avec redémarrage" : ", SANS redémarrage"}"

    idx = 0
    canary_ok = false
    while idx < hosts.size
      fqdn = hosts[idx]
      idx += 1
      say "canari : #{fqdn}"
      st = run_host(dir, job, fqdn, child_cmd)
      case st.state
      when UPTODATE
        say "#{fqdn} : à jour — le canari passe au serveur suivant"
      when UPGRADED
        say "#{fqdn} : canari réussi (#{st.detail})"
        canary_ok = true
        break
      else
        say "#{fqdn} : CANARI EN ÉCHEC (#{st.detail}) — les #{hosts.size - idx} serveur(s) restant(s) sont annulés"
        hosts[idx..].each { |f| write_state(state_path(dir, f), HostState.new(CANCELLED, "canari #{fqdn} en échec")) }
        return finish(dir, job)
      end
    end

    rest = hosts[idx..]
    if canary_ok && !rest.empty?
      say "parallèle : #{rest.size} serveur(s), #{job.parallel} à la fois"
      run_parallel(dir, job, rest, child_cmd)
    end
    finish(dir, job)
  end

  private def run_parallel(dir : String, job : Job, fqdns : Array(String), child_cmd : Array(String)) : Nil
    slots = Channel(Nil).new(job.parallel)
    done = Channel(Nil).new
    fqdns.each do |fqdn|
      spawn do
        slots.send(nil)
        begin
          st = run_host(dir, job, fqdn, child_cmd)
          say "#{fqdn} : #{st.state}#{st.detail.empty? ? "" : " — #{st.detail}"}"
        ensure
          slots.receive
          done.send(nil)
        end
      end
    end
    fqdns.size.times { done.receive }
  end

  # Lance l'enfant d'UN serveur et renvoie son état final. Un enfant qui
  # sort en erreur sans l'avoir rapporté (plantage) est noté en ÉCHEC avec la
  # fin de son journal : rien ne se perd en silence.
  def run_host(dir : String, job : Job, fqdn : String, child_cmd : Array(String)) : HostState
    path = state_path(dir, fqdn)
    write_state(path, HostState.new(RUNNING, "lancement", started_at: Time.utc))
    args = child_cmd[1..] + ["os-upgrade", fqdn, "--apply"]
    args << "--reboot" if job.reboot
    if to = job.to
      args << "--to" << to
    end
    status = File.open(log_path(dir, fqdn), "a") do |log|
      Process.run(child_cmd[0], args, env: {ENV_STATE => path}, input: Process::Redirect::Close, output: log, error: log)
    end
    st = read_state(path) || HostState.new(RUNNING, "")
    if !FINAL.includes?(st.state)
      st = if status.success?
             HostState.new(UPGRADED, "terminé (étape finale non rapportée)", st.version, st.started_at)
           else
             HostState.new(FAILED, "code #{status.exit_code} — #{log_tail(dir, fqdn)}", st.version, st.started_at)
           end
      write_state(path, st)
    elsif !status.success? && st.state != FAILED
      st = HostState.new(FAILED, "code #{status.exit_code} — #{log_tail(dir, fqdn)}", st.version, st.started_at)
      write_state(path, st)
    end
    st
  rescue ex
    st = HostState.new(FAILED, "lancement impossible : #{ex.message}")
    write_state(state_path(dir, fqdn), st)
    st
  end

  private def log_tail(dir : String, fqdn : String) : String
    File.read(log_path(dir, fqdn)).lines.map(&.strip).reject(&.empty?).last(2).join(" | ")
  rescue
    "journal illisible"
  end

  private def finish(dir : String, job : Job) : Int32
    job.finished_at = Time.utc
    save(dir, job)
    states = job.hosts.map { |h| read_state(state_path(dir, h.fqdn)) }
    failed = states.count { |s| s.try(&.state) == FAILED }
    cancelled = states.count { |s| s.try(&.state) == CANCELLED }
    say "tâche #{job.id} terminée — #{summary(states)}"
    failed > 0 || cancelled > 0 ? 2 : 0
  end

  def summary(states : Array(HostState?)) : String
    {UPGRADED, UPTODATE, RUNNING, PENDING, FAILED, CANCELLED}.compact_map do |s|
      n = states.count { |x| x.try(&.state) == s }
      "#{n} #{s}" if n > 0
    end.join(" · ")
  end

  private def say(msg : String) : Nil
    STDOUT.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl os-upgrade] #{msg}"
    STDOUT.flush
  end

  # ── Détachement (Mac d'abord, bastion ensuite) ───────────────────────────

  # Relance l'orchestrateur en arrière-plan : `nohup` (survit à la fermeture
  # du terminal) et, s'il existe (macOS), `caffeinate -i` (pas de veille tant
  # que la tâche tourne). Sortie dans `orchestrateur.log`.
  def detach(dir : String, child_cmd : Array(String)) : Int64
    prefix = ["nohup"]
    prefix += ["caffeinate", "-i"] if Process.find_executable("caffeinate")
    args = prefix[1..] + child_cmd + ["os-upgrade", "--job", dir]
    log = File.open(File.join(dir, "orchestrateur.log"), "a")
    p = Process.new(prefix[0], args, input: Process::Redirect::Close, output: log, error: log)
    log.close
    p.pid.to_i64
  end

  # ── --status ─────────────────────────────────────────────────────────────

  # Dossier de la tâche `id`, ou de la plus récente.
  def find(id : String?) : String?
    return nil unless Dir.exists?(jobs_root)
    if i = id
      d = File.join(jobs_root, i)
      return Dir.exists?(d) ? d : nil
    end
    Dir.children(jobs_root).select { |c| File.exists?(File.join(jobs_root, c, "job.json")) }.sort.last?.try { |c| File.join(jobs_root, c) }
  end

  def status(id : String?) : Int32
    dir = find(id)
    unless dir
      STDERR.puts "beryl : aucune tâche os-upgrade#{id ? " « #{id} »" : ""} (#{jobs_root})."
      return 1
    end
    job = load(dir)
    alive = (pid = job.pid) && job.finished_at.nil? && process_alive?(pid)
    phase = if job.finished_at
              "terminée"
            elsif alive
              "EN COURS (pid #{job.pid})"
            else
              "INTERROMPUE (orchestrateur arrêté avant la fin)"
            end
    puts "Tâche #{job.id} — #{job.scope} — #{phase}"
    puts "Options : #{job.reboot ? "avec" : "SANS"} redémarrage, #{job.parallel} en parallèle#{job.to ? ", cible #{job.to}" : ""}"
    puts ""
    w = job.hosts.map(&.fqdn.size).max? || 20
    states = job.hosts.map do |h|
      st = read_state(state_path(dir, h.fqdn))
      puts "  #{h.fqdn.ljust(w)}  #{(st.try(&.state) || "?").ljust(11)}  #{duration(st).rjust(6)}  #{st.try(&.detail)}"
      st
    end
    puts ""
    puts "Résumé : #{summary(states)}"
    puts "Journaux : #{dir}/<serveur>.log"
    states.any? { |s| s.try(&.state) == FAILED } ? 2 : 0
  end

  private def duration(st : HostState?) : String
    s = st.try(&.started_at) || return ""
    st = st.not_nil!
    stop = FINAL.includes?(st.state) ? st.updated_at : Time.utc
    secs = (stop - s).total_seconds.to_i
    secs >= 60 ? "#{secs // 60}m#{(secs % 60).to_s.rjust(2, '0')}" : "#{secs}s"
  end

  private def process_alive?(pid : Int64) : Bool
    Process.exists?(pid)
  rescue
    false
  end
end
