require "../spec_helper"
require "socket"

# Spec d'intégration : exerce `beryl sync` (moteur de recettes +
# primitives) contre une VRAIE VM FreeBSD du banc QEMU
# (`prod-crystal/qemu/`).
#
# Tagged `:integration` pour ne PAS tourner par défaut avec
# `crystal spec`. Si le banc n'est pas démarré, le test est marqué
# « pending » plutôt que d'échouer (CI Linux sans QEMU).
#
# Pour l'exécuter manuellement, après avoir démarré le banc :
#
#     ~/prod-crystal/beryl/qemu/start-bench.sh
#     cd ~/prod-crystal/beryl && crystal spec spec/integration/
#
# La logique vit dans `qemu/test-apply.sh` ; cette spec est un wrapper
# qui exécute le script et asserte le bilan (évite la duplication).

private TEST_APPLY_SCRIPT = File.expand_path(
  File.join(__DIR__, "..", "..", "qemu", "test-apply.sh")
)

private def tcp_open?(host : String, port : Int32, timeout : Time::Span = 1.second) : Bool
  TCPSocket.new(host, port, connect_timeout: timeout).close
  true
rescue
  false
end

# `beryl sync` n'a besoin que de la VM client (port SSH 2223) — pas
# des Tangs, contrairement à la spec de chiffrement.
private def client_vm_running? : Bool
  tcp_open?("127.0.0.1", 2223)
end

describe "intégration beryl sync (banc QEMU)" do
  it "applique les primitives sur une VM FreeBSD et est idempotent", tags: "integration" do
    unless File.exists?(TEST_APPLY_SCRIPT) && File::Info.executable?(TEST_APPLY_SCRIPT)
      pending! "script #{TEST_APPLY_SCRIPT} absent ou non exécutable"
    end

    unless client_vm_running?
      pending! "VM client QEMU non démarrée (lancez qemu/start-bench.sh)"
    end

    output = IO::Memory.new
    status = Process.run(TEST_APPLY_SCRIPT, output: output, error: output)
    out = output.to_s

    unless status.success? && out.includes?("test-apply.sh : tous les tests sont passés")
      STDERR.puts "\n--- sortie test-apply.sh ---\n#{out}\n--- fin ---\n"
    end

    status.success?.should be_true
    out.should match(/\[ OK \] test-apply.sh : tous les tests sont passés/)

    # Sanity checks ciblés : chaque primitive doit avoir laissé sa trace.
    out.should match(/sysrc-set : variable posée/)
    out.should match(/file-write : owner root:wheel/)
    out.should match(/user-create : utilisateur créé/)
    out.should match(/user-update-keys : clé déployée/)
    out.should match(/sshd-config-set : directive posée/)
    out.should match(/cron-entry : entrée posée/)
    out.should match(/apply #2 : 0 applied \(idempotent\)/)
  end
end
