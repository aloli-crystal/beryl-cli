module Beryl
  # Module de traduction minimaliste. Pas de moteur externe (reste noir
  # et blanc) : une `Hash` par locale, lookup par clé symbolique,
  # interpolation simple par `%{key}`.
  #
  # Locale détectée via `LC_ALL` / `LC_MESSAGES` / `LANG` (deux premiers
  # caractères) ; retombe sur `:en` si inconnue. Ajouter une langue =
  # ajouter une entrée dans `MESSAGES`.
  #
  # Usage :
  #
  #     Beryl::I18n.t(:rescue_ovh_trigger, service: "ns1.eu", key: "laptop")
  #     # => "OVH : prepare_rescue pour ns1.eu (clé : laptop)."
  #
  # Convention d'écriture des traductions : phrases complètes, majuscule
  # initiale et ponctuation finale, ton neutre.
  module I18n
    # Dictionnaire central. Les clés sont des symboles explicites, les
    # valeurs des strings avec placeholders `%{name}` interpolés par
    # `sprintf`-like via `String#gsub(/%\{(\w+)\}/)`.
    MESSAGES = {
      # --- Début cmd_bootstrap (cli.cr) -------------------------------
      bootstrap_header: {
        fr: "Bootstrap de %{host} (hostname cible : %{hostname}, disque : %{disk}).",
        en: "Bootstrapping %{host} (target hostname: %{hostname}, disk: %{disk}).",
      },
      bootstrap_path: {
        fr: "FreeBSD %{version} — voie mfsBSD-in-QEMU (ADR-012).",
        en: "FreeBSD %{version} — mfsBSD-in-QEMU path (ADR-012).",
      },
      bootstrap_keys_loaded: {
        fr: "%{count} clé(s) SSH chargée(s) depuis %{path}.",
        en: "Loaded %{count} SSH key(s) from %{path}.",
      },
      bootstrap_users_loaded: {
        fr: "%{count} utilisateur(s) à créer : %{names}.",
        en: "%{count} user(s) to create: %{names}.",
      },
      bootstrap_done: {
        fr: "Bootstrap terminé pour %{host}.",
        en: "Bootstrap completed for %{host}.",
      },

      # --- Étapes bootstrap (qemu_in_rescue.cr) -----------------------
      step_1_verify_linux: {
        fr: "1/7 — Vérifie que le rescue tourne bien sous Linux.",
        en: "1/7 — Checking that the rescue is running Linux.",
      },
      step_2_apt_install: {
        fr: "2/7 — Installe qemu-system-x86, sshpass et curl côté rescue.",
        en: "2/7 — Installing qemu-system-x86, sshpass and curl on the rescue.",
      },
      step_3_download_mfsbsd: {
        fr: "3/7 — Télécharge l'image mfsBSD SE %{version} si nécessaire.",
        en: "3/7 — Downloading mfsBSD SE %{version} image if needed.",
      },
      step_4_write_installerconfig: {
        fr: "4/7 — Écrit l'installerconfig côté rescue.",
        en: "4/7 — Writing installerconfig on the rescue.",
      },
      step_5_launch_qemu: {
        fr: "5/7 — Lance QEMU avec mfsBSD + disque %{disk} passthrough.",
        en: "5/7 — Launching QEMU with mfsBSD + %{disk} passthrough.",
      },
      step_6_upload_install: {
        fr: "6/7 — Upload installerconfig + bsdinstall (10 à 25 min).",
        en: "6/7 — Uploading installerconfig + running bsdinstall (10 to 25 min).",
      },
      step_7_reboot_bare_metal: {
        fr: "7/7 — Reboot bare metal sur la FreeBSD posée, attente SSH.",
        en: "7/7 — Rebooting bare metal into the installed FreeBSD, waiting for SSH.",
      },

      # --- Étapes rescue (cli/rescue.cr) ------------------------------
      rescue_ovh_trigger: {
        fr: "OVH : prepare_rescue pour %{service} (clé : %{key}).",
        en: "OVH: prepare_rescue for %{service} (key: %{key}).",
      },
      rescue_ovh_task_initial: {
        fr: "OVH : tâche #%{id} (%{function}) en %{status}.",
        en: "OVH: task #%{id} (%{function}) in %{status}.",
      },
      rescue_ovh_task_status: {
        fr: "OVH : tâche #%{id} en %{status}.",
        en: "OVH: task #%{id} in %{status}.",
      },
      rescue_scaleway_trigger: {
        fr: "Scaleway : reboot(Rescue) sur %{id}%{zone_suffix}.",
        en: "Scaleway: reboot(Rescue) on %{id}%{zone_suffix}.",
      },
      rescue_scaleway_result: {
        fr: "Scaleway : serveur %{id} passé en status = %{status}.",
        en: "Scaleway: server %{id} now in status = %{status}.",
      },
      rescue_wait_ssh: {
        fr: "Attente SSH sur %{host} (port %{port}, user root, timeout %{timeout} min).",
        en: "Waiting for SSH on %{host} (port %{port}, user root, timeout %{timeout} min).",
      },
      rescue_no_wait: {
        fr: "Commande rescue envoyée à l'API ; attente SSH désactivée (--no-wait).",
        en: "Rescue command sent to API; SSH wait disabled (--no-wait).",
      },
    }

    # Retourne la locale active (`:fr` ou `:en`).
    def self.locale : Symbol
      {"LC_ALL", "LC_MESSAGES", "LANG"}.each do |var|
        v = ENV[var]?
        next if v.nil? || v.empty?
        return :fr if v.starts_with?("fr")
        break # autre variable définie : on considère qu'on est en non-fr
      end
      :en
    end

    # Traduit une clé dans la locale active, avec interpolation.
    # Lève `KeyError` si la clé ou la locale n'existe pas (erreur de
    # programmation, mieux vaut crasher vite que renvoyer du texte
    # incohérent).
    def self.t(key : Symbol, **params) : String
      entry = MESSAGES[key]
      template = entry[locale]? || entry[:en]
      interpolate(template, params)
    end

    private def self.interpolate(template : String, params) : String
      # Crystal n'a pas String#to_sym : on matérialise les params en Hash
      # (clés string) avant le gsub.
      params_hash = {} of String => String
      params.each { |k, v| params_hash[k.to_s] = v.to_s }
      template.gsub(/%\{(\w+)\}/) do |_|
        name = $1
        params_hash[name]? || "%{#{name}}"
      end
    end
  end
end
