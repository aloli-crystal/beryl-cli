require "option_parser"
require "file_utils"
require "../config"
require "../providers"
require "./credentials"

# Sous-commande `beryl init [provider]` : amorce l'arborescence
# `~/.beryl/` avec un domaine et ses credentials.
#
# Première invocation :
#   - crée `_default.yml` (socle FreeBSD : timezone, raid, users,
#     packages de base), sans clés SSH
#   - prompt interactif pour les credentials du provider choisi,
#     sauvegarde dans `.env.yml`
#   - prompt pour la zone DNS → crée `<zone>.yml` avec ssh_key_name
#     OVH auto-détectée et une clé SSH admin importée de ~/.ssh/*.pub
#
# Invocations suivantes :
#   - ajoute un nouveau domaine dans l'existant (sans toucher aux
#     autres). `.env.yml` gagne juste une section.
module Beryl::CLI::Init
  EXIT_OK      = 0
  EXIT_USAGE   = 1
  EXIT_ABORTED = 2

  class Aborted < Exception
  end

  def self.run(config_root : String, args : Array(String)) : Int32
    provider_hint : String? = nil
    zone_flag : String? = nil
    ssh_key_name_flag : String? = nil
    admin_key_file : String? = nil
    force = false
    dry_run = false
    non_interactive = false
    regen_credentials = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl init [provider] [options]\n\n" \
                 "Ajoute un domaine dans ~/.beryl/ (ou crée l'arborescence la première fois)."
      p.on("-z NAME", "--zone=NAME", "Zone DNS (ex: aloli.net)") { |v| zone_flag = v }
      p.on("-s NAME", "--ssh-key-name=NAME", "Label de la clé SSH chez l'hébergeur (auto via API si absent)") { |v| ssh_key_name_flag = v }
      p.on("-k FILE", "--admin-key=FILE", "Fichier .pub local (auto via ~/.ssh/ sinon)") { |v| admin_key_file = File.expand_path(v, home: true) }
      p.on("-n", "--dry-run", "Affiche les fichiers qui seraient créés sans rien écrire") { dry_run = true }
      p.on("-f", "--force", "Écrase les fichiers existants") { force = true }
      p.on("-N", "--non-interactive", "Aucune invite (tout via flags)") { non_interactive = true }
      p.on("-r", "--regen-credentials", "Force la régénération des credentials dérivés (ex: OVH consumer key)") { regen_credentials = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    provider_hint ||= positional.first?

    Dir.mkdir_p(config_root) unless dry_run
    env_path = File.join(config_root, ".env.yml")
    env_file = Beryl::Config::EnvFile.load(env_path)
    STDERR.puts "DRY-RUN : mode simulation, aucun fichier écrit" if dry_run

    # Étape 1 — Choix du provider (parmi ceux implémentés)
    provider = pick_provider(provider_hint, non_interactive)
    return EXIT_USAGE unless provider

    # Étape 2 — Zone DNS (= nom du domaine). Demandée AVANT les
    # credentials car ils seront écrits dans `.env.yml[<zone>]`.
    zone_in = zone_flag
    zone : String = zone_in ? zone_in : (non_interactive ? raise("--zone requis en --non-interactive") : ask("Zone DNS du domaine (ex: aloli.net) : ", ""))
    return EXIT_USAGE if zone.empty?

    domain_yml = File.join(config_root, "#{zone}.yml")

    # Mode --regen-credentials : court-circuit dédié à la
    # régénération d'une credential dérivée (ex: OVH consumer key
    # sans le droit PUT /services/*). Le fichier domaine et les clés
    # SSH sont laissés intacts. Ce mode marche sur une install déjà
    # complète : on n'a pas à repasser par le wizard entier.
    if regen_credentials
      STDERR.puts "[beryl init] Mode --regen-credentials : on ne touche ni à #{domain_yml} ni aux clés SSH."
      unless ensure_credentials_for(provider, zone, env_file, env_path, non_interactive, regen_credentials, dry_run: dry_run)
        return EXIT_ABORTED
      end
      STDERR.puts
      STDERR.puts "[beryl init] Credentials régénérés pour `#{zone}` dans #{env_path}."
      return EXIT_OK
    end

    if File.exists?(domain_yml) && !force
      STDERR.puts "beryl : #{domain_yml} existe déjà (utilisez --force pour écraser, ou --regen-credentials pour juste régénérer les credentials)"
      return EXIT_USAGE
    end

    # Étape 3 — Credentials du provider pour CE domaine. On garantit
    # qu'ils sont persistés dans `.env.yml[<zone>]`, peu importe leur
    # provenance actuelle (shell, fichier, à saisir). Si le provider
    # expose un flux d'auto-génération (ex: OVH consumer key via
    # /auth/credential), il est déclenché ici automatiquement.
    unless ensure_credentials_for(provider, zone, env_file, env_path, non_interactive, regen_credentials, dry_run: dry_run)
      return EXIT_ABORTED
    end

    # Étape 4 — Clé SSH provider + fichier .pub local
    selection = select_ssh_key(provider, ssh_key_name_flag, admin_key_file, non_interactive)
    return EXIT_ABORTED unless selection

    # Étape 5 — Écriture du socle _default.yml s'il n'existe pas
    defaults_path = File.join(config_root, "_default.yml")
    if dry_run
      if File.exists?(defaults_path)
        STDERR.puts "DRY-RUN : #{defaults_path} existe déjà, pas écrasé"
      else
        STDERR.puts "DRY-RUN : #{defaults_path} serait créé (#{default_yaml_content.size} octets)"
      end
    else
      unless File.exists?(defaults_path)
        File.write(defaults_path, default_yaml_content)
        STDERR.puts "[beryl init] _default.yml créé"
      end
    end

    # Étape 6 — Écriture du fichier domaine
    admin_key_content = selection[:admin_key_content]
    domain_content = render_domain_yaml(provider, selection[:provider_key_id], admin_key_content)
    if dry_run
      STDERR.puts "DRY-RUN : #{domain_yml} serait créé avec :"
      STDERR.puts "─" * 60
      STDERR.puts domain_content
      STDERR.puts "─" * 60
    else
      File.write(domain_yml, domain_content)
      STDERR.puts "[beryl init] #{domain_yml} créé"
    end

    STDERR.puts
    STDERR.puts "[beryl init] Domaine `#{zone}` initialisé dans #{config_root}"
    STDERR.puts "Prochaines étapes :"
    STDERR.puts "  1. Relisez #{domain_yml} (ssh_keys, ovh.ssh_key_name)"
    STDERR.puts "  2. Pour ajouter un serveur :"
    STDERR.puts "       beryl rescue <service_name_ou_FQDN> --domain=#{zone}"
    STDERR.puts "       beryl scan   <service_name> --domain=#{zone} --dns --write"
    EXIT_OK
  rescue ex : Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  end

  # Choisit un provider (parmi ceux IMPLÉMENTÉS dans beryl, pas
  # seulement ceux dont les credentials sont déjà dispos — la config
  # se fait à l'étape suivante).
  private def self.pick_provider(flag : String?, non_interactive : Bool) : Beryl::Provider?
    implemented = Beryl::Providers.all

    if flag
      p = Beryl::Providers.find(flag)
      unless p
        STDERR.puts "beryl : provider inconnu : #{flag}. Disponibles : #{implemented.map(&.name).join(", ")}"
        return nil
      end
      STDERR.puts "[beryl init] Provider : #{p.display_name}"
      return p
    end

    case implemented.size
    when 0
      STDERR.puts "beryl : aucun provider n'est enregistré dans ce build"
      nil
    when 1
      p = implemented.first
      STDERR.puts "[beryl init] Provider (unique disponible) : #{p.display_name}"
      p
    else
      if non_interactive
        STDERR.puts "beryl : plusieurs providers disponibles (#{implemented.map(&.name).join(", ")}), passez `beryl init <provider>`"
        return nil
      end
      STDERR.puts "[beryl init] Hébergeurs supportés :"
      implemented.each_with_index do |p, i|
        status = p.available? ? "[credentials détectés dans le shell]" : "[à configurer]"
        STDERR.puts "  #{i + 1}. #{p.display_name.ljust(30)} (#{p.name.ljust(10)}) #{status}"
      end
      ans = ask("Lequel utiliser ? [1] : ", "1")
      idx = (ans.to_i? || 1).clamp(1, implemented.size) - 1
      implemented[idx]
    end
  end

  # Garantit que `.env.yml[<zone>]` contient toutes les variables
  # requises par le provider. Règle simple : « soit on les trouve,
  # soit on les demande » — et dans tous les cas, on persiste dans
  # `.env.yml[<zone>]` (les credentials doivent survivre à la
  # fermeture du shell).
  #
  # Ordre de recherche par variable :
  #   1. Déjà dans `.env.yml[<zone>]` → valeur conservée
  #   2. Exportée dans le shell (ENV)  → récupérée, persistée
  #   3. Sinon (mode interactif)       → prompt, persisté
  #   4. Sinon (mode non-interactif)   → erreur explicite
  private def self.ensure_credentials_for(
    provider : Beryl::Provider,
    zone : String,
    env_file : Beryl::Config::EnvFile,
    env_path : String,
    non_interactive : Bool,
    regen_credentials : Bool = false,
    dry_run : Bool = false,
  ) : Bool
    # NOTE : variable `zone` ici représente temporairement la société
    # dans .env.yml (refactor en cours ; le flux init sera remplacé au
    # commit 4 par `beryl init <société>` + add-provider + add-domain).
    required = provider.credentials_env_vars.reject(&.optional)
    current = env_file.for_account_provider(zone, provider.name).dup
    picked_up_from_shell = [] of String
    prompted = [] of String
    kept_from_file = [] of String

    provider.credentials_env_vars.each do |var|
      # 1. Déjà dans le fichier → on garde. On note que la var est
      # retenue pour en afficher un récap clair à la fin (important
      # quand on lance --regen-credentials : l'utilisateur voit que
      # ses APP_KEY/SECRET ne sont pas re-saisis, juste réutilisés).
      if current.has_key?(var.name) && !current[var.name].empty?
        kept_from_file << var.name
        next
      end

      # 2. Exporté dans le shell → on prend
      if (shell_val = ENV[var.name]?) && !shell_val.empty?
        current[var.name] = shell_val
        picked_up_from_shell << var.name
        next
      end

      # 3. Défaut → si la var est optionnelle et a une valeur par
      # défaut, on l'utilise sans déranger l'utilisateur
      if var.optional && (d = var.default) && !d.empty?
        current[var.name] = d
        next
      end

      # 4. Ni fichier, ni shell, ni défaut → prompt si interactif,
      # sinon on laisse manquante (on lèvera plus bas)
      next if non_interactive

      # Intro une seule fois, la première fois qu'on prompt. On affiche
      # l'URL d'aide + éventuels détails du provider (permissions IAM
      # Scaleway, routes OVH à autoriser). C'est l'utilisateur qui
      # ouvre l'URL dans le navigateur de son choix — beryl n'ouvre
      # rien automatiquement (règle Aloli : l'ouverture d'applications
      # est une prérogative de l'utilisateur, sauf contre-ordre).
      if prompted.empty? && picked_up_from_shell.empty?
        STDERR.puts "[beryl init] Configuration #{provider.display_name} pour `#{zone}`"
        STDERR.puts "             Aide : #{provider.credentials_help_url}"
        if details = provider.credentials_help_details
          details.each_line { |line| STDERR.puts "             #{line}" }
        end
      end
      prompt = "  #{var.name}"
      prompt += " (optionnel)" if var.optional
      prompt += " : "
      input = ask_optional(prompt)
      next if input.empty? && var.optional
      current[var.name] = input unless input.empty?
      prompted << var.name
    end

    # Log les vars réutilisées depuis le fichier (avec valeurs
    # masquées pour les secrets) AVANT d'appeler le hook : si le hook
    # attend une validation navigateur (cas OVH /auth/credential),
    # l'utilisateur voit d'abord CE qui sera utilisé comme base, puis
    # l'URL à valider. L'ordre chronologique est plus lisible.
    unless kept_from_file.empty?
      STDERR.puts "[beryl init] Variables conservées depuis #{env_path}[#{zone}] :"
      provider.credentials_env_vars.each do |var|
        next unless kept_from_file.includes?(var.name)
        value = current[var.name]
        display = var.secret ? mask_secret(value) : value
        STDERR.puts "               #{var.name} = #{display}"
      end
    end

    # Hook : le provider complète les credentials dérivables (OVH CK
    # via /auth/credential par ex.). No-op pour les providers qui
    # n'en ont pas besoin (Scaleway). Lève si les prérequis manquent.
    begin
      current = provider.bootstrap_credentials_if_needed(
        current,
        force_regen: regen_credentials,
        interactive: !non_interactive,
      )
    rescue ex
      STDERR.puts "beryl : échec de la génération automatique des credentials #{provider.display_name} — #{ex.message}"
      return false
    end

    # Vérifie les requises (après le hook, pour tenir compte des
    # vars que le hook a pu remplir).
    missing = required.map(&.name).reject { |n| current.has_key?(n) && !current[n].empty? }
    unless missing.empty?
      STDERR.puts "beryl : variables requises non fournies pour #{provider.display_name} : #{missing.join(", ")}"
      return false
    end

    # Persiste systématiquement. Log clair sur la provenance.
    env_file.set_account_provider(zone, provider.name, current)
    source_bits = [] of String
    source_bits << "#{kept_from_file.size} conservées" unless kept_from_file.empty?
    source_bits << "#{picked_up_from_shell.size} depuis le shell" unless picked_up_from_shell.empty?
    source_bits << "#{prompted.size} saisies" unless prompted.empty?
    if dry_run
      if source_bits.empty?
        STDERR.puts "DRY-RUN : credentials déjà présents dans #{env_path}[#{zone}][#{provider.name}]"
      else
        STDERR.puts "DRY-RUN : #{env_path}[#{zone}][#{provider.name}] recevrait #{current.size} variable(s) (#{source_bits.join(", ")})"
      end
      env_file.apply_to_env(zone, provider.name, overwrite: true)
    else
      env_file.save
      if source_bits.empty?
        STDERR.puts "[beryl init] Credentials déjà présents dans #{env_path}[#{zone}][#{provider.name}]"
      else
        STDERR.puts "[beryl init] Credentials écrits dans #{env_path}[#{zone}][#{provider.name}] (#{source_bits.join(", ")})"
      end
      env_file.apply_to_env(zone, provider.name, overwrite: true)
    end

    unless provider.available?
      STDERR.puts "beryl : credentials posés mais #{provider.display_name} se déclare indisponible (vérifiez #{env_path})"
      return false
    end
    true
  end

  # Sélection automatique de la clé SSH chez le provider + matching
  # avec ~/.ssh/*.pub local via empreinte crypto.
  private def self.select_ssh_key(
    provider : Beryl::Provider,
    ssh_key_name_flag : String?,
    admin_key_flag : String?,
    non_interactive : Bool,
  ) : NamedTuple(provider_key_id: String, admin_key_content: String)?
    begin
      remote_keys = provider.list_ssh_keys
    rescue ex
      STDERR.puts "beryl : impossible de lister les clés SSH chez #{provider.display_name} : #{ex.message}"
      return nil
    end

    local_pubs = list_local_pub_files

    matches = remote_keys.map do |rk|
      local = local_pubs.find do |f|
        begin
          c = File.read_lines(f).first? || ""
          Beryl::SshKeyInfo.new("", "", c).crypto_fingerprint == rk.crypto_fingerprint
        rescue
          false
        end
      end
      {remote: rk, local: local}
    end

    chosen = if ssh_key_name_flag
               matches.find { |m| m[:remote].id == ssh_key_name_flag || m[:remote].name == ssh_key_name_flag } ||
                 raise "clé #{ssh_key_name_flag} introuvable côté #{provider.display_name}"
             else
               auto = matches.select { |m| !m[:local].nil? }
               case auto.size
               when 1
                 STDERR.puts "[beryl init] Clé #{provider.name} : #{auto.first[:remote].name} ↔ #{auto.first[:local]}"
                 auto.first
               when 0
                 raise Aborted.new if non_interactive
                 STDERR.puts "[beryl init] Aucun ~/.ssh/*.pub ne correspond. Clés #{provider.display_name} :"
                 remote_keys.each_with_index { |k, i| STDERR.puts "  #{i + 1}. #{k.name}" }
                 ans = ask("Laquelle utiliser ? [1] : ", "1")
                 idx = (ans.to_i? || 1).clamp(1, remote_keys.size) - 1
                 {remote: remote_keys[idx], local: nil.as(String?)}
               else
                 raise Aborted.new if non_interactive
                 STDERR.puts "[beryl init] Plusieurs correspondances :"
                 auto.each_with_index { |m, i| STDERR.puts "  #{i + 1}. #{m[:remote].name} ↔ #{File.basename(m[:local].not_nil!)}" }
                 ans = ask("Laquelle utiliser ? [1] : ", "1")
                 idx = (ans.to_i? || 1).clamp(1, auto.size) - 1
                 auto[idx]
               end
             end

    # On écrit le NOM DE FICHIER dans le YAML (ex: philippe.aloli.fr.pub)
    # plutôt que le contenu. beryl résout à la lecture depuis ~/.ssh/.
    # Unique source de vérité = le fichier .pub local ; rotation facile.
    # Si la clé n'est pas dans ~/.ssh, on retombe sur le contenu inline
    # (cas edge : clé venue d'un flag --admin-key pointant ailleurs).
    admin_key_ref = if admin_key_flag
                      # Flag explicite : on prend le basename si c'est
                      # dans ~/.ssh, sinon on inline le contenu.
                      ssh_dir = File.expand_path("~/.ssh", home: true)
                      if admin_key_flag.starts_with?(ssh_dir + "/") || admin_key_flag.starts_with?(ssh_dir + File::SEPARATOR)
                        File.basename(admin_key_flag)
                      else
                        File.read_lines(admin_key_flag).map(&.strip).reject(&.empty?).first? || ""
                      end
                    elsif local = chosen[:local]
                      File.basename(local) # nom de fichier, pas le contenu
                    else
                      chosen[:remote].public_key # inline (pas de .pub local matché)
                    end

    {provider_key_id: chosen[:remote].id, admin_key_content: admin_key_ref}
  end

  private def self.list_local_pub_files : Array(String)
    ssh_dir = File.expand_path("~/.ssh", home: true)
    return [] of String unless File.directory?(ssh_dir)
    Dir.children(ssh_dir).select(&.ends_with?(".pub")).sort.map { |f| File.join(ssh_dir, f) }
  end

  # Socle FreeBSD standard (admin + deploy avec shells appropriés,
  # sans clés SSH : elles viennent du domaine via ssh_keys: + Merger).
  private def self.default_yaml_content : String
    <<-YAML
    # ─────────────────────────────────────────────────────────────────
    # Socle technique FreeBSD — commun à TOUS les domaines.
    # ─────────────────────────────────────────────────────────────────
    # Héritage : ce fichier est mergé EN PREMIER, puis
    # `<domaine>.yml`, puis éventuellement `<groupe>.yml`, puis le
    # fichier du host. Le niveau le plus spécifique gagne.
    #
    # Ce fichier ne déclare PAS de pool ZFS : les pools (disques +
    # RAID + mountpoint) sont spécifiques à chaque host, sous
    # `freebsd.zfs.<nom>:` dans le fichier host. Exemple minimal :
    #
    #   freebsd:
    #     zfs:
    #       zroot:
    #         boot: true     # exactement un pool avec boot: true
    #         raid: 0        # 0=stripe 1=mirror 5=raidz 6=raidz2 7=raidz3 10=mirror_stripe
    #         disks: [/dev/sda]
    #
    # Les clés SSH ne sont PAS ici : elles sont déclarées dans chaque
    # `<domaine>.yml` via le champ `ssh_keys:` et injectées
    # automatiquement dans chaque user par le merge (la clé domaine
    # est obligatoire, présente dans tous les `authorized_keys`).

    freebsd:
      # Fuseau horaire du système. Format IANA (`tzdata`). Remplacé
      # au bootstrap par un `cp /usr/share/zoneinfo/<tz> /etc/localtime`.
      # Exemples : Europe/Paris, Europe/London, America/New_York, UTC.
      timezone: Europe/Paris

      # Taille du swap en gigaoctets. Partition `gpt/swap0` créée par
      # bsdinstall sur le premier disque du pool boot, activée via
      # /etc/fstab. Valeurs usuelles : 2 à 16.
      swap_gb: 4

      # Chemin d'installation FreeBSD :
      #   distribution_sets : tarballs base.txz + kernel.txz (stable,
      #                       chemin testé par Aloli, voir ADR-013)
      #   packages          : pkgbase (opt-in, non câblé runtime pour
      #                       l'instant — lève `PkgbaseNotYetImplemented`
      #                       à l'install jusqu'à nouvel ordre)
      install_type: distribution_sets

      # Packages installés au bootstrap via `pkg -r /mnt install` hors
      # chroot (contournement Capsicum, ADR-013). Cette liste est
      # APPENDÉE par les niveaux suivants : un groupe d'usage peut
      # ajouter `nginx, postgresql16-server`, etc. Les doublons sont
      # éliminés automatiquement.
      packages:
        - sudo
        - zsh
        - curl
        - git

      # Règles sudoers écrites dans /usr/local/etc/sudoers.d/beryl.
      # Même logique d'append que les packages : un groupe peut
      # ajouter des règles métier (ex: `deploy ALL=(www) NOPASSWD:...`).
      sudoers:
        - '%wheel ALL=(ALL) NOPASSWD:ALL'

      # Users créés au bootstrap. SANS `ssh_keys:` ici — les clés
      # viennent :
      #   1. du champ `ssh_keys:` du domaine (obligatoire, injecté
      #      dans chaque user ici)
      #   2. plus, optionnellement, des clés listées sous `users:`
      #      dans un <groupe>.yml ou un <host>.yml pour un user donné
      #
      # Règle de merge pour `users` : merge par `name`. Un groupe/host
      # peut raffiner un user existant (ajouter des clés, changer le
      # shell) sans devoir redéclarer toutes ses propriétés.
      #
      # shells typiques :
      #   /usr/local/bin/zsh   (admin, installé via le package `zsh`)
      #   /bin/csh             (tcsh-compatible, défaut FreeBSD)
      #   /bin/sh              (POSIX minimal, pour users automatisés)
      users:
        # admin : compte interactif principal. Membre de `wheel` →
        # éligible à sudo (voir la règle sudoers ci-dessus).
        - name: admin
          primary_group: www
          secondary_groups: [wheel]
          shell: /usr/local/bin/zsh

        # deploy : compte utilisé par CI/CD. Pas de wheel : pas de
        # sudo, pas d'escalade possible. Shell minimal (pas de zsh).
        - name: deploy
          primary_group: www
          secondary_groups: []
          shell: /bin/csh
    YAML
  end

  # Contenu d'un `<domaine>.yml`. Porte l'identité : clé du domaine
  # (ssh_keys:) et clé SSH chez le provider (<provider>.ssh_key_name).
  private def self.render_domain_yaml(provider : Beryl::Provider, key_id : String, admin_key : String) : String
    String.build do |io|
      io << "# Identité du domaine — provider par défaut + clé SSH côté " << provider.display_name
      io << "\n# (injectée au rescue par l'API) + clé(s) SSH des users (posées\n"
      io << "# dans ~<user>/.ssh/authorized_keys par beryl bootstrap + apply).\n"
      io << "#\n"
      io << "# `provider:` est obligatoire ici : il permet à beryl d'opérer\n"
      io << "# sur un serveur pas encore déclaré dans un fichier host dédié\n"
      io << "# (cas typique : `beryl rescue <nom_hébergeur> --domain=<domaine>`)\n"
      io << "# où le merge est juste _default.yml + <domaine>.yml.\n"
      io << "#\n"
      io << "# Ajoutez d'autres blocs providers (`scaleway:`, `hetzner:`…) en\n"
      io << "# plus de `" << provider.name << ":` si ce domaine héberge du multi-cloud.\n"
      io << "# Pour surcharger ce défaut sur un host ou une commande :\n"
      io << "#   - dans le YAML host :       `provider: scaleway`\n"
      io << "#   - en CLI (rescue/bootstrap/scan/boot-hd) : `--provider=scaleway`\n\n"
      io << "provider: " << provider.name << "\n\n"
      io << provider.name << ":\n"
      fragment = provider.ssh_key_yaml_fragment(key_id)
      fragment.each do |k, v|
        case v
        when String
          io << "  " << k << ": " << v << '\n'
        when Array(String)
          io << "  " << k << ":\n"
          v.each { |it| io << "    - " << it << '\n' }
        end
      end
      io << "\nssh_keys:\n"
      if admin_key.empty?
        io << "  # TODO : ajoutez au moins une clé SSH publique ici\n"
        io << "  # - ssh-ed25519 AAAA... votre@email\n"
      else
        io << "  - " << admin_key << '\n'
      end
    end
  end

  private def self.ask(prompt : String, default : String) : String
    STDERR.print prompt
    STDERR.flush
    line = STDIN.gets
    raise Aborted.new if line.nil?
    a = line.chomp.strip
    a.empty? ? default : a
  end

  private def self.ask_optional(prompt : String) : String
    STDERR.print prompt
    STDERR.flush
    line = STDIN.gets || return ""
    line.chomp.strip
  end

  # Masque un secret pour l'affichage : garde les 4 premiers et 4
  # derniers caractères si la valeur est assez longue, masque entre
  # les deux. Retourne `***` si trop court. Permet à l'utilisateur
  # de reconnaître un secret sans le divulguer dans les logs.
  private def self.mask_secret(value : String) : String
    return "***" if value.size < 12
    "#{value[0, 4]}#{"*" * (value.size - 8)}#{value[-4, 4]}"
  end
end
