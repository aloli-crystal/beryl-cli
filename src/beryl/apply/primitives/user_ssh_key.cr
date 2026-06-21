require "../primitive"

module Beryl::Apply
  # Primitive `user-ssh-key` : génère la clé d'identité SSH d'un user sur le
  # serveur (`~user/.ssh/id_ed25519`), de type ed25519, avec le commentaire
  # `<user>@<fqdn>` (ex. `admin@han.example.net`). Idempotente : skip si la
  # clé existe déjà (on ne réécrit JAMAIS une clé privée).
  #
  #     - user-ssh-key:
  #         name: admin
  #         fqdn: han.example.net   # optionnel ; sinon var `fqdn` du contexte
  #
  # Le `fqdn` est pris dans les params, sinon dans le contexte (var `fqdn`),
  # sinon via `hostname` sur le serveur.
  class UserSshKey < Primitive
    def name : String
      "user-ssh-key"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      user = required_string(params, "name")
      line = shell.exec("getent passwd #{Process.quote(user)} 2>/dev/null", raise_on_error: false).stdout.strip
      return StepResult.skipped("user #{user} absent — pas de clé") if line.empty?

      home = line.split(':')[5]?
      home = "/home/#{user}" if home.nil? || home.empty?
      key = "#{home}/.ssh/id_ed25519"
      if shell.exec("test -e #{Process.quote(key)}", raise_on_error: false).success?
        return StepResult.skipped("#{user} : clé ssh déjà présente")
      end

      fqdn = string(params, "fqdn")
      fqdn = context.vars["fqdn"]? if fqdn.nil? || fqdn.empty?
      if fqdn.nil? || fqdn.empty?
        fqdn = shell.exec("hostname", raise_on_error: false).stdout.strip
      end
      comment = "#{user}@#{fqdn}"
      return StepResult.applied("#{user} : générerait #{comment} (dry-run)") if dry_run

      ssh_dir = "#{home}/.ssh"
      shell.exec("mkdir -p #{Process.quote(ssh_dir)}")
      shell.exec("ssh-keygen -t ed25519 -C #{Process.quote(comment)} -f #{Process.quote(key)} -N '' -q")
      shell.exec("chown -R #{Process.quote(user)} #{Process.quote(ssh_dir)}")
      shell.exec("chmod 700 #{Process.quote(ssh_dir)}")
      shell.exec("chmod 600 #{Process.quote(key)}")
      StepResult.applied("#{user} : clé ssh-ed25519 générée (#{comment})")
    end
  end

  Primitive.register(UserSshKey.new)
end
