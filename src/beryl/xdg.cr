module Beryl
  # Résolution des chemins selon la spec
  # https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html[XDG Base Directory].
  #
  # Tous les fichiers de configuration de beryl (inventaire des sociétés,
  # `_default.yml`, `.env.yml`, clés ZFS data) vivent sous une racine
  # unique : `$XDG_CONFIG_HOME/beryl/` quand la variable est définie,
  # ou `~/.config/beryl/` à défaut.
  #
  # Migration depuis la v0.2.0 : avant le 8 mai 2026, beryl utilisait
  # +~/.beryl/+ (non-XDG). À partir de la v0.2.1, l'opérateur doit
  # déplacer son ancienne arborescence :
  #
  # [source,shell]
  # ----
  # mv ~/.beryl ~/.config/beryl
  # ----
  #
  # Pas de fallback : si +~/.beryl/+ existe encore mais
  # `~/.config/beryl/` est absent, beryl démarre sur un Root vide
  # (« société inconnue »). Volontaire pour rendre la migration
  # explicite (cf. note mémoire `feedback_no_silent_defaults.md`).
  module Xdg
    extend self

    # Dossier de configuration beryl. Honore `$XDG_CONFIG_HOME` si
    # défini (cas des opérateurs Linux qui personnalisent leur
    # arborescence), sinon retombe sur `~/.config/beryl/` (défaut
    # XDG).
    def config_dir : String
      if xdg = ENV["XDG_CONFIG_HOME"]?
        File.join(xdg, "beryl")
      else
        File.expand_path("~/.config/beryl", home: true)
      end
    end
  end
end
