require "option_parser"
require "file_utils"
require "./credentials"

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
    provider_flag : String? = nil
    dir : String = DEFAULT_DIR
    force = false
    non_interactive = false

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl init [options]\n\n" \
                 "Crée l'arborescence d'un inventaire beryl dans #{DEFAULT_DIR}\n" \
                 "avec des squelettes de groupes (zone DNS, admin standard)."
      p.on("--provider=NAME", "Hébergeur (ovh|scaleway). Auto-détecté depuis l'env si absent.") { |v| provider_flag = v }
      p.on("--zone=NAME", "Zone DNS (ex: aloli.net). Sera un groupe `<zone>` (points → tirets).") { |v| zone = v }
      p.on("--ssh-key-name=NAME", "Nom de la clé SSH chez l'hébergeur (sinon auto-détecté via API)") { |v| ssh_key_name = v }
      p.on("--admin-key=FILE", "Fichier .pub local (sinon auto-détecté dans ~/.ssh/)") { |v| admin_key_file = File.expand_path(v, home: true) }
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

    STDERR.puts "[beryl init] Amorçage de votre inventaire." if !non_interactive

    # Question 1 : hébergeur. On parcourt le registre et garde ceux
    # dont les credentials sont dispos. 1 → auto, 2+ → prompt, 0 → erreur.
    provider = resolve_provider(provider_flag, non_interactive)
    return EXIT_USAGE unless provider

    # Question 2 : zone DNS. Pas dans l'API (plusieurs zones possibles
    # par compte). On demande.
    z_in = zone
    zv : String = z_in ? z_in : (non_interactive ? raise("--zone requis en --non-interactive") : ask(
      "Zone DNS que vous gérez (ex: aloli.net) : ", "",
    ))
    raise Aborted.new if zv.empty?

    # Question 3 : clé SSH du provider + fichier .pub local. Ces deux
    # infos sont liées : on liste les clés côté provider, leurs
    # contenus publics, et on cherche la correspondance dans
    # ~/.ssh/*.pub. Si 1 match ET 1 seule clé → tout est auto. Sinon
    # on retombe sur des prompts ciblés.
    key_selection = select_ssh_key(provider, ssh_key_name, admin_key_file, non_interactive)
    return EXIT_ABORTED unless key_selection
    provider_key_id = key_selection[:provider_key_id]
    akf_path = key_selection[:local_pub_path]

    # Lecture du contenu de la clé publique locale. Déjà résolue plus
    # haut par select_ssh_key → akf_path pointe sur un fichier existant.
    admin_key_content = if akf_path && !akf_path.empty?
                          lines = File.read_lines(akf_path).map(&.strip).reject { |l| l.empty? || l.starts_with?('#') }
                          lines.first? || ""
                        else
                          ""
                        end

    zone_group_name = zv.gsub('.', '-')

    # Création de la structure.
    FileUtils.mkdir_p(File.join(dir, "groups"))
    FileUtils.mkdir_p(File.join(dir, "hosts"))

    write_file(File.join(dir, "groups", "#{zone_group_name}.yml"),
      render_zone_group(zv, provider, provider_key_id))
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
    STDERR.puts "            Hébergeur :  #{provider.display_name}"
    STDERR.puts "            Zone :       #{zv} (groupe : #{zone_group_name})"
    STDERR.puts "            Clé #{provider.name} : #{provider_key_id}"
    STDERR.puts "            Clé admin :  #{admin_key_content.empty? ? "(à remplir manuellement)" : "chargée depuis #{akf_path}"}"
    STDERR.puts
    STDERR.puts "Prochaines étapes :"
    STDERR.puts "  1. Relisez groups/*.yml, ajustez packages, users, sudoers."
    STDERR.puts "  2. Pour ajouter un serveur :"
    STDERR.puts "       beryl rescue <service_name>"
    STDERR.puts "       beryl scan   <service_name> --dns --write"
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

  # Sélectionne l'hébergeur à utiliser parmi ceux enregistrés dans
  # `Beryl::Providers` dont les credentials sont dispos. 0 → erreur
  # explicite (rien configuré), 1 → auto, 2+ → prompt. `--provider=NAME`
  # court-circuite la détection.
  def self.resolve_provider(flag : String?, non_interactive : Bool) : Beryl::Provider?
    if flag
      p = Beryl::Providers.find(flag)
      unless p
        STDERR.puts "beryl : provider inconnu : #{flag}. Disponibles : #{Beryl::Providers.all.map(&.name).join(", ")}"
        return nil
      end
      unless p.available?
        STDERR.puts "beryl : provider #{flag} demandé mais ses credentials ne sont pas dans l'environnement."
        return nil
      end
      STDERR.puts "[beryl init] Hébergeur : #{p.display_name} (depuis --provider)"
      return p
    end

    available = Beryl::Providers.available
    case available.size
    when 0
      STDERR.puts "[beryl init] Aucun hébergeur configuré dans l'environnement."
      STDERR.puts "            Exportez les credentials de l'un des providers supportés :"
      Beryl::Providers.all.each do |p|
        STDERR.puts "              - #{p.display_name} (#{p.name})"
      end
      nil
    when 1
      p = available.first
      STDERR.puts "[beryl init] Hébergeur détecté : #{p.display_name}"
      p
    else
      if non_interactive
        raise "plusieurs hébergeurs disponibles (#{available.map(&.name).join(", ")}), passez --provider=NAME"
      end
      STDERR.puts "[beryl init] Hébergeurs disponibles :"
      available.each_with_index { |p, i| STDERR.puts "  #{i + 1}. #{p.display_name} (#{p.name})" }
      answer = ask("Lequel utiliser ? [1] : ", "1")
      idx = answer.to_i? || 1
      idx = 1 if idx < 1 || idx > available.size
      available[idx - 1]
    end
  end

  # Trouve la correspondance (clé provider ↔ fichier .pub local) sans
  # demander à l'utilisateur quand c'est possible. Règle de matching :
  # la clé distante et la clé locale ont le même couple « type + base64 »
  # (le commentaire final peut différer).
  #
  # Cas :
  # - Flags explicites fournis → on les utilise et on vérifie la
  #   cohérence (warning si pas de match, pas d'erreur).
  # - 1 clé provider + 1 fichier local correspondant → tout auto.
  # - Plusieurs clés provider avec un unique match local → auto sur le
  #   match, les autres sont ignorées.
  # - Pas de match → prompts ciblés.
  # - Aucune clé côté provider → erreur explicite.
  def self.select_ssh_key(
    provider : Beryl::Provider,
    ssh_key_name_flag : String?,
    admin_key_flag : String?,
    non_interactive : Bool,
  ) : NamedTuple(provider_key_id: String, local_pub_path: String?)?
    remote_keys = provider.list_ssh_keys
    local_pubs = list_local_pub_files

    if remote_keys.empty?
      STDERR.puts "beryl : aucune clé SSH côté #{provider.display_name}."
      STDERR.puts "        Créez-en une dans le panel de l'hébergeur puis relancez."
      return nil
    end

    # Match automatique : pour chaque clé distante, cherche le fichier
    # local qui a la même empreinte (type + base64).
    matches = [] of NamedTuple(remote: Beryl::SshKeyInfo, local: String?)
    remote_keys.each do |rk|
      local = local_pubs.find do |f|
        begin
          content = File.read_lines(f).first? || ""
          Beryl::SshKeyInfo.new("", "", content).crypto_fingerprint == rk.crypto_fingerprint
        rescue
          false
        end
      end
      matches << {remote: rk, local: local}
    end

    # Flag explicite → on prend la clé nommée, même sans match local.
    if ssh_key_name_flag
      match = matches.find { |m| m[:remote].id == ssh_key_name_flag || m[:remote].name == ssh_key_name_flag }
      raise "clé #{ssh_key_name_flag} introuvable côté #{provider.display_name}" unless match
      local_path = admin_key_flag ? resolve_admin_key_path(admin_key_flag) : match[:local]
      return {provider_key_id: match[:remote].id, local_pub_path: local_path}
    end

    auto = matches.select { |m| !m[:local].nil? }
    case auto.size
    when 1
      m = auto.first
      STDERR.puts "[beryl init] Clé #{provider.name} détectée : #{m[:remote].name}"
      STDERR.puts "             correspond à #{m[:local]}"
      {provider_key_id: m[:remote].id, local_pub_path: m[:local]}
    when 0
      STDERR.puts "[beryl init] Aucun fichier ~/.ssh/*.pub ne correspond aux clés #{provider.display_name}."
      STDERR.puts "            Clés côté #{provider.display_name} :"
      remote_keys.each { |k| STDERR.puts "              - #{k.name} (#{k.id})" }
      STDERR.puts "            Fichiers .pub locaux : #{local_pubs.empty? ? "(aucun)" : local_pubs.map { |f| File.basename(f) }.join(", ")}"
      if non_interactive
        raise "aucun match auto : passez --ssh-key-name=NAME et --admin-key=FILE"
      end
      pick_manually(provider, remote_keys, local_pubs)
    else
      if non_interactive
        raise "plusieurs matches possibles (#{auto.map { |m| m[:remote].name }.join(", ")}), passez --ssh-key-name=NAME"
      end
      STDERR.puts "[beryl init] Plusieurs clés #{provider.display_name} ont une correspondance locale :"
      auto.each_with_index { |m, i| STDERR.puts "  #{i + 1}. #{m[:remote].name} ↔ #{File.basename(m[:local].not_nil!)}" }
      answer = ask("Laquelle utiliser ? [1] : ", "1")
      idx = answer.to_i? || 1
      idx = 1 if idx < 1 || idx > auto.size
      chosen = auto[idx - 1]
      {provider_key_id: chosen[:remote].id, local_pub_path: chosen[:local]}
    end
  end

  # Liste les fichiers ~/.ssh/*.pub (chemins absolus).
  def self.list_local_pub_files : Array(String)
    ssh_dir = File.expand_path("~/.ssh", home: true)
    return [] of String unless File.directory?(ssh_dir)
    Dir.children(ssh_dir)
      .select(&.ends_with?(".pub"))
      .sort
      .map { |f| File.join(ssh_dir, f) }
  end

  # Dernier recours si le matching automatique échoue : on demande à
  # l'utilisateur de choisir (clé + fichier) à la main.
  private def self.pick_manually(
    provider : Beryl::Provider,
    remote_keys : Array(Beryl::SshKeyInfo),
    local_pubs : Array(String),
  ) : NamedTuple(provider_key_id: String, local_pub_path: String?)?
    STDERR.puts "Clés #{provider.display_name} disponibles :"
    remote_keys.each_with_index { |k, i| STDERR.puts "  #{i + 1}. #{k.name}" }
    answer = ask("Laquelle utiliser pour le rescue ? [1] : ", "1")
    idx_r = answer.to_i? || 1
    idx_r = 1 if idx_r < 1 || idx_r > remote_keys.size
    chosen_remote = remote_keys[idx_r - 1]

    local_path : String? = nil
    unless local_pubs.empty?
      STDERR.puts "Fichiers .pub dans ~/.ssh/ :"
      local_pubs.each_with_index { |f, i| STDERR.puts "  #{i + 1}. #{File.basename(f)}" }
      STDERR.puts "  0. (aucun — clé admin à compléter manuellement plus tard)"
      la = ask("Lequel poser dans authorized_keys de admin ? [1] : ", "1")
      idx_l = la.to_i? || 1
      local_path = idx_l == 0 ? nil : local_pubs[idx_l - 1]
    end
    {provider_key_id: chosen_remote.id, local_pub_path: local_path}
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

  private def self.render_zone_group(zone : String, provider : Beryl::Provider, key_id : String) : String
    fragment = provider.ssh_key_yaml_fragment(key_id)
    <<-YAML
    # Zone #{zone} — clé SSH #{provider.display_name} partagée par
    # tous les serveurs de la zone.
    #
    # À inclure dans le champ `groups:` de chaque host de cette zone.
    # Règle Aloli : la clé SSH de rescue est déclarée ICI, pas recopiée
    # dans chaque fichier host. Un serveur qui utilise une clé spécifique
    # redéclare le champ dans son propre fichier (deep merge YAML →
    # l'override host prime).

    #{provider.name}:
    #{render_yaml_fragment(fragment, indent: "  ")}
    YAML
  end

  # Sérialise un hash plat {String => String | Array(String)} en YAML
  # indenté. Limité à 1 niveau (suffisant pour les fragments provider).
  private def self.render_yaml_fragment(fragment : Hash(String, String | Array(String)), indent : String) : String
    String.build do |io|
      fragment.each_with_index do |(k, v), i|
        io << '\n' if i > 0
        case v
        when String
          io << indent << k << ": " << v
        when Array(String)
          io << indent << k << ":\n"
          v.each_with_index { |item, j| io << indent << "  - " << item; io << '\n' if j < v.size - 1 }
        end
      end
    end
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
