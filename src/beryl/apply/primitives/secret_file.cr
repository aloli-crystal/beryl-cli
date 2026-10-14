require "../primitive"
require "./file_write"

module Beryl::Apply
  # Primitive `secret-file` : écrit un fichier dont une ou plusieurs
  # parties sont injectées depuis des variables d'environnement
  # (alimentées par le coffre chiffré de la société — cf.
  # `EnvFile#apply_all_to_env`). Typiquement la PAIRE [utilisateur,
  # mot de passe] d'un compte SMTP.
  #
  # Les valeurs ne transitent JAMAIS par le YAML de recette, par git, par
  # la ligne de commande, ni par les logs :
  #   * la recette ne porte que des PLACEHOLDERS (`@@USER@@`, `@@SECRET@@`…)
  #     et les NOMS des variables d'env — jamais les valeurs ;
  #   * les valeurs sont lues côté beryl dans `ENV[...]` au moment de
  #     l'apply, substituées en mémoire, puis écrites via `write_file`
  #     (transport SFTP — pas d'argv → pas de fuite `ps`) ;
  #   * les messages (`StepResult`, dry-run) ne citent que le chemin,
  #     jamais le contenu.
  #
  #     - secret-file:
  #         path: /usr/local/etc/dma/auth.conf
  #         mode: "0600"             # défaut "0600" (fichier sensible)
  #         env:                     # placeholder → NOM de variable (coffre)
  #           "@@USER@@":   SMTP_RELAY_USER
  #           "@@SECRET@@": SMTP_RELAY_PASSWORD
  #         content: |
  #           @@USER@@|{{ smarthost }}:@@SECRET@@
  #
  # Variables PAR SERVEUR : pour chaque nom, beryl cherche d'abord
  # `<NOM>__<HÔTE>` (ex. `PARTIDUO_AGENT_TOKEN__LOULOU`), puis `<NOM>`. Avec
  # `per_host: true`, seule la variante du serveur est acceptée : un jeton ou
  # une clé propre à chaque serveur n'est jamais pris dans la valeur commune.
  #
  # Note : les noms de variables (sous-map `env`) sont en DUR — l'Executor
  # n'interpole que les strings de premier niveau (donc `content`), pas les
  # sous-maps. Les `{{ … }}` non secrets vont dans `content`.
  #
  # Hérite de `FileWrite` pour l'idempotence (SHA-256) et l'écriture ;
  # seules la résolution des valeurs et le `mode` par défaut diffèrent.
  class SecretFile < FileWrite
    def name : String
      "secret-file"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      content = required_string(params, "content")
      env_map = parse_env_map(params)
      per_host = params["per_host"]?.try(&.as_bool?) == true
      if env_map.empty?
        return StepResult.failed("secret-file : sous-map `env` (placeholder → variable d'env) requis.")
      end

      rendered = content
      env_map.each do |placeholder, var_name|
        # Garde-fou : sans le placeholder dans le contenu, la valeur ne
        # serait jamais injectée → recette probablement erronée.
        unless content.includes?(placeholder)
          return StepResult.failed(
            "placeholder `#{placeholder}` absent du contenu — `#{var_name}` ne serait pas injecté."
          )
        end
        value = Apply.secret(var_name, context, per_host: per_host)
        if value.nil?
          host = context.vars["hostname"]? || ""
          wanted =
            if per_host && !host.empty?
              "`#{Apply.host_secret_name(var_name, host)}` (propre à ce serveur, per_host)"
            elsif host.empty?
              "`#{var_name}`"
            else
              "`#{Apply.host_secret_name(var_name, host)}` ou `#{var_name}`"
            end
          return StepResult.failed(
            "variable #{wanted} absente ou vide. " \
            "Posez-la dans le coffre de la société (`beryl env edit <société>`) puis relancez."
          )
        end
        rendered = rendered.gsub(placeholder, value)
      end

      # Délègue à FileWrite (idempotence SHA-256 + écriture SFTP). Ses
      # messages ne citent QUE le chemin → les valeurs ne fuitent pas.
      # `mode` par défaut 0600 (fichier sensible) si non précisé.
      delegated = params.reject("per_host")
      delegated["content"] = YAML::Any.new(rendered)
      delegated["mode"] = params["mode"]? || YAML::Any.new("0600")
      super(shell, delegated, dry_run, context)
    end

    # Parse le sous-map `env:` → Hash(placeholder => nom de variable).
    private def parse_env_map(params : Hash(String, YAML::Any)) : Hash(String, String)
      result = {} of String => String
      if any = params["env"]?
        if h = any.as_h?
          h.each do |k, v|
            ks = k.as_s?
            vs = v.as_s?
            result[ks] = vs if ks && vs
          end
        end
      end
      result
    end
  end

  Primitive.register(SecretFile.new)
end
