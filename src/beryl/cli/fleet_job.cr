require "json"
require "../xdg"

# Tâche de flotte pour `beryl os-upgrade|upgrade <société|domaine> --apply` :
# CANARI puis PARALLÈLE LIMITÉ, état sur disque lisible par `--status`.
#
# Chaque serveur est traité par un processus ENFANT `beryl <kind> <fqdn>
# --apply …` (le chemin un-serveur, déjà éprouvé) : sa sortie
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
# Dossier d'une tâche : `$XDG_STATE_HOME/beryl/jobs/<kind>/<id>/`
# (`job.json`, `<fqdn>.json`, `<fqdn>.log`, `orchestrateur.log`). Rien de
# propre au Mac : la même tâche pourra tourner sur un bastion.
module Beryl::CLI::FleetJob
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
    # Sous-commande beryl des enfants (`os-upgrade`, `upgrade`).
    getter kind : String = "os-upgrade"
    getter scope : String
    getter created_at : Time
    # Options passées à chaque enfant après `<kind> <fqdn>` (`--apply`…).
    getter child_args : Array(String) = [] of String
    getter parallel : Int32
    getter hosts : Array(HostRef)
    property pid : Int64? = nil
    property finished_at : Time? = nil

    def initialize(@id, @kind, @scope, @created_at, @child_args, @parallel, @hosts)
    end
  end

  struct HostState
    include JSON::Serializable
    getter state : String
    getter detail : String
    getter version : String?
    getter started_at : Time?
    getter updated_at : Time
    # Vrai dès que l'enfant a commencé à MODIFIER le serveur (installation,
    # montée, redémarrage). Un échec AVANT (injoignable, protégé, pas de
    # cible…) ne dit rien de la mise à jour : il n'invalide pas le canari.
    getter touched : Bool = false

    def initialize(@state, @detail, @version = nil, @started_at = nil, @updated_at = Time.utc, @touched = false)
    end
  end

  def jobs_root(kind : String) : String
    File.join(Beryl::Xdg.state_dir, "jobs", kind)
  end

  def state_path(dir : String, fqdn : String) : String
    File.join(dir, "#{fqdn}.json")
  end

  def log_path(dir : String, fqdn : String) : String
    File.join(dir, "#{fqdn}.log")
  end

  # Crée la tâche (dossier + job.json + état « en attente » par serveur).
  def create(kind : String, scope : String, fqdns : Array(String), child_args : Array(String), parallel : Int32) : String
    root = jobs_root(kind)
    base = Time.local.to_s("%Y%m%d-%H%M%S")
    id = base
    n = 1
    while Dir.exists?(File.join(root, id)) # deux tâches dans la même seconde
      n += 1
      id = "#{base}-#{n}"
    end
    dir = File.join(root, id)
    Dir.mkdir_p(dir)
    job = Job.new(id, kind, scope, Time.utc, child_args, parallel, fqdns.map { |f| HostRef.new(f) })
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
  def report(state : String, detail : String, version : String? = nil, touched : Bool = false) : Nil
    path = ENV[ENV_STATE]? || return
    prev = read_state(path)
    write_state(path, HostState.new(state, detail, version || prev.try(&.version), prev.try(&.started_at) || Time.utc,
      touched: touched || prev.try(&.touched) || false))
  rescue
    # Le rapport ne doit jamais faire échouer la mise à jour elle-même.
  end

  # ── Orchestrateur ────────────────────────────────────────────────────────

  # Commande de base d'un processus enfant : CE binaire + options globales
  # (racine de config, transport), pour que l'enfant voie la même config.
  def self_cmd(config_root : String) : Array(String)
    exe = Process.executable_path || PROGRAM_NAME
    cmd = [exe, "-c", config_root]
    cmd << "--transport=overlay" if Beryl.transport_mode == :overlay
    cmd
  end

  # `child_cmd` : commande de base de l'enfant (exécutable + options globales),
  # le fqdn et les options d'os-upgrade sont ajoutés ici.
  def run(dir : String, child_cmd : Array(String)) : Int32
    job = load(dir)
    job.pid = Process.pid.to_i64
    save(dir, job)
    hosts = job.hosts.map(&.fqdn)
    say job, "tâche #{job.id} : #{hosts.size} serveur(s), canari puis #{job.parallel} en parallèle (#{job.child_args.join(" ")})"

    idx = 0
    canary_ok = false
    while idx < hosts.size
      fqdn = hosts[idx]
      idx += 1
      say job, "canari : #{fqdn}"
      st = run_host(dir, job, fqdn, child_cmd)
      case
      when st.state == UPTODATE
        say job, "#{fqdn} : à jour — le canari passe au serveur suivant"
      when st.state != UPGRADED && !st.touched
        say job, "#{fqdn} : #{st.state} AVANT toute modification (#{st.detail}) — n'invalide pas la mise à jour, le canari passe au serveur suivant"
      when st.state == UPGRADED
        say job, "#{fqdn} : canari réussi (#{st.detail})"
        canary_ok = true
        break
      else
        say job, "#{fqdn} : CANARI EN ÉCHEC (#{st.detail}) — les #{hosts.size - idx} serveur(s) restant(s) sont annulés"
        hosts[idx..].each { |f| write_state(state_path(dir, f), HostState.new(CANCELLED, "canari #{fqdn} en échec")) }
        return finish(dir, job)
      end
    end

    rest = hosts[idx..]
    if canary_ok && !rest.empty?
      say job, "parallèle : #{rest.size} serveur(s), #{job.parallel} à la fois"
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
          say job, "#{fqdn} : #{st.state}#{st.detail.empty? ? "" : " — #{st.detail}"}"
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
    args = child_cmd[1..] + [job.kind, fqdn] + job.child_args
    status = File.open(log_path(dir, fqdn), "a") do |log|
      Process.run(child_cmd[0], args, env: {ENV_STATE => path}, input: Process::Redirect::Close, output: log, error: log)
    end
    st = read_state(path) || HostState.new(RUNNING, "")
    if !FINAL.includes?(st.state)
      st = if status.success?
             HostState.new(UPGRADED, "terminé (étape finale non rapportée)", st.version, st.started_at, touched: st.touched)
           else
             HostState.new(FAILED, "code #{status.exit_code} — #{log_tail(dir, fqdn)}", st.version, st.started_at, touched: st.touched)
           end
      write_state(path, st)
    elsif !status.success? && st.state != FAILED
      st = HostState.new(FAILED, "code #{status.exit_code} — #{log_tail(dir, fqdn)}", st.version, st.started_at, touched: st.touched)
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
    say job, "tâche #{job.id} terminée — #{summary(states)}"
    failed > 0 || cancelled > 0 ? 2 : 0
  end

  def summary(states : Array(HostState?)) : String
    {UPGRADED, UPTODATE, RUNNING, PENDING, FAILED, CANCELLED}.compact_map do |s|
      n = states.count { |x| x.try(&.state) == s }
      "#{n} #{s}" if n > 0
    end.join(" · ")
  end

  private def say(job : Job, msg : String) : Nil
    STDOUT.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl #{job.kind}] #{msg}"
    STDOUT.flush
  end

  # ── Détachement (Mac d'abord, bastion ensuite) ───────────────────────────

  # Relance l'orchestrateur en arrière-plan : `nohup` (survit à la fermeture
  # du terminal) et, s'il existe (macOS), `caffeinate -i` (pas de veille tant
  # que la tâche tourne). Sortie dans `orchestrateur.log`.
  def detach(dir : String, child_cmd : Array(String)) : Int64
    prefix = ["nohup"]
    prefix += ["caffeinate", "-i"] if Process.find_executable("caffeinate")
    args = prefix[1..] + child_cmd + [load(dir).kind, "--job", dir]
    log = File.open(File.join(dir, "orchestrateur.log"), "a")
    p = Process.new(prefix[0], args, input: Process::Redirect::Close, output: log, error: log)
    log.close
    p.pid.to_i64
  end

  # ── --status ─────────────────────────────────────────────────────────────

  # Dossier de la tâche `id`, ou de la plus récente.
  def find(kind : String, id : String?) : String?
    root = jobs_root(kind)
    return nil unless Dir.exists?(root)
    if i = id
      d = File.join(root, i)
      return Dir.exists?(d) ? d : nil
    end
    Dir.children(root).select { |c| File.exists?(File.join(root, c, "job.json")) }.sort.last?.try { |c| File.join(root, c) }
  end

  def status(kind : String, id : String?) : Int32
    dir = find(kind, id)
    unless dir
      STDERR.puts "beryl : aucune tâche #{kind}#{id ? " « #{id} »" : ""} (#{jobs_root(kind)})."
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
    puts "Tâche #{job.kind} #{job.id} — #{job.scope} — #{phase}"
    puts "Options : #{job.child_args.join(" ")} — #{job.parallel} en parallèle après le canari"
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
