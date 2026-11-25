require "base64"
require "random/secure"
require "ssh"
require "./shell"

module Beryl::Apply
  # Shell distant PERSISTANT : un seul `ssh … sudo -n sh` ouvert pour tout le
  # sync, les commandes lui sont envoyées sur son entrée standard.
  #
  # Pourquoi : même multiplexée (ControlMaster), chaque `ssh … commande`
  # ouvre une nouvelle session côté sshd (~0,35 s par appel mesuré sur un serveur le
  # 25 nov. 2026, dont une bonne part due au marquage des paquets, cf.
  # `Beryl::SSH_OPTIONS`), soit l'essentiel des ~110 s d'un sync où 152 étapes sur 157
  # ne font que vérifier. Ici, un appel coûte un aller-retour réseau.
  #
  # Protocole (sh POSIX, aucun prérequis distant au-delà de la base) :
  # - au démarrage, un script d'amorce définit `__beryl_run` / `__beryl_put`
  #   puis annonce `<marqueur> READY` ;
  # - chaque commande voyage en base64 sur UNE ligne (`__beryl_run '<b64>'`),
  #   décodée puis jouée par `sh -c` dans un processus à part (aucun état —
  #   cd, variables — ne fuit d'une commande à l'autre), stdin = /dev/null
  #   (elle ne peut pas avaler la suite du flux), stdout/stderr dans deux
  #   fichiers d'un dossier temporaire privé ;
  # - la réponse est un en-tête `<marqueur> <code> <octets stdout> <octets
  #   stderr>` suivi des deux contenus bruts : sûr pour toute sortie, même
  #   binaire ou sans fin de ligne ;
  # - `write_file` passe par `__beryl_put` : contenu en base64 décodé par le
  #   `printf` intégré du shell (pas de limite ARG_MAX), puis `install`
  #   (connexion sudo, comme `SudoShell`) ou `cat >` (connexion root, comme
  #   `SshShell`).
  #
  # Les commandes sont jouées à l'identique de `SudoShell`/`SshShell` : même
  # `sh -c`, même environnement (celui de `sudo`), même dossier courant.
  #
  # Repli : si l'amorce échoue, ou si la session tombe en cours de route, les
  # appels suivants passent par `fallback` (un `ssh` par commande, l'ancien
  # chemin), avec un message sur stderr. La commande en vol au moment de la
  # coupure est rapportée en échec (code 255, comme ssh) : jamais rejouée,
  # elle a pu s'exécuter.
  class PersistentShell < Shell
    # Code rendu pour une commande perdue avec la session (celui de ssh).
    LOST = 255

    # Délai maximal de l'amorce (connexion comprise).
    BOOT_TIMEOUT = 30.seconds

    # Désactivation explicite (débogage) : `BERYL_SSH_PERSISTENT=0`.
    ENV_SWITCH = "BERYL_SSH_PERSISTENT"

    def self.enabled? : Bool
      ENV[ENV_SWITCH]? != "0"
    end

    # Ouvre le shell persistant vers `conn` (`sudo` : connexion par un compte
    # sudo-capable, les commandes sont jouées en root). Rend `fallback` seul
    # si désactivé.
    def self.open(conn : SSH::Connection, sudo : Bool, fallback : Shell) : Shell
      return fallback unless enabled?
      # Sur la connexion multiplexée : un canal de plus sur le maître, sans
      # poignée de main. Son marquage `IPQoS=ef` (`Beryl::SSH_OPTIONS`) est
      # celui du maître, fixé à sa création ; un maître ouvert avant (sans
      # `ef`) ne ralentit que le temps de son expiration (ControlPersist).
      shell = new("ssh", conn.ssh_args(sudo ? "sudo -n sh" : "sh"), fallback, install: sudo)
      if shell.start && ENV[TRACE_SWITCH]? == "1"
        shell.calibrate
        calibrate_transports(conn, fallback)
      end
      shell
    end

    # Options ssh qui court-circuitent le multiplexage : placées EN TÊTE, elles
    # l'emportent (ssh retient la première valeur d'une option).
    NO_MUX = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    # Diagnostic : l'écho pur (transport seul) sur une connexion propre, sans
    # sudo, selon le marquage de priorité IP des paquets (`IPQoS`), pour
    # vérifier le choix de `Beryl::SSH_OPTIONS` depuis un autre réseau.
    TRANSPORT_VARIANTS = {
      "IPQoS=none (défaut de ssh sans terminal)" => ["-o", "IPQoS=none"],
      "IPQoS=cs1"                                => ["-o", "IPQoS=cs1"],
      "IPQoS=lowdelay"                           => ["-o", "IPQoS=lowdelay"],
      "IPQoS=ef"                                 => ["-o", "IPQoS=ef"],
    }

    def self.calibrate_transports(conn : SSH::Connection, fallback : Shell, rounds : Int32 = 10) : Nil
      parts = TRANSPORT_VARIANTS.map do |label, extra|
        probe = new("ssh", NO_MUX + extra + conn.ssh_args("sh"), fallback, install: false)
        next "#{label} : échec" unless probe.start
        "#{label} #{probe.median_ms(rounds) { probe.echo }} ms"
      ensure
        probe.try(&.close)
      end
      STDERR.puts "beryl : shell distant persistant, écho sur connexion propre (médiane sur #{rounds}) : #{parts.join(", ")}"
    end

    # Écho pur : réponse du seul `sh` distant, aucun processus lancé.
    def echo : SSH::Result
      request("__beryl_echo")
    end

    # Durée médiane (ms) de `rounds` exécutions du bloc.
    def median_ms(rounds : Int32, &) : Int32
      samples = Array.new(rounds) do
        started = Time.instant
        yield
        (Time.instant - started).total_milliseconds
      end
      samples.sort[rounds // 2].round.to_i
    end

    # Diagnostic : `BERYL_SSH_TRACE=1` mesure, à l'ouverture, ce que coûte un
    # échange (cf. `calibrate`).
    TRACE_SWITCH = "BERYL_SSH_TRACE"

    # Étalonnage (diagnostic) : durée médiane d'un écho pur (réponse produite
    # par le seul `sh` distant, AUCUN processus lancé : le transport seul),
    # d'une commande vide (le protocole complet) et d'une lecture réaliste
    # (empreinte + stat, comme `file-write`). Écrit sur stderr (journal).
    def calibrate(rounds : Int32 = 10) : Nil
      probes = {
        "écho (transport seul)"   => -> { echo },
        "commande vide (true)"    => -> { request("__beryl_run '#{Base64.strict_encode("true")}'") },
        "lecture (sha256 + stat)" => -> { request("__beryl_run '#{Base64.strict_encode(Posix.file_state("/etc/rc.conf", FREEBSD))}'") },
      }
      parts = probes.map do |label, probe|
        "#{label} #{median_ms(rounds) { probe.call }} ms"
      end
      STDERR.puts "beryl : shell distant persistant, étalonnage (médiane sur #{rounds}) : #{parts.join(", ")}"
    end

    getter? alive = false
    @process : Process?
    @stderr_log = IO::Memory.new

    def initialize(@command : String, @args : Array(String), @fallback : Shell, @install : Bool = true)
      @marker = "BERYL-#{Random::Secure.hex(8)}"
    end

    # Lance la session et attend l'annonce `READY`. Faux (et repli
    # annoncé) si la session n'a pas pu s'établir.
    def start : Bool
      process = Process.new(@command, @args,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)
      @process = process
      stderr = process.error
      log = @stderr_log
      spawn { IO.copy(stderr, log) rescue nil }
      process.input.print boot_script
      process.input.flush
      out = process.output
      out.read_timeout = BOOT_TIMEOUT
      ready = "#{@marker} READY"
      while line = out.gets
        if line == ready
          out.read_timeout = nil
          return @alive = true
        end
      end
      give_up("session impossible à établir")
    rescue ex : IO::Error | IO::TimeoutError | File::Error
      give_up("session impossible à établir (#{ex.message})")
    end

    def exec(command : String, raise_on_error : Bool = true) : SSH::Result
      return @fallback.exec(command, raise_on_error) unless alive?
      result = request("__beryl_run '#{Base64.strict_encode(command)}'")
      raise SSH::CommandFailed.new(command, result) if raise_on_error && !result.success?
      result
    end

    def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
      return @fallback.write_file(remote_path, content, mode) unless alive?
      how = @install ? "install" : "cat"
      line = "__beryl_put #{Process.quote(remote_path)} #{Process.quote(mode || "")} #{how} '#{Base64.strict_encode(content)}'"
      result = request(line)
      raise SSH::CommandFailed.new("écriture de #{remote_path}", result) unless result.success?
    end

    # Délai laissé à `ssh` pour finir après la fin du flux, avant de l'arrêter.
    CLOSE_TIMEOUT = 5.seconds

    # Ferme proprement la session (fin du flux : le shell distant sort et
    # efface son dossier temporaire). Jamais bloquant : un serveur qui a
    # redémarré (`os-upgrade --reboot`) ne répond plus, ssh attendrait la
    # fin de la connexion TCP ; il est arrêté passé `CLOSE_TIMEOUT`.
    def close : Nil
      return unless process = @process
      @alive = false
      @process = nil
      process.input.close rescue nil
      done = Channel(Nil).new(1)
      spawn do
        process.wait rescue nil
        done.send(nil)
      end
      select
      when done.receive
      when timeout(CLOSE_TIMEOUT)
        process.terminate rescue nil
      end
    end

    # Envoie `line` et lit la réponse.
    #
    # La requête part en UNE seule écriture (`self.frame`) : les tuyaux de
    # `Process` sont en écriture directe (`sync = true`), et `print line, '\n'`
    # en faisait deux. Sans pseudo-terminal, ssh laisse Nagle actif : le `\n`
    # d'un octet attendait l'ACK de la ligne, que le serveur différait (son
    # `sh` attend justement ce `\n` pour répondre) → ~0,2 s perdues par appel,
    # contre ~0,05 s de trajet réseau (25 nov. 2026).
    private def request(line : String) : SSH::Result
      process = @process.not_nil!
      process.input.write(self.class.frame(line))
      process.input.flush
      header = process.output.gets
      return lost("connexion fermée") unless header
      fields = header.split(' ')
      unless fields && fields.size == 4 && fields[0] == @marker
        return lost("réponse inattendue #{header.inspect}")
      end
      code, out_size, err_size = fields[1].to_i, fields[2].to_i, fields[3].to_i
      SSH::Result.new(read_exactly(process.output, out_size), read_exactly(process.output, err_size), code)
    rescue ex : IO::Error | ArgumentError
      lost(ex.message || ex.class.name)
    end

    # La requête complète, fin de ligne comprise, en un seul bloc d'octets.
    def self.frame(line : String) : Bytes
      "#{line}\n".to_slice
    end

    private def read_exactly(io : IO, size : Int32) : String
      return "" if size == 0
      slice = Bytes.new(size)
      io.read_fully(slice)
      String.new(slice)
    end

    # Session perdue en cours de route : la commande en vol est rapportée en
    # échec, les suivantes passent par le repli.
    private def lost(why : String) : SSH::Result
      give_up("session interrompue : #{why}")
      SSH::Result.new("", "beryl : shell distant persistant interrompu (#{why}) — commande peut-être jouée, à vérifier", LOST)
    end

    private def give_up(why : String) : Bool
      @alive = false
      detail = @stderr_log.to_s.strip.lines.last(3).join(" | ")
      STDERR.puts "beryl : shell distant persistant : #{why}#{detail.empty? ? "" : " (#{detail})"} — " \
                  "retour à une connexion ssh par commande"
      if process = @process
        process.input.close rescue nil
        process.terminate rescue nil
        process.wait rescue nil
        @process = nil
      end
      false
    end

    # Script d'amorce, lu par le `sh` distant sur son entrée standard.
    # `__beryl_dec` : décodage base64 de la base FreeBSD (`b64decode -r`),
    # sinon `base64 -d` (Linux, macOS). Script non décodable : code 125,
    # comme `Apply.sh_line` (DECODE_FAILED), jamais un script vide joué.
    #
    # `__beryl_reply` assemble la réponse (en-tête + stdout + stderr) dans UN
    # fichier puis l'émet d'un seul `cat` : une seule écriture sur le canal,
    # pour la même raison (Nagle) que la requête, cf. `request`.
    def boot_script : String
      <<-SH
        M='#{@marker}'
        T=$(mktemp -d "${TMPDIR:-/tmp}/beryl.XXXXXX") || exit 1
        trap 'rm -rf "$T"' EXIT
        __beryl_dec() { printf %s "$1" | b64decode -r 2>/dev/null || printf %s "$1" | base64 -d 2>/dev/null; }
        __beryl_reply() {
          { printf '%s %s %s %s\\n' "$M" "$1" $(wc -c <"$T/o") $(wc -c <"$T/e"); cat "$T/o" "$T/e"; } >"$T/r"
          cat "$T/r"
        }
        __beryl_run() {
          s=; [ -n "$1" ] && s=$(__beryl_dec "$1")
          if [ -n "$1" ] && [ -z "$s" ]; then
            : >"$T/o"; echo "beryl : decodage du script impossible (b64decode/base64)" >"$T/e"; __beryl_reply #{DECODE_FAILED}
          else
            sh -c "$s" </dev/null >"$T/o" 2>"$T/e"; __beryl_reply $?
          fi
        }
        __beryl_put() {
          : >"$T/o"; : >"$T/e"
          f=$(mktemp "$T/put.XXXXXX") && __beryl_dec "$4" >"$f" 2>>"$T/e"
          if [ -n "$4" ] && [ ! -s "$f" ]; then echo "beryl : decodage du contenu impossible" >>"$T/e"; rm -f "$f"; __beryl_reply #{DECODE_FAILED}; return; fi
          if [ "$3" = install ]; then
            install -m "${2:-0644}" "$f" "$1" 2>>"$T/e"; rc=$?
          else
            cat "$f" >"$1" 2>>"$T/e" && { [ -z "$2" ] || chmod "$2" "$1" 2>>"$T/e"; }; rc=$?
          fi
          rm -f "$f"; __beryl_reply $rc
        }
        __beryl_echo() { printf '%s 0 0 0\\n' "$M"; }
        printf '%s READY\\n' "$M"

        SH
    end
  end

  # Point d'entrée COMMUN des commandes qui travaillent en root sur un serveur :
  # `sudo` si `user` n'est pas root, et, par défaut, une seule session distante
  # pour toute la commande (`PersistentShell`), avec repli automatique sur un
  # ssh par commande. Le shell rendu se ferme par `close` (sans effet s'il
  # n'est pas persistant).
  #
  # `persistent: false` quand la commande doit VÉRIFIER qu'une NOUVELLE
  # connexion passe encore (vrack : fermeture du 22 public, rotate-key : la
  # nouvelle clé) — une session déjà ouverte masquerait un verrouillage — ou
  # pour un appel isolé (une session de plus n'y gagne rien).
  def self.root_shell(conn : SSH::Connection, user : String, persistent : Bool = true) : Shell
    classic = user == "root" ? SshShell.new(conn) : SudoShell.new(SshShell.new(conn))
    return classic unless persistent
    PersistentShell.open(conn, sudo: user != "root", fallback: classic)
  end

  # `root_shell` le temps du bloc, refermé à la sortie (même sur exception).
  def self.with_root_shell(conn : SSH::Connection, user : String, persistent : Bool = true, &)
    shell = root_shell(conn, user, persistent)
    begin
      yield shell
    ensure
      shell.close
    end
  end
end
