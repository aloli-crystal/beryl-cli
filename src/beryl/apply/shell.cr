require "base64"
require "ssh"

module Beryl::Apply
  # Abstraction de l'exécution de commandes distantes pour les
  # primitives. Découple la logique d'idempotence du transport SSH
  # réel, ce qui permet de tester les primitives sans serveur via un
  # `FakeShell` (même esprit que `FakeOvhTransport` côté providers).
  #
  # Les primitives ne connaissent que cette interface : `exec` (lecture
  # d'état + action) et `write_file`. La signature de retour est
  # `SSH::Result` pour rester homogène avec le shard `ssh`.
  abstract class Shell
    abstract def exec(command : String, raise_on_error : Bool = true) : SSH::Result
    abstract def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
  end

  # Ligne `sh -c …` qui exécute `script` (sh POSIX) quel que soit le shell de
  # connexion distant. Un script d'UNE ligne est simplement cité ; un script
  # multi-ligne voyage en base64 : csh (shell de connexion d'`admin` et des
  # anciens root FreeBSD) refuse un retour à la ligne entre apostrophes
  # (« Unmatched ' », « Illegal variable name », « esac: Command not found »,
  # qwerty, 14 oct. 2026). Le script décodé est passé en ARGUMENT de `sh -c`,
  # pas par un pipe : une commande du script qui lit stdin avalerait la suite.
  # Décodage impossible (ni `b64decode`, base FreeBSD, ni `base64`) → code
  # `DECODE_FAILED` + message, jamais un script vide joué en silence.
  def self.sh_line(script : String) : String
    return "sh -c #{Process.quote(script)}" unless multi_line?(script)
    decoder = "p=#{Base64.strict_encode(script)}; " \
              "s=$(printf %s \"$p\" | b64decode -r 2>/dev/null || printf %s \"$p\" | base64 -d 2>/dev/null); " \
              "[ -n \"$s\" ] || { echo \"beryl : decodage du script impossible (b64decode/base64)\" >&2; exit #{DECODE_FAILED}; }; " \
              "exec sh -c \"$s\""
    "sh -c #{Process.quote(decoder)}"
  end

  # Code de sortie de `sh_line` quand le script n'a pas pu être décodé.
  DECODE_FAILED = 125

  # `command` tel quel s'il tient sur une ligne, sinon transporté par `sh_line`.
  def self.single_line(command : String) : String
    multi_line?(command) ? sh_line(command) : command
  end

  def self.multi_line?(text : String) : Bool
    text.includes?('\n') || text.includes?('\r')
  end

  # Implémentation réelle : délègue à une `SSH::Connection`. La ligne envoyée
  # est d'abord lue par le shell de connexion (csh possible) : un texte
  # multi-ligne passe donc par `Apply.single_line`.
  class SshShell < Shell
    def initialize(@conn : SSH::Connection)
    end

    def exec(command : String, raise_on_error : Bool = true) : SSH::Result
      @conn.exec(Apply.single_line(command), raise_on_error: raise_on_error)
    end

    def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
      @conn.write_file(remote_path, content, mode: mode)
    end
  end

  # Décorateur d'escalade : enrobe un `Shell` pour exécuter chaque commande
  # via `sudo` (NOPASSWD attendu). Utilisé quand beryl se connecte comme un
  # user sudo-capable plutôt que root (root SSH coupé sur les hôtes durcis).
  # Les écritures passent par un temp possédé par le user puis un `sudo
  # install` (root) — l'écriture SFTP directe ne pouvant pas escalader.
  class SudoShell < Shell
    def initialize(@inner : Shell)
    end

    def exec(command : String, raise_on_error : Bool = true) : SSH::Result
      @inner.exec("sudo #{Apply.sh_line(command)}", raise_on_error: raise_on_error)
    end

    def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
      tmp = @inner.exec("mktemp").stdout.strip
      @inner.write_file(tmp, content)
      @inner.exec("sudo install -m #{Process.quote(mode || "0644")} #{Process.quote(tmp)} #{Process.quote(remote_path)}")
      @inner.exec("rm -f #{Process.quote(tmp)}", raise_on_error: false)
    end
  end
end
