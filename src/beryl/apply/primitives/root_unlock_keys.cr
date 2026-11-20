require "../primitive"
require "../../unlock_gate"

module Beryl::Apply
  # Primitive `root-unlock-keys` : accès root LIMITÉ AU DÉVERROUILLAGE ZFS des
  # serveurs à /home chiffré (cf. `Beryl::UnlockGate`), tenu à jour après le
  # bootstrap :
  #
  #   * `/root/.ssh/authorized_keys` = exactement `keys`, chaque clé restreinte
  #     (`restrict,command="/usr/local/sbin/beryl-unlock"`), root:wheel 0600 ;
  #   * `/usr/local/sbin/beryl-unlock` = le script de la version de beryl
  #     (root:wheel 0555).
  #
  # Sémantique « ensemble exact » (clés retirées du YAML → retirées de root).
  # Liste vide → REFUS : root est le seul accès avant le déverrouillage, un
  # fichier vide rendrait le serveur indéverrouillable à distance.
  #
  #     - root-unlock-keys:
  #         keys: ["ssh-ed25519 AAAA… ops@acme"]
  class RootUnlockKeys < Primitive
    AUTHORIZED_KEYS = "/root/.ssh/authorized_keys"

    def name : String
      "root-unlock-keys"
    end

    def systems : Array(String)
      [FREEBSD]
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      keys = string_array(params, "keys").map(&.strip).reject(&.empty?).uniq
      if keys.empty?
        return StepResult.failed("aucune clé : root resterait sans accès au déverrouillage (refus)")
      end
      content = self.class.content(keys)
      script = Beryl::UnlockGate::SCRIPT + "\n"

      keys_stale = shell.exec("cat #{AUTHORIZED_KEYS} 2>/dev/null", raise_on_error: false).stdout != content
      gate_stale = shell.exec("cat #{Beryl::UnlockGate::PATH} 2>/dev/null", raise_on_error: false).stdout != script
      return StepResult.skipped("#{keys.size} clé(s) root et #{Beryl::UnlockGate::PATH} à jour") unless keys_stale || gate_stale

      changes = [] of String
      changes << "#{AUTHORIZED_KEYS} (#{keys.size} clé(s), restreintes)" if keys_stale
      changes << Beryl::UnlockGate::PATH if gate_stale
      return StepResult.applied("#{changes.join(" + ")} à réécrire (dry-run)") if dry_run

      if keys_stale
        shell.exec("mkdir -p /root/.ssh && chmod 700 /root/.ssh")
        shell.write_file(AUTHORIZED_KEYS, content, mode: "0600")
        shell.exec("chown root:wheel #{AUTHORIZED_KEYS}")
      end
      if gate_stale
        shell.exec("mkdir -p #{Process.quote(File.dirname(Beryl::UnlockGate::PATH))}")
        shell.write_file(Beryl::UnlockGate::PATH, script, mode: "0555")
        shell.exec("chown root:wheel #{Beryl::UnlockGate::PATH}")
      end
      StepResult.applied("#{changes.join(" + ")} réécrit(s)")
    end

    # Contenu exact d'authorized_keys de root (fin de ligne finale). Pur.
    def self.content(keys : Array(String)) : String
      keys.map { |k| Beryl::UnlockGate.root_key_line(k) + "\n" }.join
    end
  end

  Primitive.register(RootUnlockKeys.new)
end
