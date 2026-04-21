require "process"

module Beryl
  module SSH
    # Résultat d'une exécution distante.
    struct Result
      getter stdout : String
      getter stderr : String
      getter exit_code : Int32

      def initialize(@stdout : String, @stderr : String, @exit_code : Int32)
      end

      def success? : Bool
        @exit_code == 0
      end
    end

    # Levée quand une commande distante retourne un code non nul.
    class CommandFailed < Exception
      getter command : String
      getter result : Result

      def initialize(@command : String, @result : Result)
        super(build_message)
      end

      private def build_message : String
        String.build do |io|
          io << "commande distante échouée (exit " << @result.exit_code << ") : " << @command
          unless @result.stderr.empty?
            io << '\n' << "stderr: " << @result.stderr.strip
          end
        end
      end
    end

    # Connexion SSH vers un hôte distant.
    #
    # S'appuie sur les binaires `ssh` et `scp` du système : bénéficie de
    # `~/.ssh/config`, de l'agent, de `ProxyJump`, etc., sans lib native à maintenir.
    class Connection
      getter host : String
      getter user : String
      getter port : Int32
      getter identity_file : String?
      getter options : Hash(String, String)

      def initialize(
        @host : String,
        @user : String = "root",
        @port : Int32 = 22,
        @identity_file : String? = nil,
        @options : Hash(String, String) = {} of String => String,
      )
      end

      # Construit une connexion « bootstrap » qui ne vérifie pas la clé de l'hôte.
      #
      # À n'utiliser que pour le bootstrap mfsBSD où la clé change entre le Linux
      # de rescue et l'image FreeBSD. Dangereux en usage courant (MITM possible).
      def self.insecure_bootstrap(
        host : String,
        user : String = "root",
        port : Int32 = 22,
      ) : Connection
        new(
          host: host,
          user: user,
          port: port,
          options: {
            "StrictHostKeyChecking" => "no",
            "UserKnownHostsFile"    => "/dev/null",
            "LogLevel"              => "ERROR",
          }
        )
      end

      # Exécute une commande distante. Lève `CommandFailed` si `exit_code != 0`,
      # sauf si `raise_on_error: false`.
      def exec(
        command : String,
        stdin : String? = nil,
        raise_on_error : Bool = true,
      ) : Result
        stdout_io = IO::Memory.new
        stderr_io = IO::Memory.new

        status = if stdin
                   Process.run(
                     command: "ssh",
                     args: ssh_args(command),
                     input: IO::Memory.new(stdin),
                     output: stdout_io,
                     error: stderr_io,
                   )
                 else
                   Process.run(
                     command: "ssh",
                     args: ssh_args(command),
                     output: stdout_io,
                     error: stderr_io,
                   )
                 end

        result = Result.new(stdout_io.to_s, stderr_io.to_s, status.exit_code)

        if raise_on_error && !result.success?
          raise CommandFailed.new(command, result)
        end

        result
      end

      # Écrit un contenu dans un fichier distant via `cat > file`.
      # Pratique pour les petits fichiers de configuration.
      def write_file(remote_path : String, content : String, mode : String? = nil) : Nil
        exec("cat > #{Process.quote(remote_path)}", stdin: content)
        exec("chmod #{mode} #{Process.quote(remote_path)}") if mode
      end

      # Transfère un fichier local vers la cible via `scp`.
      def upload(local_path : String, remote_path : String) : Nil
        status = Process.run(
          command: "scp",
          args: scp_args(local_path, "#{@user}@#{@host}:#{remote_path}"),
        )
        raise "scp échoué (exit #{status.exit_code}) : #{local_path} → #{@host}:#{remote_path}" unless status.success?
      end

      # Récupère un fichier distant via `scp`.
      def download(remote_path : String, local_path : String) : Nil
        status = Process.run(
          command: "scp",
          args: scp_args("#{@user}@#{@host}:#{remote_path}", local_path),
        )
        raise "scp échoué (exit #{status.exit_code}) : #{@host}:#{remote_path} → #{local_path}" unless status.success?
      end

      # Liste des arguments pour le binaire `ssh` (exposée pour les tests).
      def ssh_args(command : String) : Array(String)
        base_args + ["#{@user}@#{@host}", command]
      end

      # Liste des arguments pour le binaire `scp` (exposée pour les tests).
      def scp_args(source : String, destination : String) : Array(String)
        args = [] of String
        args << "-P" << @port.to_s
        if identity = @identity_file
          args << "-i" << identity
        end
        @options.each do |key, value|
          args << "-o" << "#{key}=#{value}"
        end
        args << source << destination
        args
      end

      private def base_args : Array(String)
        args = [] of String
        # `-F /dev/null` ignore totalement le ~/.ssh/config de l'utilisateur :
        # beryl a été pris au piège par des lignes polluées dans le config
        # du laptop (bad configuration option → ssh refuse de tourner).
        # Le bootstrap ne doit jamais dépendre d'un état externe du shell.
        args << "-F" << "/dev/null"
        args << "-p" << @port.to_s
        if identity = @identity_file
          args << "-i" << identity
        end
        @options.each do |key, value|
          args << "-o" << "#{key}=#{value}"
        end
        args
      end
    end
  end
end
