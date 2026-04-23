require "option_parser"
require "file_utils"
require "../config"
require "../providers"
require "./account_utils"
require "./add_provider"
require "./add_domain"

# Sous-commande `beryl init [<société>]` (refondue ADR-014) :
# initialise l'arborescence `~/.beryl/` avec une société.
#
# Crée :
#   - `~/.beryl/_default.yml` (socle FreeBSD) si absent
#   - `~/.beryl/<société>/` (dossier société)
#   - `~/.beryl/<société>/_account.yml` (optionnel, métadonnées)
#
# Puis propose d'enchaîner sur `beryl add-provider` et `beryl add-domain`
# pour configurer fournisseurs et domaines.
#
# Usage :
#
#   beryl init aloli
#   beryl init          # demande interactivement
module Beryl::CLI::Init
  EXIT_OK      = 0
  EXIT_USAGE   = 1
  EXIT_ABORTED = 2

  def self.run(config_root : String, args : Array(String)) : Int32
    force = false
    non_interactive = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl init [<société>] [options]\n\n" \
                 "Crée l'arborescence ~/.beryl/<société>/ et propose d'ajouter\n" \
                 "fournisseurs et domaines.\n\n" \
                 "Enchaînements possibles :\n" \
                 "  beryl add-provider <société>/<provider>\n" \
                 "  beryl add-domain   <société>/<domaine>"
      p.on("-f", "--force", "Écrase _account.yml si existant") { force = true }
      p.on("-N", "--non-interactive", "Refuse tout prompt") { non_interactive = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    Dir.mkdir_p(config_root)

    # Étape 1 : nom de la société (argument ou prompt)
    account = positional.first?
    if (account.nil? || account.empty?) && non_interactive
      STDERR.puts "beryl : argument société requis en --non-interactive. USAGE : beryl init <société>"
      return EXIT_USAGE
    end
    account ||= Beryl::CLI::AccountUtils.ask("Nom court de la société (ex: aloli) :", "")
    return EXIT_USAGE if account.empty?

    # Validation basique du nom (dossier filesystem)
    unless account =~ /\A[a-z0-9][a-z0-9_-]*\z/
      STDERR.puts "beryl : nom de société invalide : `#{account}`. Utilisez [a-z0-9_-]."
      return EXIT_USAGE
    end

    account_dir = File.join(config_root, account)
    Dir.mkdir_p(account_dir)
    STDERR.puts "[beryl init] Dossier créé : #{account_dir}"

    # Étape 2 : socle _default.yml si absent
    defaults_path = File.join(config_root, "_default.yml")
    unless File.exists?(defaults_path)
      File.write(defaults_path, default_yaml_content)
      STDERR.puts "[beryl init] _default.yml créé (socle FreeBSD)."
    end

    # Étape 3 : _account.yml (métadonnées optionnelles)
    account_meta_path = File.join(account_dir, "_account.yml")
    if !File.exists?(account_meta_path) || force
      write_account_metadata(account_meta_path, account, non_interactive)
    end

    STDERR.puts
    STDERR.puts "Société `#{account}` initialisée dans #{account_dir}."
    STDERR.puts

    # Étape 4 : chaîne vers add-provider si l'utilisateur veut
    unless non_interactive
      if Beryl::CLI::AccountUtils.ask_yes_no("Ajouter un fournisseur maintenant ?", default_yes: true)
        return chain_add_providers(config_root, account)
      end
    end

    STDERR.puts "Prochaines étapes :"
    STDERR.puts "  beryl add-provider #{account}/<provider>   # ovh, scaleway, …"
    STDERR.puts "  beryl add-domain   #{account}/<domaine>    # aloli.net, …"
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
        STDERR.puts "[beryl init] Tous les fournisseurs disponibles sont déjà configurés pour `#{account}`."
        break
      end

      STDERR.puts "[beryl init] Fournisseurs disponibles pour `#{account}` :"
      remaining.each_with_index do |p, i|
        STDERR.puts "  #{i + 1}. #{p.name.ljust(12)} (#{p.display_name}) — capabilities : #{p.capabilities.map(&.to_s).sort.join(", ")}"
      end

      ans = Beryl::CLI::AccountUtils.ask("Lequel ajouter ? (nom, ou Entrée pour passer) :", "")
      break if ans.empty?

      provider_name = if idx = ans.to_i?
                        remaining[(idx - 1).clamp(0, remaining.size - 1)].name
                      else
                        ans
                      end

      exit_code = Beryl::CLI::AddProvider.run(config_root, [provider_name, "--account=#{account}"])
      return exit_code unless exit_code == EXIT_OK

      break unless Beryl::CLI::AccountUtils.ask_yes_no("Ajouter un autre fournisseur ?", default_yes: false)
    end

    # Puis proposer add-domain
    loop do
      STDERR.puts
      break unless Beryl::CLI::AccountUtils.ask_yes_no("Ajouter un domaine maintenant ?", default_yes: true)
      domain = Beryl::CLI::AccountUtils.ask("Nom du domaine (ex: aloli.net) :", "")
      next if domain.empty?
      exit_code = Beryl::CLI::AddDomain.run(config_root, [domain, "--account=#{account}"])
      return exit_code unless exit_code == EXIT_OK
    end

    STDERR.puts
    STDERR.puts "[beryl init] Configuration initiale de `#{account}` terminée."
    EXIT_OK
  end

  # Crée `_account.yml` avec un champ `name:` saisi par l'utilisateur
  # (ou égal au slug de société en non-interactif).
  private def self.write_account_metadata(path : String, account : String, non_interactive : Bool) : Nil
    display_name = if non_interactive
                     account
                   else
                     Beryl::CLI::AccountUtils.ask(
                       "Nom complet de la société (optionnel, ex: ALOLI SAS) :", account,
                     )
                   end
    content = String.build do |io|
      io << "# Métadonnées de la société `#{account}` — optionnel.\n"
      io << "# Beryl lit `name:` pour l'affichage ; le reste est en commentaire\n"
      io << "# libre (contact, facturation, notes).\n\n"
      io << "name: " << display_name << '\n'
    end
    File.write(path, content)
    STDERR.puts "[beryl init] _account.yml créé dans #{File.basename(File.dirname(path))}/."
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
