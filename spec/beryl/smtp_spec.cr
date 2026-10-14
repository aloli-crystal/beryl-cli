require "../spec_helper"
require "../../src/beryl/smtp"

# Faux serveur SMTP en mémoire : rejoue `replies` (une par commande reçue,
# après l'accueil) et enregistre ce que le client envoie.
private def fake_smtp(replies : Array(String), &)
  c2s_r, c2s_w = IO.pipe # client → serveur
  s2c_r, s2c_w = IO.pipe # serveur → client
  received = [] of String
  done = Channel(Nil).new
  spawn do
    s2c_w << "220 relais prêt\r\n"
    s2c_w.flush
    queue = replies.dup
    while (rep = queue.shift?)
      line = c2s_r.gets || break
      received << line.chomp
      s2c_w << rep << "\r\n"
      s2c_w.flush
      next unless line.chomp == "DATA"
      # Corps du message jusqu'au « . » final, puis réponse à ce « . ».
      data = [] of String
      while (l = c2s_r.gets) && l.chomp != "."
        data << l.chomp
      end
      received << data.join("\n")
      break unless (dot = queue.shift?)
      s2c_w << dot << "\r\n"
      s2c_w.flush
    end
  ensure
    c2s_r.close rescue nil
    s2c_w.close rescue nil
    done.send(nil)
  end
  yield IO::Stapled.new(s2c_r, c2s_w), received
  done.receive
end

MSG = Beryl::Smtp::Message.new("relais@example.net", "ops@example.net",
  "[beryl][initech] os-upgrade : 4 mis à jour · 9 échec", "Tâche os-upgrade\n  han  mis à jour  revenu en 15.1-RELEASE-p5\n")

describe Beryl::Smtp do
  it "dialogue complet : EHLO, AUTH PLAIN, MAIL, RCPT, DATA, QUIT" do
    replies = ["250-relais\r\n250 AUTH PLAIN", "235 ok", "250 ok", "250 ok", "354 go", "250 queued", "221 bye"]
    fake_smtp(replies) do |io, received|
      Beryl::Smtp.deliver(io, "relais@example.net", "s3cret", MSG)
      sleep 10.milliseconds
      received[0].should eq("EHLO beryl")
      received[1].should eq("AUTH PLAIN #{Base64.strict_encode("\0relais@example.net\0s3cret")}")
      received[2].should eq("MAIL FROM:<relais@example.net>")
      received[3].should eq("RCPT TO:<ops@example.net>")
      received[4].should eq("DATA")
      data = received[5]
      data.should contain("Subject: =?UTF-8?B?#{Base64.strict_encode(MSG.subject)}?=")
      data.should contain("Content-Type: text/plain; charset=UTF-8")
      body64 = data.split("\n\n", 2).last
      Base64.decode_string(body64.gsub("\n", "")).should eq(MSG.body)
    end
  end

  it "refus du destinataire → erreur avec la réplique du serveur (jamais silencieux)" do
    replies = ["250 relais", "235 ok", "250 ok", "550 5.1.1 destinataire inconnu"]
    fake_smtp(replies) do |io, _received|
      expect_raises(Beryl::Smtp::Error, /RCPT TO.*550 5.1.1 destinataire inconnu/) do
        Beryl::Smtp.deliver(io, "relais@example.net", "s3cret", MSG)
      end
    end
  end

  it "authentification refusée → erreur, mot de passe non répété dans le message" do
    replies = ["250 relais", "535 5.7.8 authentication failed"]
    fake_smtp(replies) do |io, _received|
      ex = expect_raises(Beryl::Smtp::Error, /535/) do
        Beryl::Smtp.deliver(io, "relais@example.net", "s3cret", MSG)
      end
      ex.message.not_nil!.should_not contain("s3cret")
      ex.message.not_nil!.should_not contain(Base64.strict_encode("\0relais@example.net\0s3cret"))
    end
  end
end
