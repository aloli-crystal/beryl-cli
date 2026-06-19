module Beryl::Config
  # Lecture unifiée de `freebsd.users`. Deux formes acceptées :
  #
  #   NOUVELLE (préférée) — l'utilisateur est la CLÉ, toute sa config dessous :
  #     users:
  #       - deploy:
  #           groups: [www, wheel]
  #           shell: oh-my-zsh          # recette OU /chemin/vers/shell
  #           sudo: true
  #           ssh_keys: [...]
  #
  #   LEGACY — un champ `name:` :
  #     users:
  #       - name: deploy
  #         groups: [www, wheel]
  #
  # → une suite d'`Entry(name, fields)`, `fields` = la config (sans le nom).
  #
  # `shell` est polymorphe (idée de Philippe) : un `/chemin` est posé par la
  # primitive `user-shell` (gère le CHANGEMENT, ex. `/bin/csh` → `/bin/bash`) ;
  # sinon c'est le nom d'une RECETTE (ex. `oh-my-zsh`) qui pose son propre shell.
  module Users
    extend self

    record Entry, name : String, fields : Hash(YAML::Any, YAML::Any) do
      # Valeur brute du champ `shell`, ou nil.
      def shell : String?
        fields[YAML::Any.new("shell")]?.try(&.as_s?)
      end

      # `shell` est un chemin (`/…`) → primitive user-shell. nil sinon.
      def shell_path : String?
        s = shell
        s && s.starts_with?('/') ? s : nil
      end

      # `shell` est le nom d'une RECETTE (pas un chemin) → à déclencher. nil sinon.
      def shell_recipe : String?
        s = shell
        s && !s.starts_with?('/') ? s : nil
      end
    end

    # Parse un élément de la liste `users`. nil si forme non reconnue.
    def entry(elem : YAML::Any) : Entry?
      h = elem.as_h?
      return nil unless h
      # Legacy : un champ `name:` (valeur chaîne).
      if name = h[YAML::Any.new("name")]?.try(&.as_s?)
        fields = h.dup
        fields.delete(YAML::Any.new("name"))
        return Entry.new(name, fields)
      end
      # Nouvelle forme : mapping à UNE seule clé (le nom), valeur = hash (ou vide).
      if h.size == 1
        k, v = h.first
        if kn = k.as_s?
          return Entry.new(kn, v.as_h?.try(&.dup) || {} of YAML::Any => YAML::Any)
        end
      end
      nil
    end

    # `Entry`s d'une liste `users` (formes mixtes tolérées, ordre préservé).
    def list(users : Array(YAML::Any)) : Array(Entry)
      users.compact_map { |e| entry(e) }
    end

    # Reconstruit un élément de liste `users` en forme NOUVELLE `{ name: fields }`.
    def build(name : String, fields : Hash(YAML::Any, YAML::Any)) : YAML::Any
      YAML::Any.new({YAML::Any.new(name) => YAML::Any.new(fields)})
    end
  end
end
