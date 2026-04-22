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
    non_interactive = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl init [provider] [options]\n\n" \
                 "Ajoute un domaine dans ~/.beryl/ (ou crée l'arborescence la première fois)."
      p.on("-z NAME", "--zone=NAME", "Zone DNS (ex: aloli.net)") { |v| zone_flag = v }
      p.on("-s NAME", "--ssh-key-name=NAME", "Label de la clé SSH chez l'hébergeur (auto via API si absent)") { |v| ssh_key_name_flag = v }
      p.on("-k FILE", "--admin-key=FILE", "Fichier .pub local (auto via ~/.ssh/ sinon)") { |v| admin_key_file = File.expand_path(v, home: true) }
      p.on("-f", "--force", "Écrase les fichiers existants") { force = true }
      p.on("-N", "--non-interactive", "Aucune invite (tout via flags)") { non_interactive = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    provider_hint ||= positional.first?

    Dir.mkdir_p(config_root)

    # Choix du provider
    provider = choose_provider(config_root, provider_hint, non_interactive)
    return EXIT_USAGE unless provider

    # Zone DNS (= nom du domaine)
    zone_in = zone_flag
    zone : String = zone_in ? zone_in : (non_interactive ? raise("--zone requis en --non-interactive") : ask("Zone DNS du domaine (ex: aloli.net) : ", ""))
    return EXIT_USAGE if zone.empty?

    domain_yml = File.join(config_root, "#{zone}.yml")
    if File.exists?(domain_yml) && !force
      STDERR.puts "beryl : #{domain_yml} existe déjà (utilisez --force pour écraser)"
      return EXIT_USAGE
    end

    # Détection clé SSH provider + fichier .pub local par matching
    selection = select_ssh_key(provider, ssh_key_name_flag, admin_key_file, non_interactive)
    return EXIT_ABORTED unless selection

    # Écriture du socle _default.yml s'il n'existe pas
    defaults_path = File.join(config_root, "_default.yml")
    unless File.exists?(defaults_path)
      File.write(defaults_path, default_yaml_content)
      STDERR.puts "[beryl init] _default.yml créé"
    end

    # Écriture du fichier domaine
    admin_key_content = selection[:admin_key_content]
    File.write(domain_yml, render_domain_yaml(provider, selection[:provider_key_id], admin_key_content))
    STDERR.puts "[beryl init] #{domain_yml} créé"

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

  # Choisit un provider (avec détection credentials + prompt si
  # plusieurs + config interactive si absent).
  private def self.choose_provider(config_root : String, flag : String?, non_interactive : Bool) : Beryl::Provider?
    env_path = File.join(config_root, ".env.yml")
    env_file = Beryl::Config::EnvFile.load(env_path)

    # Les providers.available? regardent ENV ; on applique les vars du
    # .env.yml le temps de la détection.
    available_names = env_file.domains.flat_map { |d| env_file.for_domain(d).keys }.to_set
    env_file.domains.each { |d| env_file.apply_to_env(d) }

    implemented = Beryl::Providers.all

    if flag
      p = Beryl::Providers.find(flag)
      unless p
        STDERR.puts "beryl : provider inconnu : #{flag}. Disponibles : #{implemented.map(&.name).join(", ")}"
        return nil
      end
      STDERR.puts "[beryl init] Provider : #{p.display_name}"
      return configure_provider_if_needed(p, env_file, env_path, non_interactive)
    end

    available = implemented.select(&.available?)
    case available.size
    when 0
      if non_interactive
        STDERR.puts "beryl : aucun provider configuré (ajoutez --provider ou exportez les credentials)"
        return nil
      end
      STDERR.puts "[beryl init] Aucun provider configuré."
      STDERR.puts "Hébergeurs supportés :"
      implemented.each_with_index { |p, i| STDERR.puts "  #{i + 1}. #{p.display_name} (#{p.name})" }
      ans = ask("Lequel configurer ? [1] : ", "1")
      idx = (ans.to_i? || 1).clamp(1, implemented.size) - 1
      return configure_provider_if_needed(implemented[idx], env_file, env_path, non_interactive)
    when 1
      p = available.first
      STDERR.puts "[beryl init] Provider détecté : #{p.display_name}"
      p
    else
      STDERR.puts "[beryl init] Providers disponibles :"
      available.each_with_index { |p, i| STDERR.puts "  #{i + 1}. #{p.display_name} (#{p.name})" }
      ans = ask("Lequel utiliser ? [1] : ", "1")
      idx = (ans.to_i? || 1).clamp(1, available.size) - 1
      available[idx]
    end
  end

  private def self.configure_provider_if_needed(provider : Beryl::Provider, env_file : Beryl::Config::EnvFile, env_path : String, non_interactive : Bool) : Beryl::Provider?
    return provider if provider.available?
    return nil if non_interactive
    STDERR.puts "[beryl init] Configuration #{provider.display_name}"
    STDERR.puts "  Aide : #{provider.credentials_help_url}"
    values = {} of String => String
    provider.credentials_env_vars.each do |var|
      prompt = "  #{var.name}"
      prompt += " [#{var.default}]" if var.default
      prompt += " (optionnel)" if var.optional
      prompt += " : "
      input = ask_optional(prompt)
      input = var.default.not_nil! if input.empty? && var.default
      next if input.empty?
      values[var.name] = input
    end

    # Section temporaire "__init_pending__" → le domaine sera renommé
    # après saisie de la zone. Pour simplifier : on demande la zone
    # tout de suite pour poser les credentials dans la bonne section.
    zone = ask("Zone DNS de ce domaine (ex: aloli.net) : ", "")
    raise Aborted.new if zone.empty?
    env_file.set_domain(zone, values)
    env_file.save
    STDERR.puts "[beryl init] Credentials écrits dans #{env_path}"
    # Ré-applique pour que provider.available? devienne vrai.
    env_file.apply_to_env(zone, overwrite: true)
    provider.available? ? provider : nil
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

    admin_key_content = if admin_key_flag
                          File.read_lines(admin_key_flag).map(&.strip).reject(&.empty?).first? || ""
                        elsif local = chosen[:local]
                          File.read_lines(local).map(&.strip).reject(&.empty?).first? || ""
                        else
                          chosen[:remote].public_key
                        end

    {provider_key_id: chosen[:remote].id, admin_key_content: admin_key_content}
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
    # Socle technique FreeBSD — commun à TOUS les domaines.
    # Les clés SSH ne sont PAS ici : elles sont déclarées dans chaque
    # <domaine>.yml (ssh_keys:) et injectées automatiquement dans chaque
    # user par le merge.

    freebsd:
      timezone: Europe/Paris
      pool_name: zroot
      swap_gb: 4
      raid: stripe
      install_type: distribution_sets
      packages:
        - sudo
        - zsh
        - curl
        - git
      sudoers:
        - '%wheel ALL=(ALL) NOPASSWD:ALL'
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

  # Contenu d'un `<domaine>.yml`. Porte l'identité : clé du domaine
  # (ssh_keys:) et clé SSH chez le provider (<provider>.ssh_key_name).
  private def self.render_domain_yaml(provider : Beryl::Provider, key_id : String, admin_key : String) : String
    String.build do |io|
      io << "# Identité du domaine — clé SSH côté " << provider.display_name
      io << "\n# (injectée au rescue par l'API) + clé(s) SSH des users (posées\n"
      io << "# dans ~<user>/.ssh/authorized_keys par beryl bootstrap + apply).\n\n"
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
end
