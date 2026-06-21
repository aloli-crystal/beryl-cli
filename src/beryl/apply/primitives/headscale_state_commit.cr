require "../primitive"

module Beryl::Apply
  # Primitive `headscale-state-commit` : ajoute une ligne d'audit au
  # repo d'état headscale (`<company>/headscale-state`, UN par société —
  # cloné localement dans /etc/headscale-state) et la commit. Utilisée par
  # les recipes `sshd-public-open` / `sshd-public-close` pour tracer
  # chaque ouverture/fermeture de la fenêtre port 22.
  #
  # L'audit s'écrit dans un fichier `audit.log` à la racine du repo
  # (pas dans le dump `headscale-state.sql.gz`), pour ne pas être
  # écrasé par le prochain backup automatique. Format :
  #
  #     <RFC3339 UTC> <event-type> <key=value>...
  #
  #     - headscale-state-commit:
  #         message: "PORT 22 PUBLIC OPEN host=loulou.example.net operateur=$USER raison=..."
  #
  # Le `message` est interpolé `{{var}}` par l'Executor en amont ; les
  # variables shell `$USER` etc. sont substituées côté shell distant.
  #
  # Sérialisé via `flock` (le repo est partagé avec le cron de backup).
  # Pré-requis : recipe `headscale-backup` déjà appliquée sur ce host
  # (le repo doit déjà être cloné dans /etc/headscale-state/).
  class HeadscaleStateCommit < Primitive
    REPO_DIR   = "/etc/headscale-state"
    AUDIT_FILE = "audit.log"
    LOCK_FILE  = "/var/run/headscale-state-commit.lock"

    def name : String
      "headscale-state-commit"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      message = required_string(params, "message")

      msg = "audit-commit: #{message[0..60]}#{message.size > 60 ? "..." : ""}"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      # Garde-fou : repo absent → on ne peut rien committer.
      probe = shell.exec("test -d #{Process.quote(REPO_DIR)}/.git", raise_on_error: false)
      unless probe.success?
        return StepResult.failed(
          "repo #{REPO_DIR} absent — appliquez d'abord `headscale-backup` " \
          "et `headscale-backup-init.sh` sur ce host."
        )
      end

      audit_path = "#{REPO_DIR}/#{AUDIT_FILE}"
      hostname = shell.exec("hostname -s", raise_on_error: false).stdout.strip
      timestamp = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      line = "#{timestamp} #{message}"

      # On enchaîne en une commande shell : flock pour sérialiser,
      # append (>>) pour l'audit, git add/commit/push. La deploy key
      # SSH a été posée par l'opérateur (cf. `doc/headscale-setup.adoc`).
      cmd = <<-SHELL
        ( flock -n 9 || exit 0
          echo #{Process.quote(line)} >> #{Process.quote(audit_path)}
          cd #{Process.quote(REPO_DIR)}
          export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519_headscale_state -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
          git add #{Process.quote(AUDIT_FILE)}
          git commit --quiet -m "audit #{hostname} #{message[0..40]}" || exit 0
          git push --quiet origin HEAD 2>&1 | grep -vE '^(remote:|To |[ \t]*$)' || true
        ) 9>#{Process.quote(LOCK_FILE)}
      SHELL

      result = shell.exec(cmd, raise_on_error: false)
      unless result.success?
        return StepResult.failed("commit audit échoue : #{result.stderr.strip[0..200]}")
      end

      StepResult.applied(msg)
    end
  end

  Primitive.register(HeadscaleStateCommit.new)
end
