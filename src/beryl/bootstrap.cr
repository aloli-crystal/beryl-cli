require "./bootstrap/mfsbsd"
require "./bootstrap/installer"

module Beryl
  # Bootstrap complet : Linux rescue → mfsBSD → FreeBSD installé.
  #
  # Orchestre les deux phases dans l'ordre et renvoie la connexion finale
  # prête à servir pour `beryl apply`.
  module Bootstrap
  end
end
