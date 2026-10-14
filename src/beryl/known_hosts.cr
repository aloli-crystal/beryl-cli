require "file_utils"

module Beryl
  # Oubli des clés d'hôte d'un serveur réinstallé dans le `known_hosts` de
  # l'opérateur.
  #
  # beryl lui-même n'en dépend pas (le shard `ssh` force
  # `UserKnownHostsFile=/dev/null`), mais les `ssh` interactifs de
  # l'opérateur, si : après un rescue ou un bootstrap, la clé d'hôte change
  # et ssh refuse la connexion (« REMOTE HOST IDENTIFICATION HAS CHANGED »).
  #
  # Les entrées sont retirées par `ssh-keygen -R`, qui gère les noms hachés
  # (`HashKnownHosts`) et retire la ligne entière (`nom,ip clé`). Le travail
  # se fait sur une copie : le fichier n'est réécrit qu'une fois, et
  # `known_hosts.old` garde l'état d'avant (pas l'avant-dernier nom traité,
  # comme le ferait une suite de `ssh-keygen -R` directs).
  module KnownHosts
    def self.default_path : String
      Path.home.join(".ssh", "known_hosts").to_s
    end

    # Formes sous lesquelles ssh enregistre un nom : `nom` sur le port 22,
    # `[nom]:port` sinon. Les deux sont retirées quel que soit le port
    # courant (le port a pu changer d'une installation à l'autre).
    def self.patterns(names : Array(String), port : Int32) : Array(String)
      names.reject(&.empty?).uniq.flat_map do |name|
        bracketed = port == 22 ? [] of String : ["[#{name}]:#{port}"]
        [name, "[#{name}]:22"] + bracketed
      end.uniq
    end

    # Retire de `path` toutes les entrées de `names` (sur `port`). Renvoie les
    # noms effectivement trouvés (vide si aucun, ou si le fichier n'existe
    # pas). Lève `IO::Error` si `ssh-keygen` manque ou échoue.
    def self.forget(names : Array(String), port : Int32 = 22, path : String = default_path) : Array(String)
      return [] of String unless File.exists?(path)
      dir = File.tempname("beryl-known-hosts")
      Dir.mkdir(dir, 0o700)
      begin
        work = File.join(dir, "known_hosts")
        FileUtils.cp(path, work)
        found = patterns(names, port).select { |pattern| remove(work, pattern) }
        unless found.empty?
          FileUtils.cp(path, "#{path}.old")
          File.write(path, File.read(work))
        end
        found
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    # `ssh-keygen -R` sort en 0 que le nom soit trouvé ou non : seul le
    # message (« # Host … found: » sur stdout) les distingue.
    private def self.remove(file : String, pattern : String) : Bool
      stdout = IO::Memory.new
      err = IO::Memory.new
      status = Process.run("ssh-keygen", ["-R", pattern, "-f", file], output: stdout, error: err, input: Process::Redirect::Close)
      raise IO::Error.new("ssh-keygen -R #{pattern} : #{err.to_s.strip}") unless status.success?
      stdout.to_s.matches?(/^# Host .+ found:/m)
    end
  end
end
