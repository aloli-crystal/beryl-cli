require "option_parser"
require "file_utils"

# Sous-commande `beryl init` : crée l'arborescence standard d'un
# inventaire beryl dans `~/.beryl/`, avec des squelettes de groupes
# qui reflètent les règles Aloli (zone DNS partagée, user admin
# standard, pas de défaut silencieux).
#
# Usage :
#
#   beryl init
#   beryl init --zone=aloli.net --ssh-key-name=philippe.aloli.fr --admin-key=~/.ssh/philippe.pub
#   beryl init --force           # écrase un ~/.beryl/ existant
#   beryl init --dir=./.beryl    # local au projet au lieu de global
#   beryl init --dir=/autre/chemin
#
# Après `beryl init`, toutes les sous-commandes résolvent leur inventaire
# automatiquement depuis `~/.beryl/`. `beryl -i AUTRE` reste possible
# pour pointer ailleurs.
module Beryl::CLI::Init
  EXIT_OK         = 0
  EXIT_USAGE      = 1
  EXIT_ABORTED    = 2
  EXIT_ALREADY    = 3
  EXIT_UNEXPECTED = 4

  # Dossier cible : ~/.beryl/ directement, pas de sous-dossier
  # `inventory/` (convention .gitconfig : le nom de l'outil = le nom
  # du dossier de conf, avec un point devant).
  DEFAULT_DIR = File.expand_path("~/.beryl", home: true)

  def self.run(args : Array(String)) : Int32
    zone : String? = nil
    ssh_key_name : String? = nil
    admin_key_file : String? = nil
    dir : String = DEFAULT_DIR
    force = false
    non_interactive = false

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl init [options]\n\n" \
                 "Crée l'arborescence d'un inventaire beryl dans #{DEFAULT_DIR}\n" \
                 "avec des squelettes de groupes (zone DNS, admin standard)."
      p.on("--zone=NAME", "Zone DNS (ex: aloli.net). Sera un groupe `<zone>` (points → tirets).") { |v| zone = v }
      p.on("--ssh-key-name=NAME", "Nom de la clé SSH OVH pour la zone (ex: philippe.aloli.fr)") { |v| ssh_key_name = v }
      p.on("--admin-key=FILE", "Fichier .pub de la clé admin standard (ex: ~/.ssh/id_ed25519.pub)") { |v| admin_key_file = File.expand_path(v, home: true) }
      p.on("--dir=DIR", "Répertoire de l'inventaire (défaut : #{DEFAULT_DIR})") { |v| dir = File.expand_path(v, home: true) }
      p.on("--force", "Écrase un inventaire existant") { force = true }
      p.on("--non-interactive", "Aucune invite. Tous les paramètres doivent être en flags.") { non_interactive = true }
      p.on("-h", "--help", "Aide") do
        puts p
        exit 0
      end
    end
    parser.parse(args)

    # Si le dossier existe déjà avec des YAML dedans, on refuse sauf --force.
    if File.directory?(dir) && !force
      existing = Dir.glob(File.join(dir, "**", "*.yml"))
      unless existing.empty?
        STDERR.puts "beryl : #{dir} contient déjà #{existing.size} fichier(s) YAML."
        STDERR.puts "        Utilisez --force pour écraser, ou --dir pour un autre chemin."
        return EXIT_ALREADY
      end
    end

    STDERR.puts "[beryl init] Trois informations pour amorcer votre inventaire :" if !non_interactive && (zone.nil? || ssh_key_name.nil?)
    z_in = zone
    zv : String = z_in ? z_in : (non_interactive ? raise("--zone requis en --non-interactive") : ask(
      "  1. Zone DNS que vous gérez chez OVH (ex: aloli.net) : ", "",
    ))
    raise Aborted.new if zv.empty?
    k_in = ssh_key_name
    kv : String = k_in ? k_in : (non_interactive ? raise("--ssh-key-name requis en --non-interactive") : ask(
      "  2. Label de votre clé SSH enregistrée dans le panel OVH\n" \
      "     (Compte → Mes clés SSH, colonne « Nom ») : ", "",
    ))
    raise Aborted.new if kv.empty?
    akf : String? = admin_key_file
    if akf.nil? && !non_interactive
      akf = ask_optional(
        "  3. Fichier .pub de votre clé SSH perso (chemin, ou nom simple\n" \
        "     si dans ~/.ssh/, vide = à remplir manuellement plus tard) : "
      )
    end

    # Résolution flexible du chemin :
    #   1. Tel quel (absolu ou relatif au cwd), avec `~` expansé
    #   2. Si ça échoue et que l'entrée n'a pas de '/', on tente ~/.ssh/<nom>
    #   3. Sinon erreur explicite qui liste les chemins essayés
    akf_path = resolve_admin_key_path(akf)

    admin_key_content = if akf_path && !akf_path.empty?
                          lines = File.read_lines(akf_path).map(&.strip).reject { |l| l.empty? || l.starts_with?('#') }
                          lines.first? || ""
                        else
                          if akf && !akf.empty?
                            STDERR.puts "beryl : fichier introuvable : #{akf}"
                            STDERR.puts "        Essayé : ./#{akf}, ~/.ssh/#{akf}"
                            STDERR.puts "        Passez un chemin absolu si la clé est ailleurs."
                            return EXIT_USAGE
                          end
                          ""
                        end

    zone_group_name = zv.gsub('.', '-')

    # Création de la structure.
    FileUtils.mkdir_p(File.join(dir, "groups"))
    FileUtils.mkdir_p(File.join(dir, "hosts"))

    write_file(File.join(dir, "groups", "#{zone_group_name}.yml"),
      render_zone_group(zv, kv))
    write_file(File.join(dir, "groups", "aloli-admin.yml"),
      render_admin_group(admin_key_content))
    write_file(File.join(dir, "groups", "rails-servers.yml"),
      render_rails_group)
    write_file(File.join(dir, "groups", "backup-servers.yml"),
      render_backup_group)
    write_file(File.join(dir, "hosts", "README.adoc"),
      render_hosts_readme(dir))

    STDERR.puts
    STDERR.puts "[beryl init] Inventaire créé dans #{dir}"
    STDERR.puts "            Zone :       #{zv} (groupe : #{zone_group_name})"
    STDERR.puts "            Clé OVH :    #{kv}"
    STDERR.puts "            Clé admin :  #{admin_key_content.empty? ? "(à remplir manuellement)" : "chargée depuis #{akf_path}"}"
    STDERR.puts
    STDERR.puts "Prochaines étapes :"
    STDERR.puts "  1. Relisez groups/*.yml, ajustez packages, users, sudoers."
    STDERR.puts "  2. Pour ajouter un serveur :"
    STDERR.puts "       beryl rescue <service_name_OVH>"
    STDERR.puts "       beryl scan   <service_name_OVH> --dns --write"
    STDERR.puts "  3. beryl (toute commande) trouvera l'inventaire automatiquement."
    EXIT_OK
  rescue ex : Aborted
    STDERR.puts "beryl : abandon."
    EXIT_ABORTED
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  class Aborted < Exception
  end

  # Résout un chemin de fichier .pub saisi par l'utilisateur :
  #
  # - nil / "" → nil (pas de clé admin)
  # - chemin absolu, relatif, ou avec ~ → essayé tel quel
  # - nom simple sans '/' → essayé aussi dans ~/.ssh/<nom>
  #
  # Retourne le chemin résolu qui existe, ou nil si aucun ne marche.
  # Signature publique (defs privés non-self pas pratiques à tester).
  def self.resolve_admin_key_path(input : String?) : String?
    return nil if input.nil? || input.empty?
    expanded = File.expand_path(input, home: true)
    return expanded if File.exists?(expanded)
    unless input.includes?('/')
      in_ssh_dir = File.expand_path("~/.ssh/#{input}", home: true)
      return in_ssh_dir if File.exists?(in_ssh_dir)
    end
    nil
  end

  private def self.write_file(path : String, content : String) : Nil
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Prompt obligatoire : valeur par défaut acceptée si non vide.
  private def self.ask(prompt : String, default : String) : String
    STDERR.print prompt
    STDERR.flush
    line = STDIN.gets || raise Aborted.new
    a = line.chomp.strip
    a.empty? ? default : a
  end

  # Prompt optionnel : peut être laissé vide.
  private def self.ask_optional(prompt : String) : String
    STDERR.print prompt
    STDERR.flush
    line = STDIN.gets || return ""
    line.chomp.strip
  end

  private def self.render_zone_group(zone : String, ssh_key_name : String) : String
    <<-YAML
    # Zone #{zone} — clé SSH OVH partagée par tous les serveurs de la zone.
    #
    # À inclure dans le champ `groups:` de chaque host de cette zone.
    # Règle Aloli : la clé SSH de rescue est déclarée ICI, pas recopiée
    # dans chaque fichier host. Un serveur qui utilise une clé spécifique
    # redéclare `ovh.ssh_key_name` dans son propre fichier (deep merge
    # YAML → l'override host prime).

    ovh:
      ssh_key_name: #{ssh_key_name}
    YAML
  end

  private def self.render_admin_group(admin_key : String) : String
    placeholder_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRemplacezMoi votre@email"
    key_line = admin_key.empty? ? placeholder_key : admin_key
    comment = admin_key.empty? ? "# TODO : remplacez par votre vraie clé SSH publique" : "# Clé importée depuis le fichier .pub fourni à `beryl init`"
    <<-YAML
    # Group aloli-admin — user admin standard pour tous les serveurs.
    #
    # Règles Aloli :
    # - pas de clé SSH sur root (feedback_beryl_no_root_ssh)
    # - admin est dans wheel (sudo NOPASSWD via sudoers ci-dessous)
    # - shell /bin/csh (défaut FreeBSD, change si préférence contraire)

    freebsd:
      users:
        - name: admin
          primary_group: www
          secondary_groups: [wheel]
          shell: /bin/csh
          ssh_keys:
            #{comment}
            - #{key_line}

      sudoers:
        - '%wheel ALL=(ALL) NOPASSWD:ALL'
    YAML
  end

  private def self.render_rails_group : String
    <<-YAML
    # Group rails-servers — stack Ruby on Rails (exemple, à personnaliser).
    #
    # À inclure dans `groups:` d'un host qui héberge une app Rails :
    #   groups: [<zone>, aloli-admin, rails-servers]
    #
    # Les packages listés sont APPENDÉS à ceux déclarés dans d'autres
    # groupes listés par le host (voir règle merge append-by-key dans
    # examples/inventory-tree/README.adoc).

    freebsd:
      packages:
        - sudo
        - zsh
        - curl
        - git
        - ruby
        - rubygem-bundler
        - postgresql16-server
        - postgresql16-client
        - node
        - nginx
    YAML
  end

  private def self.render_backup_group : String
    <<-YAML
    # Group backup-servers — serveurs de sauvegarde (exemple).
    #
    # Typiquement : SSD système + HDD data, rsync/restic/borg pour les
    # backups applicatifs.

    freebsd:
      packages:
        - sudo
        - zsh
        - curl
        - git
        - rsync
        - restic
        - borgbackup
    YAML
  end

  private def self.render_hosts_readme(dir : String) : String
    <<-ADOC
    = Dossier hosts/ — un fichier par serveur

    Ce dossier contient un fichier YAML par serveur. Le nom du fichier
    donne le nom logique de l'hôte (ex: `loulou.aloli.net.yml` →
    `loulou.aloli.net`).

    == Ajouter un nouveau serveur

    Quand vous recevez un serveur OVH, vous ne connaissez que son
    `service_name` (ex. `ns3156789.ip-51-83-6.eu`). beryl prend le
    relais :

    [source,sh]
    ----
    # 1. Mise en rescue (via API OVH, utilise la clé SSH de la zone)
    beryl rescue ns3156789.ip-51-83-6.eu

    # 2. Scan + nommage DNS + écriture du fichier host
    beryl scan ns3156789.ip-51-83-6.eu --dns --write
    ----

    `beryl scan --dns` demande :

    - le nom court du serveur (ex. `loulou`)
    - la zone DNS (ex. `aloli.net`)

    Puis pose un CNAME dans la zone (`loulou.aloli.net → ns3156789.ip-...`),
    un reverse DNS sur l'IPv4 et l'IPv6 du serveur, et renomme
    l'affichage côté panel OVH. Écrit ensuite `hosts/loulou.aloli.net.yml`.

    == Structure type d'un fichier host

    [source,yaml]
    ----
    provider: ovh
    ovh:
      service_name: ns3156789.ip-51-83-6.eu
      # ssh_key_name : hérité du groupe zone

    groups:
      - aloli-net       # zone DNS + ssh_key_name
      - aloli-admin     # user admin standard
      - rails-servers   # stack fonctionnelle

    freebsd:
      hostname: loulou
      disks: [/dev/sda, /dev/sdb]
      raid: mirror
      # Tout le reste (timezone, packages, users, sudoers) vient des
      # groupes listés ci-dessus.
    ----
    ADOC
  end
end
