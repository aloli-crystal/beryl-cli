require "socket"
require "openssl"
require "base64"

# Client SMTP minimal, pour les courriels de beryl lui-même (récapitulatif
# d'une tâche de flotte) : submission (587) + STARTTLS + AUTH PLAIN, message
# texte UTF-8. Les serveurs, eux, passent par `dma` (recette smtp-relay) ;
# beryl envoie au MÊME relais avec les MÊMES identifiants du coffre
# (`[mail] SMTP_RELAY_USER/PASSWORD/TO`), sans dépendre d'aucun serveur.
#
# Le dialogue (`deliver`) prend un IO : testable sans réseau.
module Beryl::Smtp
  extend self

  class Error < Exception
  end

  record Message, from : String, to : String, subject : String, body : String

  # Envoie `msg` via `host:port` (STARTTLS obligatoire, auth `user`/`password`).
  def send(host : String, port : Int32, user : String, password : String, msg : Message) : Nil
    tcp = TCPSocket.new(host, port, connect_timeout: 15.seconds)
    tcp.read_timeout = 30.seconds
    tcp.write_timeout = 30.seconds
    upgrade = ->(io : IO) do
      ctx = OpenSSL::SSL::Context::Client.new
      OpenSSL::SSL::Socket::Client.new(io, ctx, sync_close: true, hostname: host).as(IO)
    end
    deliver(tcp, user, password, msg, upgrade)
  ensure
    tcp.try &.close rescue nil
  end

  # Dialogue SMTP sur `io`. `upgrade` (STARTTLS) rend l'IO chiffré ; nil =
  # pas de STARTTLS (tests uniquement). Lève `Error` sur toute réponse
  # inattendue, avec la réplique du serveur.
  def deliver(io : IO, user : String, password : String, msg : Message, upgrade : Proc(IO, IO)? = nil) : Nil
    expect(io, 220)
    command(io, "EHLO beryl", 250)
    if up = upgrade
      command(io, "STARTTLS", 220)
      io = up.call(io)
      command(io, "EHLO beryl", 250)
    end
    command(io, "AUTH PLAIN #{Base64.strict_encode("\0#{user}\0#{password}")}", 235, hide: true)
    command(io, "MAIL FROM:<#{msg.from}>", 250)
    command(io, "RCPT TO:<#{msg.to}>", 250, 251)
    command(io, "DATA", 354)
    io << render(msg)
    command(io, ".", 250)
    command(io, "QUIT", 221) rescue nil
  end

  # Message RFC 5322 : objet encodé (RFC 2047), corps UTF-8 en base64 (aucune
  # ligne ne commence par un point → pas de bourrage nécessaire). Pur.
  def render(msg : Message, now : Time = Time.utc) : String
    body64 = Base64.encode(msg.body) # lignes de 60 caractères
    String.build do |s|
      s << "From: <" << msg.from << ">\r\n"
      s << "To: <" << msg.to << ">\r\n"
      s << "Subject: =?UTF-8?B?" << Base64.strict_encode(msg.subject) << "?=\r\n"
      s << "Date: " << now.to_rfc2822 << "\r\n"
      s << "Message-ID: <beryl-" << now.to_unix_ms << "@" << msg.from.split('@').last << ">\r\n"
      s << "MIME-Version: 1.0\r\n"
      s << "Content-Type: text/plain; charset=UTF-8\r\n"
      s << "Content-Transfer-Encoding: base64\r\n"
      s << "\r\n"
      body64.each_line { |l| s << l.chomp << "\r\n" }
    end
  end

  private def command(io : IO, line : String, *codes : Int32, hide : Bool = false) : Nil
    io << line << "\r\n"
    io.flush
    expect(io, *codes, sent: hide ? line.split.first(2).join(" ") + " ***" : line)
  end

  # Lit une réponse (éventuellement multi-ligne `250-…`) et vérifie son code.
  private def expect(io : IO, *codes : Int32, sent : String? = nil) : Nil
    last = ""
    loop do
      line = io.gets || raise Error.new("connexion SMTP fermée#{sent ? " après « #{sent} »" : ""}")
      last = line.chomp
      break unless last.size >= 4 && last[3] == '-'
    end
    code = last[0, 3].to_i? || 0
    return if codes.includes?(code)
    raise Error.new("SMTP « #{sent || "accueil"} » → #{last}")
  end
end
