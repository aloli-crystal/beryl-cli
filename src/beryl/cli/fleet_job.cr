require "json"
require "../xdg"
require "../smtp"
require "../config/env_file"

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

  # Serveurs traités à la fois quand ni `--parallel=N` ni le réglage
  # `parallel:` de la configuration ne le disent.
  DEFAULT_PARALLEL = 4

  # Valeur de `--parallel=…` : N ≥ 1, 0 pour `no`/`non` (parallèle coupé,
  # comme `--no-parallel`), -1 si illisible. Pur.
  def parse_parallel(value : String) : Int32
    return 0 if {"no", "non"}.includes?(value.strip.downcase)
    n = value.strip.to_i?
    n && n >= 1 ? n : -1
  end

  # Serveurs à la fois : `--parallel=N` s'il est donné, sinon le PLUS PETIT
  # réglage `parallel:` des serveurs de la portée (prudence quand elle mêle
  # des groupes), sinon DEFAULT_PARALLEL. Pur côté config.
  def parallel_for(hosts : Array(Beryl::Config::ResolvedHost), flag : Int32?) : Int32
    return flag if flag && flag >= 1
    hosts.compact_map(&.parallel).min? || DEFAULT_PARALLEL
  end

  struct HostRef
    include JSON::Serializable
    getter fqdn : String
    # `reboot_group` du serveur : jamais deux d'un même groupe en même temps.
    getter group : String? = nil

    def initialize(@fqdn : String, @group : String? = nil)
    end
  end

  # CLASSE (et non struct) : `finish`/`mail_summary` modifient la tâche
  # (finished_at, mailed_to…) avant de l'enregistrer ; une struct serait
  # COPIÉE à chaque passage en argument et ces champs perdus.
  class Job
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
    # Société dont le coffre fournit le relais du courriel récapitulatif, et
    # racine de config où le trouver.
    getter account : String? = nil
    getter config_root : String? = nil
    # Courriel récapitulatif : destinataire si envoyé, sinon raison.
    property mailed_to : String? = nil
    property mail_error : String? = nil

    def initialize(@id, @kind, @scope, @created_at, @child_args, @parallel, @hosts, @account = nil, @config_root = nil)
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
  def create(kind : String, scope : String, fqdns : Array(String), child_args : Array(String), parallel : Int32,
             groups : Hash(String, String) = {} of String => String,
             account : String? = nil, config_root : String? = nil) : String
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
    job = Job.new(id, kind, scope, Time.utc, child_args, parallel, fqdns.map { |f| HostRef.new(f, groups[f]?) }, account, config_root)
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

  # Ordonnanceur : au plus `parallel` serveurs à la fois, et JAMAIS deux d'un
  # même `reboot_group` (bastions…). Un serveur dont le groupe est occupé
  # attend son tour sans bloquer ceux des autres groupes.
  private def run_parallel(dir : String, job : Job, fqdns : Array(String), child_cmd : Array(String)) : Nil
    groups = job.hosts.to_h { |h| {h.fqdn, h.group} }
    pending = fqdns.dup
    busy = Set(String).new
    running = 0
    done = Channel(String).new
    until pending.empty? && running == 0
      while running < job.parallel && (fqdn = next_runnable(pending, groups, busy))
        pending.delete(fqdn)
        groups[fqdn]?.try { |g| busy << g }
        running += 1
        launch(dir, job, fqdn, child_cmd, done)
      end
      finished = done.receive
      running -= 1
      groups[finished]?.try { |g| busy.delete(g) }
    end
  end

  # Lance UN serveur dans sa fibre. Méthode à part (et non bloc dans la
  # boucle) : `fqdn` est un ARGUMENT, propre à chaque fibre. Une variable de
  # boucle capturée par `spawn` serait partagée : un serveur terminé
  # annoncerait le nom d'un autre, et son groupe ne serait jamais libéré.
  private def launch(dir : String, job : Job, fqdn : String, child_cmd : Array(String), done : Channel(String)) : Nil
    spawn do
      st = run_host(dir, job, fqdn, child_cmd)
      say job, "#{fqdn} : #{st.state}#{st.detail.empty? ? "" : " — #{st.detail}"}"
    ensure
      done.send(fqdn)
    end
  end

  # Premier serveur en attente dont le groupe n'est pas occupé. Pur.
  def next_runnable(pending : Array(String), groups : Hash(String, String?), busy : Set(String)) : String?
    pending.find { |f| (g = groups[f]?).nil? || !busy.includes?(g) }
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
    # Courriel récapitulatif SEULEMENT hors console : tâche détachée (sortie
    # vers son journal) ou lancée sur un bastion. Au premier plan dans un
    # terminal, l'opérateur a déjà tout sous les yeux.
    if notify?
      mail_summary(job, states)
      save(dir, job)
    end
    failed > 0 || cancelled > 0 ? 2 : 0
  end

  # Courriel récapitulatif ? Hors console (sortie qui n'est pas un terminal),
  # sauf décision forcée (tests).
  @@notify : Bool? = nil

  def notify=(value : Bool?) : Nil
    @@notify = value
  end

  def notify? : Bool
    n = @@notify
    n.nil? ? !STDOUT.tty? : n
  end

  # Envoie le récapitulatif via le relais du coffre de la société
  # (`[mail]` : SMTP_RELAY_USER/PASSWORD/TO, SMTP_RELAY_HOST/PORT facultatifs,
  # défaut ssl0.ovh.net:587 comme la recette smtp-relay). Un échec est
  # consigné (journal + `--status`), jamais silencieux.
  private def mail_summary(job : Job, states : Array(HostState?)) : Nil
    acct = job.account
    root = job.config_root
    unless acct && root
      return mail_failed(job, "société inconnue pour cette tâche")
    end
    mail = Beryl::Config::EnvFile.load_vault(File.join(root, acct, Beryl::Config::EnvFile::VAULT_FILENAME))["mail"]? || {} of String => String
    user = mail["SMTP_RELAY_USER"]?
    pass = mail["SMTP_RELAY_PASSWORD"]?
    to = mail["SMTP_RELAY_TO"]?
    unless user && pass && to
      return mail_failed(job, "coffre #{acct} : [mail] SMTP_RELAY_USER/PASSWORD/TO incomplet")
    end
    host = mail["SMTP_RELAY_HOST"]? || "ssl0.ovh.net"
    port = mail["SMTP_RELAY_PORT"]?.try(&.to_i?) || 587
    subject, body = compose(job, states)
    Beryl::Smtp.send(host, port, user, pass, Beryl::Smtp::Message.new(user, to, subject, body))
    job.mailed_to = to
    say job, "récapitulatif envoyé à #{to}"
  rescue ex
    mail_failed(job, ex.message || ex.class.name)
  end

  private def mail_failed(job : Job, why : String) : Nil
    job.mail_error = why
    say job, "⚠ courriel récapitulatif NON envoyé : #{why}"
  end

  # Objet et corps du récapitulatif. Pur.
  def compose(job : Job, states : Array(HostState?)) : {String, String}
    subject = "[beryl][#{job.account || job.scope}] #{job.kind} #{job.scope} : #{summary(states)}"
    w = job.hosts.map(&.fqdn.size).max? || 20
    body = String.build do |b|
      b << "Tâche " << job.kind << " " << job.id << " — " << job.scope << "\n"
      b << "Options : " << job.child_args.join(" ") << " — " << job.parallel << " en parallèle après le canari\n\n"
      job.hosts.each_with_index do |h, i|
        st = states[i]?
        grp = h.group ? "[#{h.group}] " : ""
        b << "  " << h.fqdn.ljust(w) << "  " << (st.try(&.state) || "?").ljust(11) << "  " << grp << st.try(&.detail) << "\n"
      end
      b << "\nRésumé : " << summary(states) << "\n"
      b << "Détail : beryl " << job.kind << " --status " << job.id << "\n"
    end
    {subject, body}
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
    return unless Dir.exists?(root)
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
      grp = h.group ? "[#{h.group}] " : ""
      puts "  #{h.fqdn.ljust(w)}  #{(st.try(&.state) || "?").ljust(11)}  #{duration(st).rjust(6)}  #{grp}#{st.try(&.detail)}"
      st
    end
    puts ""
    puts "Résumé : #{summary(states)}"
    if to = job.mailed_to
      puts "Récapitulatif envoyé à #{to}"
    elsif err = job.mail_error
      puts "⚠ Récapitulatif NON envoyé : #{err}"
    end
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
