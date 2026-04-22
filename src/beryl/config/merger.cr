require "yaml"

module Beryl::Config
  # Fusionne la chaîne d'héritage d'un host pour produire sa config
  # effective.
  #
  # Ordre d'application (du plus général au plus spécifique) :
  #
  #   1. `_default.yml`            (socle technique commun)
  #   2. `<domaine>.yml`           (identité du domaine, users, clé domaine)
  #   3. `<groupe>.yml`            (optionnel, packages/sudoers métier)
  #   4. `<host>.yml`              (spécificités host)
  #
  # Règles de merge :
  #   - Scalaires (hostname, raid, timezone…) : override strict.
  #   - Hashes imbriqués : merge récursif.
  #   - `freebsd.packages` / `freebsd.sudoers` : append + dédup.
  #   - `freebsd.users` : merge par `name`. Pour un user présent dans
  #     plusieurs niveaux, les scalaires (shell, primary_group…) sont
  #     overridés, et `ssh_keys` est remplacé par la liste la plus
  #     spécifique (pas append).
  #   - `freebsd.disks` : override strict.
  #   - `freebsd.users[].ssh_keys` : chaque user reçoit EN PLUS la ou
  #     les clés SSH du domaine (champ racine `ssh_keys:` du fichier
  #     `<domaine>.yml`) injectées en tête. La clé domaine est
  #     obligatoire, non supprimable par un niveau inférieur.
  module Merger
    # Produit le Hash YAML effectif d'un host, en partant de defaults
    # et en appliquant les niveaux un à un. La clé domaine est
    # injectée dans chaque user après le merge, et toutes les clés
    # SSH (domaine + user) sont résolues via `Config.resolve_ssh_key`
    # (nom de fichier dans `ssh_dir` → contenu, ou inline si la chaîne
    # commence par `ssh-`).
    def self.merge(
      defaults : Hash(YAML::Any, YAML::Any),
      domain : Domain,
      group : Group?,
      host : HostNode,
      ssh_dir : String = DEFAULT_SSH_DIR,
    ) : Hash(YAML::Any, YAML::Any)
      result = {} of YAML::Any => YAML::Any
      result = deep_merge(result, defaults, path: "")
      result = deep_merge(result, domain.raw, path: "")
      result = deep_merge(result, group.raw, path: "") if group
      result = deep_merge(result, host.raw, path: "")

      # Injection de la ou des clés SSH du domaine dans chaque user.
      # Résolution des noms de fichiers `xxx.pub` en contenu effectif.
      domain_keys_resolved = Beryl::Config.resolve_ssh_keys(domain.ssh_keys, ssh_dir)
      result = inject_domain_keys_into_users(result, domain_keys_resolved, ssh_dir)

      result
    end

    # Merge récursif avec règles spécifiques pour les chemins connus.
    # `path` suit la position dans l'arbre (ex: "freebsd.packages").
    def self.deep_merge(
      base : Hash(YAML::Any, YAML::Any),
      override : Hash(YAML::Any, YAML::Any),
      path : String,
    ) : Hash(YAML::Any, YAML::Any)
      result = base.dup
      override.each do |k, v|
        key_name = k.as_s? || k.to_s
        sub_path = path.empty? ? key_name : "#{path}.#{key_name}"
        existing = result[k]?

        if existing && (eh = existing.as_h?) && (vh = v.as_h?)
          result[k] = YAML::Any.new(deep_merge(eh, vh, path: sub_path))
        elsif existing && (ea = existing.as_a?) && (va = v.as_a?) && append_array_path?(sub_path)
          result[k] = YAML::Any.new(merge_arrays(ea, va, sub_path))
        else
          result[k] = v
        end
      end
      result
    end

    # Chemins dont les arrays s'appendent au lieu de se remplacer.
    # Liste volontairement courte et explicite — pas de règle globale
    # « toutes les arrays s'appendent » pour éviter les surprises
    # (disks, ssh_keys qui doivent rester override).
    def self.append_array_path?(path : String) : Bool
      {"freebsd.packages", "freebsd.sudoers", "freebsd.users"}.includes?(path)
    end

    def self.merge_arrays(
      base : Array(YAML::Any),
      override : Array(YAML::Any),
      path : String,
    ) : Array(YAML::Any)
      if path == "freebsd.users"
        # Merge par `name` : pour chaque user, fusion des scalaires,
        # `ssh_keys` du niveau supérieur remplace celui du niveau base.
        merge_users(base, override)
      else
        # packages / sudoers : append + dédup par contenu.
        seen = [] of YAML::Any
        (base + override).each { |item| seen << item unless seen.includes?(item) }
        seen
      end
    end

    # Merge de deux listes de users par leur champ `name`. Pour un
    # user présent des deux côtés, on applique un deep_merge (scalaires
    # overridés). `ssh_keys` est remplacé par la version du niveau
    # supérieur (pas append, cohérent avec la sémantique déclarative
    # voulue pour `beryl apply`).
    def self.merge_users(base : Array(YAML::Any), override : Array(YAML::Any)) : Array(YAML::Any)
      by_name = {} of String => YAML::Any
      order = [] of String

      base.each do |u|
        if (h = u.as_h?) && (n = h[YAML::Any.new("name")]?.try(&.as_s?))
          by_name[n] = u
          order << n
        end
      end

      override.each do |u|
        h = u.as_h?
        next unless h
        n = h[YAML::Any.new("name")]?.try(&.as_s?)
        next unless n

        if existing = by_name[n]?
          # Fusion champ par champ. `ssh_keys` prend la version override
          # telle quelle (pas d'append dans les users).
          existing_hash = existing.as_h
          merged = existing_hash.dup
          h.each do |fk, fv|
            merged[fk] = fv
          end
          by_name[n] = YAML::Any.new(merged)
        else
          by_name[n] = u
          order << n
        end
      end

      order.map { |n| by_name[n] }
    end

    # Injecte la ou les clés SSH du domaine en tête de `ssh_keys` de
    # chaque user. Les clés que chaque user déclare sont aussi
    # résolues (nom de fichier → contenu), puis filtrées pour éviter
    # les doublons avec la clé domaine. La clé domaine ne peut pas
    # être supprimée par un niveau inférieur : elle est *toujours*
    # présente en tête.
    def self.inject_domain_keys_into_users(
      config : Hash(YAML::Any, YAML::Any),
      domain_keys_resolved : Array(String),
      ssh_dir : String = DEFAULT_SSH_DIR,
    ) : Hash(YAML::Any, YAML::Any)
      freebsd_any = config[YAML::Any.new("freebsd")]?
      return config unless freebsd_any
      freebsd_hash = freebsd_any.as_h? || return config
      users_any = freebsd_hash[YAML::Any.new("users")]?
      return config unless users_any
      users_array = users_any.as_a? || return config

      domain_keys_as_any = domain_keys_resolved.map { |k| YAML::Any.new(k) }

      new_users = users_array.map do |user_any|
        user_hash = user_any.as_h
        existing_keys_any = user_hash[YAML::Any.new("ssh_keys")]?
        existing_raw = (existing_keys_any.try(&.as_a?) || [] of YAML::Any).compact_map(&.as_s?)
        # Résolution de chaque entrée (nom de fichier → contenu, ou
        # inline tel quel). Les clés déjà présentes dans le domaine
        # sont filtrées pour dédup.
        existing_resolved = existing_raw.map { |k| Beryl::Config.resolve_ssh_key(k, ssh_dir) }
        final_keys = domain_keys_as_any + existing_resolved.reject { |k| domain_keys_resolved.includes?(k) }.map { |k| YAML::Any.new(k) }

        new_user_hash = user_hash.dup
        new_user_hash[YAML::Any.new("ssh_keys")] = YAML::Any.new(final_keys)
        YAML::Any.new(new_user_hash)
      end

      new_freebsd_hash = freebsd_hash.dup
      new_freebsd_hash[YAML::Any.new("users")] = YAML::Any.new(new_users)
      new_config = config.dup
      new_config[YAML::Any.new("freebsd")] = YAML::Any.new(new_freebsd_hash)
      new_config
    end
  end
end
