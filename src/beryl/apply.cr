# Moteur `beryl apply` — architecture à 2 niveaux (cf.
# `apply-recipes-architecture.adoc`) :
#
#   * Niveau 1 — PRIMITIVES : tâches élémentaires idempotentes en
#     Crystal natif (`pkg-install`, …), enregistrées dans un registre.
#   * Niveau 2 — RECETTES YAML : fichiers `.yml` reliés par `requires:`,
#     résolus récursivement + tri topologique, exécutés step par step.
#
# Primitives disponibles : pkg-install, pkg-remove, service-enable,
# service-disable, sysrc-set, file-write, file-template, user-create,
# user-update-keys, sshd-config-set, pf-rule, cron-entry,
# headscale-join, assert-env-var, assert-tailscale-up,
# auto-close-schedule, headscale-state-commit. Les recettes
# (ssh-hardening, firewall-pf, headscale-*, …) qui les composent
# vivent dans le dépôt aloli-crystal/beryl-recipes.
require "./apply/shell"
require "./apply/primitive"
require "./apply/primitives/pkg_install"
require "./apply/primitives/pkg_remove"
require "./apply/primitives/service"
require "./apply/primitives/sysrc_set"
require "./apply/primitives/file_write"
require "./apply/primitives/secret_file"
require "./apply/primitives/user_create"
require "./apply/primitives/user_update_keys"
require "./apply/primitives/sshd_config_set"
require "./apply/primitives/pf_rule"
require "./apply/primitives/cron_entry"
require "./apply/primitives/headscale_join"
require "./apply/primitives/assert_env_var"
require "./apply/primitives/assert_tailscale_up"
require "./apply/primitives/auto_close_schedule"
require "./apply/primitives/auto_close_cancel"
require "./apply/primitives/jail_create"
require "./apply/primitives/jail_ops"
require "./apply/primitives/zfs_dataset"
require "./apply/primitives/headscale_state_commit"
require "./apply/primitives/user_shell"
require "./apply/primitives/git_clone"
require "./apply/primitives/user_sync"
require "./apply/primitives/user_ssh_key"
require "./apply/primitives/pkg_versioned"
require "./apply/primitives/postgresql_initdb"
require "./apply/primitives/make_install"
require "./apply/primitives/freshclam"
require "./apply/primitives/clamd_config_set"
require "./apply/primitives/netif"
require "./apply/primitives/group_member"
require "./apply/primitives/directory"
require "./apply/primitives/symlink"
require "./apply/primitives/mariadb_secure"
require "./apply/primitives/github_ssh_key"
require "./apply/primitives/poudriere_build"
require "./apply/primitives/acme_cert"
require "./apply/template"
require "./apply/recipe"
require "./apply/resolver"
require "./apply/executor"

module Beryl::Apply
end
