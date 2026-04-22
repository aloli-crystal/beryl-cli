# Enregistrement des providers natifs de beryl. Un shard tiers qui
# veut ajouter un nouvel hébergeur fait la même chose dans son propre
# fichier :
#
#   require "beryl"
#   class Beryl::Providers::Hetzner < Beryl::Provider
#     # ...
#   end
#   Beryl::Providers.register(Beryl::Providers::Hetzner.new)
#
# Le require côté utilisateur (dans son shard ou son code applicatif)
# suffit à le rendre visible à `beryl init`.
Beryl::Providers.register(Beryl::Providers::Ovh.new)
Beryl::Providers.register(Beryl::Providers::Scaleway.new)
