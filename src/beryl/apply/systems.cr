module Beryl::Apply
  # Systèmes cibles. FreeBSD est la cible de beryl ; Linux (systemd, SUSE
  # pour `pkg-install`) est pris en charge pour une poignée de primitives
  # seulement (une VM confiée par un client, par exemple), chacune le
  # déclarant dans `Primitive#systems`, chaque recette dans `systems:`.
  FREEBSD = "freebsd"
  LINUX   = "linux"
end
