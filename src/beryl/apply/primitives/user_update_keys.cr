require "../primitive"

module Beryl::Apply
  # Primitive `user-update-keys` : synchronise le fichier
  # `~<user>/.ssh/authorized_keys` avec l'ensemble *exact* des clés
  # déclarées (sémantique « set », pas « append » : les clés absentes
  # de la liste sont retirées du serveur).
  #
  # Idempotence : diff ligne par ligne, comparaison par (type + blob
  # base64) en ignorant le commentaire final.
  #
  # GARDE-FOU : refus explicite de retirer une clé que beryl utilise
  # actuellement pour se connecter (`context.protected_keys`, dérivées
  # de `host.identity_file`). Sans ça, retirer cette clé du YAML puis
  # lancer apply couperait l'accès en plein vol.
  #
  #     - user-update-keys:
  #         user: deploy
  #         keys:
  #           - "ssh-ed25519 AAAA... deploy@acme"
  class UserUpdateKeys < Primitive
    # Type de clé reconnu en tête d'une ligne authorized_keys (après
    # d'éventuelles options). Sert à isoler le couple (type, blob).
    KEY_TYPE = /\A(ssh-(rsa|dss|ed25519)|ecdsa-sha2-[\w-]+|sk-(ssh-ed25519|ecdsa-sha2-[\w-]+)@openssh\.com)\z/

    # Levée par le garde-fou (héritée de PrimitiveError → step failed,
    # stop net).
    class ProtectedKeyRemoval < Primitive::PrimitiveError
    end

    def name : String
      "user-update-keys"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "user")
      desired = string_array(params, "keys")

      home = home_dir(shell, user)
      if home.empty?
        return StepResult.skipped("user #{user} absent (créez-le avec user-create)")
      end

      # Dédup des clés désirées par identité (type+blob), en gardant la
      # 1re ligne brute (avec commentaire) rencontrée.
      desired_by_id = {} of String => String
      desired.each do |line|
        if id = key_id(line)
          desired_by_id[id] ||= line.strip
        end
      end

      current_raw = shell.exec("cat #{Process.quote(home)}/.ssh/authorized_keys 2>/dev/null", raise_on_error: false).stdout
      current_ids = current_raw.lines
        .map(&.strip)
        .reject { |l| l.empty? || l.starts_with?('#') }
        .compact_map { |l| key_id(l) }
        .to_set

      desired_ids = desired_by_id.keys.to_set
      to_add = desired_ids - current_ids
      to_remove = current_ids - desired_ids

      # Garde-fou : aucune clé de connexion de beryl ne doit être retirée.
      protected_ids = context.protected_keys.compact_map { |k| key_id(k) }.to_set
      endangered = to_remove & protected_ids
      unless endangered.empty?
        raise ProtectedKeyRemoval.new(
          "refus de retirer la clé SSH que beryl utilise pour se connecter " \
          "(user #{user}). Gardez-la dans la liste `keys:` ou changez " \
          "`identity_file` avant de la retirer."
        )
      end

      if to_add.empty? && to_remove.empty?
        return StepResult.skipped("#{user} : #{desired_ids.size} clé(s), déjà sync")
      end

      msg = "#{user} : +#{to_add.size} / -#{to_remove.size} clé(s)"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      content = desired_by_id.values.join("\n")
      content += "\n" unless content.empty?
      shell.exec("mkdir -p #{Process.quote(home)}/.ssh && chmod 700 #{Process.quote(home)}/.ssh && chown #{Process.quote(user)} #{Process.quote(home)}/.ssh")
      shell.write_file("#{home}/.ssh/authorized_keys", content, mode: "0600")
      shell.exec("chown #{Process.quote(user)} #{Process.quote(home)}/.ssh/authorized_keys")
      StepResult.applied(msg)
    end

    # Identité d'une clé = "type blob", en sautant d'éventuelles
    # options en tête de ligne. nil si la ligne n'est pas une clé.
    private def key_id(line : String) : String?
      tokens = line.strip.split(/\s+/)
      idx = tokens.index { |t| t.matches?(KEY_TYPE) }
      return nil unless idx
      blob = tokens[idx + 1]?
      return nil unless blob
      "#{tokens[idx]} #{blob}"
    end

    private def home_dir(shell : Shell, user : String) : String
      shell.exec("getent passwd #{Process.quote(user)} | cut -d: -f6", raise_on_error: false).stdout.strip
    end
  end

  Primitive.register(UserUpdateKeys.new)
end
