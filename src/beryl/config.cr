require "yaml"

# Namespace de la configuration beryl dans `~/.beryl/` (ADR-014).
#
# Arborescence :
#
#   ~/.beryl/
#     _default.yml                    # socle technique commun à toutes sociétés
#     .env.yml                        # credentials : société → fournisseur → vars
#     <société>/
#       _account.yml                  # optionnel : métadonnées société
#       <domaine>.yml                 # identité du domaine
#       <domaine>/                    # hosts directs + groupes
#         <host>.yml
#         <groupe>.yml                # propriétés du groupe
#         <groupe>/
#           <host>.yml
#
# Un fichier host dans un groupe garde le même FQDN `<host>.<domaine>`
# que s'il était à la racine du domaine : le groupe n'apparaît PAS
# dans le FQDN. Le groupe ne sert qu'à factoriser les propriétés
# métier (packages, sudoers…).
#
# Hiérarchie d'héritage (du plus général au plus spécifique) :
#   1. `_default.yml`                      — socle commun à tous les domaines
#   2. `<société>/<domaine>.yml`           — identité du domaine
#   3. `<société>/<domaine>/<groupe>.yml`  — spécialisation d'usage (optionnel)
#   4. `<société>/<domaine>/<host>.yml`
#      OU `<société>/<domaine>/<groupe>/<host>.yml`
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
require "./config/zpool"
require "./config/host_node"
require "./config/group"
require "./config/domain"
require "./config/account"
require "./config/env_file"
require "./config/merger"
require "./config/loader"
require "./config/root"
