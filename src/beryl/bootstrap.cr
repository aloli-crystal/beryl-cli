require "./bootstrap/mfsbsd_release"
require "./bootstrap/qemu_in_rescue"

# Les classes ci-dessous restent dispo pour les tests et le support
# Legacy BIOS éventuel, mais ne sont plus sur le chemin principal.
# Voir ADR-010 (ARCHITECTURE.adoc) pour le contexte et ADR-011 pour la
# nouvelle voie (Beryl::Bootstrap::QemuInRescue).
require "./bootstrap/mfsbsd"
require "./bootstrap/installer"

module Beryl
  # Bootstrap complet : Linux rescue → FreeBSD 15 installé UEFI-compatible.
  #
  # Depuis ADR-011 (supersede ADR-003), la voie principale est
  # `Beryl::Bootstrap::QemuInRescue` : FreeBSD s'installe dans une VM
  # QEMU lancée *depuis* le rescue Linux, avec le disque réel en
  # passthrough. Résultat : un système UEFI-bootable posé nativement
  # sur le bare metal, sans la couche mfsBSD qui ne boote pas sur les
  # firmwares UEFI-only modernes.
  module Bootstrap
  end
end
