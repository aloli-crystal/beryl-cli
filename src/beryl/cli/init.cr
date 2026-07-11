require "option_parser"
require "file_utils"
require "../config"
require "../providers"
require "./account_utils"
require "./add_provider"
require "./add_domain"
require "./config_git"

# Sous-commande `beryl init [<société>]` (refondue ADR-014) :
# initialise l'arborescence `~/.config/beryl/` avec une société.
#
# Crée :
#   - `~/.config/beryl/_default.yml` (socle FreeBSD) si absent
#   - `~/.config/beryl/<société>/` (dossier société)
#   - `~/.config/beryl/<société>/_account.yml` (optionnel, métadonnées)
#
# Puis propose d'enchaîner sur `beryl add-provider` et `beryl add-domain`
# pour configurer les fournisseurs (hébergeur des serveurs et/ou
# gestionnaire DNS — chez la plupart des hébergeurs c'est OVH pour les deux) et les
# domaines.
#
# Usage :
#
#   beryl init acme
#   beryl init          # demande interactivement
module Beryl::CLI::Init
  EXIT_OK      = 0
  EXIT_USAGE   = 1
  EXIT_ABORTED = 2

  def self.run(config_root : String, args : Array(String)) : Int32
    force = false
    non_interactive = false
    dry_run = true
    no_commit = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl init [<société>] [options]\n\n" \
                 "Crée l'arborescence ~/.config/beryl/<société>/ et propose\n" \
                 "d'ajouter ses fournisseurs (hébergeur de serveurs et/ou\n" \
                 "gestionnaire DNS — chez la plupart des hébergeurs c'est OVH pour les deux) et\n" \
                 "ses domaines.\n\n" \
                 "Enchaînements possibles :\n" \
                 "  beryl add-provider <société>/<provider>\n" \
                 "  beryl add-domain   <société>/<domaine>"
      p.on("--apply", "Applique réellement les changements (sinon : dry-run, prévisualise sans rien modifier)") { dry_run = false }
      p.on("-f", "--force", "Écrase _account.yml si existant") { force = true }
      p.on("-N", "--non-interactive", "Refuse tout prompt") { non_interactive = true }
      p.on("--no-commit", "N'auto-commite pas _account.yml dans le dépôt git de config") { no_commit = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    Dir.mkdir_p(config_root) unless dry_run

    # Étape 1 : nom de la société (argument ou prompt)
    account = positional.first?
    if (account.nil? || account.empty?) && non_interactive
      STDERR.puts "beryl : argument société requis en --non-interactive. USAGE : beryl init <société>"
      return EXIT_USAGE
    end
    account ||= Beryl::CLI::AccountUtils.ask("Nom court de la société (ex: acme) :", "")
    return EXIT_USAGE if account.empty?

    # Validation basique du nom (dossier filesystem)
    unless account =~ /\A[a-z0-9][a-z0-9_-]*\z/
      STDERR.puts "beryl : nom de société invalide : `#{account}`. Utilisez [a-z0-9_-]."
      return EXIT_USAGE
    end

    account_dir = File.join(config_root, account)

    if dry_run
      STDERR.puts
      STDERR.puts "DRY-RUN : actions `beryl init #{account}` prévues :"
      STDERR.puts "  - Création du dossier : #{account_dir}"
      defaults_path = File.join(config_root, "_default.yml")
      if File.exists?(defaults_path)
        STDERR.puts "  - #{defaults_path} existe déjà, pas écrasé"
      else
        STDERR.puts "  - Écriture socle : #{defaults_path} (#{default_yaml_content.bytesize} octets)"
      end
      account_meta_path = File.join(account_dir, "_account.yml")
      if File.exists?(account_meta_path) && !force
        STDERR.puts "  - #{account_meta_path} existe déjà, pas écrasé (utilisez --force)"
      else
        STDERR.puts "  - Écriture métadonnées : #{account_meta_path}"
      end
      STDERR.puts "  - Proposition de chaîner add-provider / add-domain (interactif seulement)"
      STDERR.puts
      STDERR.puts "DRY-RUN : aucune action exécutée."
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("init", args)}"
      return EXIT_OK
    end

    Dir.mkdir_p(account_dir)
    STDERR.puts
    STDERR.puts "[beryl init] 1 Dossier créé : #{account_dir}"

    # Étape 2 : socle _default.yml si absent
    defaults_path = File.join(config_root, "_default.yml")
    unless File.exists?(defaults_path)
      File.write(defaults_path, default_yaml_content)
      STDERR.puts
      STDERR.puts "[beryl init] 1 _default.yml créé (socle FreeBSD)."
    end

    # Étape 3 : _account.yml (métadonnées optionnelles)
    account_meta_path = File.join(account_dir, "_account.yml")
    if !File.exists?(account_meta_path) || force
      STDERR.puts
      write_account_metadata(account_meta_path, account, non_interactive)
      # Auto-commit si le dossier société est déjà un dépôt git (sinon
      # skip silencieux : l'opérateur fera `git init` quand il voudra).
      Beryl::CLI::ConfigGit.commit(
        [account_meta_path],
        "init : société #{account}",
        no_commit,
      )
    end

    STDERR.puts
    STDERR.puts "Société `#{account}` initialisée dans #{account_dir}."
    STDERR.puts

    # Étape 4 : chaîne vers add-provider si l'utilisateur veut
    unless non_interactive
      if Beryl::CLI::AccountUtils.ask_yes_no("Ajouter un fournisseur (serveurs et/ou DNS) maintenant ?", default_yes: true)
        return chain_add_providers(config_root, account)
      end
    end

    STDERR.puts "Prochaines étapes :"
    STDERR.puts "  beryl add-provider #{account}/<provider>   # serveurs et/ou DNS : ovh, scaleway, dedibox, …"
    STDERR.puts "  beryl add-domain   #{account}/<domaine>    # example.net, …"
    EXIT_OK
  rescue ex : Beryl::CLI::AccountUtils::Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  end

  # Boucle `add-provider` tant que l'utilisateur en ajoute. Puis propose
  # `add-domain` en boucle aussi.
  private def self.chain_add_providers(config_root : String, account : String) : Int32
    loop do
      STDERR.puts
      implemented = Beryl::CLI::AccountUtils.implemented_providers
      already = Beryl::CLI::AccountUtils.providers_of(config_root, account)
      remaining = implemented.reject { |p| already.includes?(p.name) }

      if remaining.empty?
        STDERR.puts "[beryl init] 1 Tous les fournisseurs disponibles sont déjà configurés pour `#{account}`."
        break
      end

      STDERR.puts "[beryl init] 1 Fournisseurs disponibles pour `#{account}` (que fournit chacun) :"
      remaining.each_with_index do |p, i|
        STDERR.puts "  #{i + 1}. #{p.name.ljust(12)} #{p.display_name.ljust(25)}  → #{capabilities_label(p.capabilities)}"
      end

      ans = Beryl::CLI::AccountUtils.ask("Lequel ajouter ? (nom, ou Entrée pour passer) :", "")
      break if ans.empty?

      provider_name = if idx = ans.to_i?
                        remaining[(idx - 1).clamp(0, remaining.size - 1)].name
                      else
                        ans
                      end

      STDERR.puts
      exit_code = Beryl::CLI::AddProvider.run(config_root, [provider_name, "--account=#{account}"])
      return exit_code unless exit_code == EXIT_OK

      STDERR.puts
      break unless Beryl::CLI::AccountUtils.ask_yes_no("Ajouter un autre fournisseur ?", default_yes: false)
    end

    # Puis proposer add-domain
    loop do
      STDERR.puts
      break unless Beryl::CLI::AccountUtils.ask_yes_no("Ajouter un domaine maintenant ?", default_yes: true)
      domain = Beryl::CLI::AccountUtils.ask("Nom du domaine (ex: example.net) :", "")
      next if domain.empty?
      STDERR.puts
      exit_code = Beryl::CLI::AddDomain.run(config_root, [domain, "--account=#{account}"])
      return exit_code unless exit_code == EXIT_OK
    end

    STDERR.puts
    STDERR.puts "[beryl init] 1 Configuration initiale de `#{account}` terminée."
    EXIT_OK
  end

  # Traduit la liste de capabilities en libellé français lisible pour
  # l'utilisateur final. Évite le jargon `compute, dns` qui ne lève
  # pas l'ambiguïté « fournisseur de quoi ? » côté opérateur.
  #
  #   [:compute, :dns] → "serveurs + DNS"
  #   [:compute]       → "serveurs uniquement"
  #   [:dns]           → "DNS uniquement"
  private def self.capabilities_label(caps : Array(Symbol)) : String
    parts = [] of String
    parts << "serveurs" if caps.includes?(:compute)
    parts << "DNS" if caps.includes?(:dns)
    case parts.size
    when 0 then "—"
    when 1 then "#{parts.first} uniquement"
    else        parts.join(" + ")
    end
  end

  # Crée `_account.yml` avec un champ `name:` saisi par l'utilisateur
  # (ou égal au slug de société en non-interactif).
  private def self.write_account_metadata(path : String, account : String, non_interactive : Bool) : Nil
    display_name = if non_interactive
                     account
                   else
                     Beryl::CLI::AccountUtils.ask(
                       "Nom complet de la société (optionnel, ex: ACME SAS) :", account,
                     )
                   end
    content = String.build do |io|
      io << "# Métadonnées de la société `#{account}` — optionnel.\n"
      io << "# Beryl lit `name:` pour l'affichage ; le reste est en commentaire\n"
      io << "# libre (contact, facturation, notes).\n\n"
      io << "name: " << display_name << '\n'
    end
    File.write(path, content)
    STDERR.puts "[beryl init] 1 _account.yml créé dans #{File.basename(File.dirname(path))}/."
  end

  # Socle FreeBSD standard (admin + deploy avec shells appropriés,
  # sans clés SSH : elles viennent du domaine via ssh_keys: + Merger).
  private def self.default_yaml_content : String
    <<-YAML
    # ─────────────────────────────────────────────────────────────────
    # Socle technique commun à TOUTES les sociétés (ADR-014).
    # ─────────────────────────────────────────────────────────────────
    # Hiérarchie de merge :
    #   1. _default.yml (ce fichier)
    #   2. <société>/<domaine>.yml
    #   3. <société>/<domaine>/<groupe>.yml (optionnel)
    #   4. <société>/<domaine>/<host>.yml OU
    #      <société>/<domaine>/<groupe>/<host>.yml
    # Le niveau le plus spécifique gagne.
    #
    # Les pools ZFS ne sont PAS ici : spécifiques à chaque host, sous
    # `freebsd.zfs.<nom>:`. Exemple minimal :
    #
    #   freebsd:
    #     zfs:
    #       zroot:
    #         boot: true     # exactement un pool avec boot: true
    #         raid: 0        # 0=stripe 1=mirror 5=raidz 6=raidz2 7=raidz3 10=mirror_stripe
    #         disks: [/dev/sda]
    #
    # Les clés SSH utilisateurs sont au niveau `<société>/<domaine>.yml`
    # dans `ssh_keys:` (chaque domaine peut avoir ses clés, injectées
    # dans tous les `authorized_keys` via le merger).

    # OS cible par défaut. Aujourd'hui seul `freebsd` est câblé côté
    # runtime ; `debian`, `ubuntu`, `alpine` arriveront plus tard.
    os: freebsd

    freebsd:
      # Fuseau horaire. Format IANA. Exemples : Europe/Paris, UTC.
      timezone: Europe/Paris

      # Taille du swap en Go. Partition `gpt/swap0` sur le premier
      # disque du pool boot.
      swap_gb: 4

      # Chemin d'installation :
      #   distribution_sets : tarballs base.txz + kernel.txz (stable, ADR-013)
      #   packages          : pkgbase (opt-in, non câblé runtime)
      install_type: distribution_sets

      # Packages installés au bootstrap via `pkg -r /mnt install` hors
      # chroot (ADR-013). Append + dédup par les niveaux suivants.
      packages:
        - sudo
        - zsh
        - curl
        - git

      # Règles sudoers → /usr/local/etc/sudoers.d/beryl.
      sudoers:
        - '%wheel ALL=(ALL) NOPASSWD:ALL'

      # Users créés au bootstrap. Merge par `name` : un groupe/host
      # peut raffiner un user existant.
      users:
        - name: admin
          primary_group: www
          secondary_groups: [wheel]
          shell: /usr/local/bin/zsh

        - name: deploy
          primary_group: www
          secondary_groups: []
          shell: /bin/csh
    YAML
  end
end
