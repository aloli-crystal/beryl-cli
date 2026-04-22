require "yaml"

# Namespace de la configuration beryl dans `~/.beryl/`.
#
# Arborescence cible (convention fichier+dossier à la Ruby/Crystal,
# 3 niveaux max : `.beryl/ / domaine / groupe`) :
#
#   ~/.beryl/
#     _default.yml           # socle technique FreeBSD (sans clés SSH)
#     .env.yml               # credentials providers par domaine
#     aloli.net.yml          # identité du domaine (ssh_keys, ssh_key_name)
#     aloli.net/             # contenu du domaine (hosts directs + groupes)
#       loulou.yml           # host direct → loulou.aloli.net
#       web.yml              # propriétés du groupe web
#       web/                 # hosts du groupe web
#         rails01.yml        # → rails01.aloli.net
#
# Un fichier host dans un groupe garde le même FQDN `<host>.<domaine>`
# que s'il était à la racine du domaine : le groupe n'apparaît PAS
# dans le FQDN. Le groupe ne sert qu'à factoriser les propriétés
# métier (packages, sudoers…).
#
# Hiérarchie d'héritage (du plus général au plus spécifique) :
#   1. `_default.yml`             — socle commun à tous les domaines
#   2. `<domaine>.yml`            — identité du compte/domaine
#   3. `<domaine>/<groupe>.yml`   — spécialisation d'usage (optionnel)
#   4. `<domaine>/<host>.yml`
#      OU `<domaine>/<groupe>/<host>.yml`
#
# Règles de merge (voir `Beryl::Config::Merger`) :
#   - scalaires : override
#   - freebsd.packages / sudoers : append + dédup
#   - freebsd.users : merge par `name`
#   - freebsd.users[].ssh_keys : remplacement (liste exacte au niveau
#     le plus spécifique) + injection de la clé domaine obligatoire
#   - freebsd.disks : override
module Beryl::Config
end

require "./config/ssh_key_resolver"
require "./config/host_node"
require "./config/group"
require "./config/domain"
require "./config/env_file"
require "./config/merger"
require "./config/loader"
require "./config/root"
