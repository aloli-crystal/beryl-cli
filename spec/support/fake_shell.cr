# Shell factice pour tester les primitives sans serveur SSH réel.
# Enregistre chaque commande exécutée et renvoie un `SSH::Result` stubé
# par motif (regex), calqué sur l'esprit de `FakeOvhTransport`.

require "../../src/beryl/apply/shell"

class FakeShell < Beryl::Apply::Shell
  record Stub, pattern : Regex, result : SSH::Result
  record FileWrite, path : String, content : String, mode : String?

  getter commands = [] of String
  getter writes = [] of FileWrite
  getter stubs = [] of Stub

  # Stub d'une commande : la 1re commande qui matche `pattern` renvoie
  # un `SSH::Result` construit depuis `stdout`/`exit_code`. Les stubs
  # déclarés en dernier l'emportent (cf. FakeOvhTransport).
  def stub(pattern : Regex, stdout : String = "", exit_code : Int32 = 0, stderr : String = "") : Nil
    @stubs << Stub.new(pattern, SSH::Result.new(stdout, stderr, exit_code))
  end

  def exec(command : String, raise_on_error : Bool = true) : SSH::Result
    @commands << command
    text = self.class.readable(command)
    match = @stubs.reverse.find { |s| s.pattern.matches?(text) }
    result = match.try(&.result) || SSH::Result.new("", "", 0)
    raise SSH::CommandFailed.new(command, result) if raise_on_error && !result.success?
    result
  end

  def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
    @writes << FileWrite.new(remote_path, content, mode)
  end

  # Vrai si une des commandes exécutées matche `pattern`.
  def ran?(pattern : Regex) : Bool
    @commands.any? { |c| pattern.matches?(self.class.readable(c)) }
  end

  # La commande suivie, en clair, des scripts multi-lignes qu'elle transporte
  # en base64 (cf. `Beryl::Apply.sh_line`) : les stubs et `ran?` visent ainsi
  # le script réel, encodé ou non.
  def self.readable(command : String) : String
    command.scan(/p=([A-Za-z0-9+\/=]+);/).reduce(command) do |acc, m|
      acc + "\n" + readable(Base64.decode_string(m[1]))
    end
  end
end
