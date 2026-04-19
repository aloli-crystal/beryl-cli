#!/usr/bin/env ruby
# Mini-serveur HTTP Ruby (stdlib seulement) pour l'étape de provisioning
# des VM de test beryl. Remplace `python3 -m http.server` afin de ne pas
# ajouter de dépendance Python dans un écosystème Ruby/Crystal.
#
# Usage :
#   ./provision-server.rb [DIR] [-p PORT] [-b BIND]
#
# Par défaut : sert le répertoire courant sur 127.0.0.1:8080.
# Compatible Ruby 2.6+ (système macOS), pas de gem nécessaire.

require "socket"
require "uri"

root = "."
port = 8080
bind = "127.0.0.1"

args = ARGV.dup
while (arg = args.shift)
  case arg
  when "-p", "--port"    then port = Integer(args.shift)
  when "-b", "--bind"    then bind = args.shift
  when "-h", "--help"
    puts "usage: #{$0} [DIR] [-p PORT] [-b BIND]"
    exit 0
  else
    root = arg
  end
end

root = File.expand_path(root)
unless File.directory?(root)
  warn "erreur : répertoire introuvable : #{root}"
  exit 1
end

server = TCPServer.new(bind, port)
warn "[provision-server] sert #{root} sur http://#{bind}:#{port}"
warn "[provision-server] Ctrl+C pour arrêter"

%w[INT TERM].each { |sig| trap(sig) { server.close; exit 0 } }

loop do
  client = server.accept
  Thread.new(client) do |c|
    begin
      request_line = c.gets.to_s
      _method, raw_path, _version = request_line.split(" ", 3)
      path = URI.decode_www_form_component(raw_path.to_s.split("?").first.to_s)

      # Saute les en-têtes (jusqu'à la ligne vide).
      while (line = c.gets) && line.strip != ""
      end

      file = File.join(root, path.sub(%r{\A/}, ""))
      # Sécurité : bloque le path-traversal.
      unless File.expand_path(file).start_with?(root + File::SEPARATOR) || File.expand_path(file) == root
        c.print "HTTP/1.0 403 Forbidden\r\n\r\n"
        warn "[provision-server] 403 #{path}"
        next
      end

      if File.file?(file)
        body = File.binread(file)
        c.print "HTTP/1.0 200 OK\r\n"
        c.print "Content-Type: application/octet-stream\r\n"
        c.print "Content-Length: #{body.bytesize}\r\n"
        c.print "Connection: close\r\n\r\n"
        c.write body
        warn "[provision-server] 200 #{path} (#{body.bytesize} o)"
      else
        c.print "HTTP/1.0 404 Not Found\r\n\r\n"
        warn "[provision-server] 404 #{path}"
      end
    rescue => e
      warn "[provision-server] erreur : #{e.class}: #{e.message}"
    ensure
      c.close
    end
  end
end
