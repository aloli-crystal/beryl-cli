require "../spec_helper"
require "socket"

# Spec d'intégration : exerce beryl contre un banc QEMU local
# (`prod-crystal/qemu/`) avec Tang + ZFS native encryption.
#
# Tagged `:integration` pour ne PAS tourner par défaut avec
# `crystal spec` (qui ne ferait pas tourner l'opérateur d'un
# CI Linux sans QEMU FreeBSD).
#
# Pour l'exécuter manuellement, après avoir démarré le banc :
#
#     cd ~/prod-crystal/qemu
#     ./00-fetch-image.sh                  # 1ʳᵉ fois seulement
#     ./01-prepare-disks.sh
#     ./10-run-tang.sh
#     ./11-run-client.sh
#     ./20-provision-tang.sh
#     ./21-provision-client.sh
#     ./22-promote-root-on-client.sh
#     cd ~/prod-crystal/beryl
#     crystal spec spec/integration/
#
# Si le banc n'est pas démarré, le test est marqué « pending »
# avec un message clair plutôt que d'échouer.
#
# La logique de test elle-même vit dans `qemu/test-beryl.sh`
# (Option I) — la spec ici est juste un wrapper qui exécute le
# script et asserte le code de retour + la ligne de bilan.
# Évite la duplication de logique entre shell et Crystal.

private TEST_BERYL_SCRIPT = File.expand_path(
  File.join(__DIR__, "..", "..", "qemu", "test-beryl.sh")
)

# Tente une connexion TCP rapide. Vrai si le port répond.
private def tcp_open?(host : String, port : Int32, timeout : Time::Span = 1.second) : Bool
  TCPSocket.new(host, port, connect_timeout: timeout).close
  true
rescue
  false
end

# Vrai si le banc QEMU semble démarré (les 5 ports clés répondent).
private def bench_running? : Bool
  tcp_open?("127.0.0.1", 2222) &&   # VM tang SSH
    tcp_open?("127.0.0.1", 2223) && # VM client SSH
    tcp_open?("127.0.0.1", 8888) && # Tang #1
    tcp_open?("127.0.0.1", 8889) && # Tang #2
    tcp_open?("127.0.0.1", 8890)    # Tang #3
end

describe "intégration beryl ↔ crystal-clevis-zfs (banc QEMU)" do
  it "passe les 5 scénarios de test-beryl.sh end-to-end", tags: "integration" do
    unless File.exists?(TEST_BERYL_SCRIPT) && File::Info.executable?(TEST_BERYL_SCRIPT)
      pending! "script #{TEST_BERYL_SCRIPT} absent ou non exécutable"
    end

    unless bench_running?
      pending! "banc QEMU non démarré (lancez prod-crystal/qemu/0[0-9]-*.sh + 22-promote-root-on-client.sh)"
    end

    output = IO::Memory.new
    status = Process.run(
      TEST_BERYL_SCRIPT,
      output: output,
      error: output,
    )
    out = output.to_s

    # On affiche la sortie complète si le test échoue, pour
    # diagnostic. (Crystal spec n'affiche par défaut que le diff
    # des assertions, pas l'exécution préalable.)
    unless status.success? && out.includes?("test-beryl.sh : tous les tests sont passés")
      STDERR.puts "\n--- sortie test-beryl.sh ---\n#{out}\n--- fin ---\n"
    end

    status.success?.should be_true
    out.should match(/\[ OK \] test-beryl.sh : tous les tests sont passés/)

    # Sanity checks ciblés sur le contenu : chaque scénario doit
    # avoir laissé une trace identifiable. Si l'un des tests
    # passait mais sans réelle exécution (ex: skip silencieux), ça
    # remonterait ici.
    out.should match(/T1 unlock ssh_unlock/)
    out.should match(/T2 tang-enroll single-Tang/)
    out.should match(/T3 tang-enroll SSS k=2\/n=3/)
    out.should match(/T4 unlock avec 1 Tang mort/)
  end
end
