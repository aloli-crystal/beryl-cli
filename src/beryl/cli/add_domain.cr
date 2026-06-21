require "option_parser"
require "../config"
require "../providers"
require "./account_utils"
require "./config_git"

# Sous-commande `beryl add-domain` : ajoute un domaine (zone DNS) à
# une société et crée `~/.config/beryl/<société>/<domaine>.yml`.
#
# Formes équivalentes :
#
#   beryl add-domain acme/example.net
#   beryl add-domain example.net --account=acme
#
# Le domaine déclare :
#   - `dns_provider` : qui gère la zone (gandi, ovh, scaleway…)
#   - `provider`     : hébergeur par défaut des hosts du domaine
#   - un bloc `<provider>:` avec la SSH key du compte provider
#     (auto-sélectionnée via l'API si une seule clé correspond)
#   - `ssh_keys:`    : clés SSH utilisateurs (contenu ou nom de
#     fichier sous ~/.ssh/)
module Beryl::CLI::AddDomain
  EXIT_OK      = 0
  EXIT_USAGE   = 1
  EXIT_ABORTED = 2

  def self.run(config_root : String, args : Array(String)) : Int32
    account_flag : String? = nil
    dns_provider_flag : String? = nil
    provider_flag : String? = nil
    ssh_key_name_flag : String? = nil
    admin_key_file : String? = nil
    force = false
    non_interactive = false
    dry_run = false
    no_commit = false
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE :\n" \
                 "  beryl add-domain <société>/<domaine>\n" \
                 "  beryl add-domain <domaine> [--account=NAME]\n\n" \
                 "Crée ~/.config/beryl/<société>/<domaine>.yml."
      p.on("-a NAME", "--account=NAME", "Société cible") { |v| account_flag = v }
      p.on("-n", "--dry-run", "Affiche ce qui serait fait sans écrire ni appeler d'API") { dry_run = true }
      p.on("-D NAME", "--dns-provider=NAME", "Gestionnaire DNS (cloudflare, gandi, ovh…)") { |v| dns_provider_flag = v }
      p.on("-P NAME", "--provider=NAME", "Hébergeur par défaut (dedibox, ovh, scaleway…)") { |v| provider_flag = v }
      p.on("-s NAME", "--ssh-key-name=NAME", "Label clé SSH chez le provider (auto sinon)") { |v| ssh_key_name_flag = v }
      p.on("-k FILE", "--admin-key=FILE", "Fichier .pub local (auto via ~/.ssh/ sinon)") { |v| admin_key_file = File.expand_path(v, home: true) }
      p.on("-f", "--force", "Écrase le fichier domaine existant") { force = true }
      p.on("-N", "--non-interactive", "Refuse tout prompt") { non_interactive = true }
      p.on("--no-commit", "N'auto-commite pas le fichier domaine dans le dépôt git de config") { no_commit = true }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : domaine non précisé. USAGE : beryl add-domain <société>/<domaine>"
      return EXIT_USAGE
    end

    parsed = Beryl::CLI::AccountUtils.split_account_path(raw)
    domain_name = parsed[:object]
    path_account = parsed[:account]

    account = Beryl::CLI::AccountUtils.resolve_account(config_root, path_account, account_flag)
    unless account
      STDERR.puts "beryl : impossible de déterminer la société. Utilisez :"
      STDERR.puts "  - la forme `beryl add-domain <société>/#{domain_name}`"
      STDERR.puts "  - ou le flag `--account=<société>`"
      accounts = Beryl::Config::Root.load(config_root).account_names
      STDERR.puts "  Sociétés existantes : #{accounts.empty? ? "(aucune, lancez `beryl init <société>`)" : accounts.join(", ")}"
      return EXIT_USAGE
    end

    account_dir = File.join(config_root, account)
    unless File.directory?(account_dir)
      STDERR.puts "beryl : la société `#{account}` n'existe pas. Créez-la avec `beryl init #{account}` d'abord."
      return EXIT_USAGE
    end

    domain_yml = File.join(account_dir, "#{domain_name}.domain.yml")
    if File.exists?(domain_yml) && !force
      STDERR.puts "beryl : #{domain_yml} existe déjà. Utilisez --force pour écraser."
      return EXIT_USAGE
    end

    # Liste des providers configurés pour cette société (présents
    # dans .env.yml). On restreint les choix à ceux-là.
    env_file = Beryl::Config::EnvFile.load(File.join(config_root, ".env.yml"))
    configured_providers = env_file.providers_for(account)
    if configured_providers.empty?
      STDERR.puts "beryl : la société `#{account}` n'a aucun fournisseur configuré."
      STDERR.puts "        Lancez d'abord `beryl add-provider #{account}/<provider>`."
      return EXIT_USAGE
    end

    # Résout le dns_provider
    dns_provider = resolve_dns_provider(dns_provider_flag, configured_providers, non_interactive)
    return EXIT_ABORTED unless dns_provider
    unless configured_providers.includes?(dns_provider)
      STDERR.puts "beryl : `#{dns_provider}` n'est pas configuré pour la société `#{account}`."
      STDERR.puts "        Configurez-le d'abord avec `beryl add-provider #{account}/#{dns_provider}`."
      return EXIT_USAGE
    end
    dns_prov_instance = Beryl::Providers.find(dns_provider)
    unless dns_prov_instance && dns_prov_instance.capable_of?(:dns)
      STDERR.puts "beryl : `#{dns_provider}` ne sait pas gérer le DNS (pas de capability :dns)."
      return EXIT_USAGE
    end

    # Résout le compute_provider (peut être le même que dns)
    compute_provider = resolve_compute_provider(provider_flag, configured_providers, dns_provider, non_interactive)
    return EXIT_ABORTED unless compute_provider
    unless configured_providers.includes?(compute_provider)
      STDERR.puts "beryl : `#{compute_provider}` n'est pas configuré pour la société `#{account}`."
      return EXIT_USAGE
    end

    compute_prov_instance = Beryl::Providers.find(compute_provider).not_nil!

    if dry_run
      STDERR.puts
      STDERR.puts "DRY-RUN : actions `beryl add-domain #{account}/#{domain_name}` prévues :"
      STDERR.puts "  - DNS provider    : #{dns_provider}"
      STDERR.puts "  - Compute provider : #{compute_provider}"
      STDERR.puts "  - Sélection SSH key côté #{compute_provider} (appel API `list_ssh_keys`)"
      STDERR.puts "  - Écriture du fichier : #{domain_yml}"
      STDERR.puts
      STDERR.puts "DRY-RUN : aucune action exécutée, aucune API appelée."
      STDERR.puts "Pour exécuter : #{Beryl.rerun_hint("add-domain", args)}"
      return EXIT_OK
    end

    # Sélection de la SSH key côté compute provider
    env_file.apply_to_env(account, compute_provider, overwrite: true)

    selection = select_ssh_key(compute_prov_instance, ssh_key_name_flag, admin_key_file, non_interactive)
    return EXIT_ABORTED unless selection

    admin_key_content = selection[:admin_key_content]
    content = render_domain_yaml(
      dns_provider: dns_provider,
      provider: compute_provider,
      compute_prov: compute_prov_instance,
      provider_key_id: selection[:provider_key_id],
      admin_key: admin_key_content,
    )

    File.write(domain_yml, content)
    STDERR.puts "[beryl add-domain] 3 #{domain_yml} créé."
    Beryl::CLI::ConfigGit.commit(
      [domain_yml],
      "add-domain : #{domain_name} (dns=#{dns_provider}, compute=#{compute_provider})",
      no_commit,
    )
    STDERR.puts
    STDERR.puts "Récapitulatif #{domain_name} :"
    STDERR.puts "  - zone DNS gérée par : #{dns_provider}"
    STDERR.puts "  - hébergeur des serveurs (défaut) : #{compute_provider}"
    STDERR.puts "  (les deux rôles sont distincts — DNS chez l'un, serveurs chez l'autre)"
    STDERR.puts
    STDERR.puts "Prochaines étapes :"
    STDERR.puts "  beryl rescue <host> --account=#{account} --domain=#{domain_name}"
    STDERR.puts "  beryl scan <host> --account=#{account} --domain=#{domain_name} --dns --write"
    EXIT_OK
  rescue ex : Beryl::CLI::AccountUtils::Aborted
    STDERR.puts "beryl : abandon"
    EXIT_ABORTED
  end

  private def self.resolve_dns_provider(flag : String?, configured : Array(String), non_interactive : Bool) : String?
    return flag if flag
    # Filtre les providers DNS-capable parmi les configurés
    dns_capable = configured.select do |p|
      prov = Beryl::Providers.find(p)
      prov && prov.capable_of?(:dns)
    end
    case dns_capable.size
    when 0
      STDERR.puts "beryl : aucun fournisseur DNS-capable configuré pour cette société."
      STDERR.puts "        Fournisseurs configurés : #{configured.join(", ")}."
      STDERR.puts "        Aucun n'a la capability :dns dans ce build."
      nil
    when 1
      STDERR.puts "[beryl add-domain] 3 Gestionnaire DNS de la zone (auto) : #{dns_capable.first}"
      dns_capable.first
    else
      return dns_capable.first if non_interactive
      STDERR.puts "[beryl add-domain] 3 Gestionnaires DNS disponibles :"
      dns_capable.each_with_index { |p, i| STDERR.puts "  #{i + 1}. #{p}" }
      ans = Beryl::CLI::AccountUtils.ask("Lequel gère la zone ? [1] :", "1")
      idx = (ans.to_i? || 1).clamp(1, dns_capable.size) - 1
      dns_capable[idx]
    end
  end

  private def self.resolve_compute_provider(flag : String?, configured : Array(String), dns_provider : String, non_interactive : Bool) : String?
    return flag if flag
    compute_capable = configured.select do |p|
      prov = Beryl::Providers.find(p)
      prov && prov.capable_of?(:compute)
    end
    return nil if compute_capable.empty?
    # S'il y a un seul compute-capable, auto.
    if compute_capable.size == 1
      STDERR.puts "[beryl add-domain] 3 Hébergeur des serveurs (auto) : #{compute_capable.first}"
      return compute_capable.first
    end
    # Plusieurs : propose le dns_provider en défaut si lui aussi compute-capable
    default = compute_capable.includes?(dns_provider) ? dns_provider : compute_capable.first
    return default if non_interactive
    STDERR.puts "[beryl add-domain] 3 Hébergeurs disponibles :"
    compute_capable.each_with_index do |p, i|
      marker = p == default ? " (défaut)" : ""
      STDERR.puts "  #{i + 1}. #{p}#{marker}"
    end
    ans = Beryl::CLI::AccountUtils.ask("Lequel par défaut pour les hosts ? :", default)
    # `ans` peut être un nom ou un numéro
    if idx = ans.to_i?
      compute_capable[(idx - 1).clamp(0, compute_capable.size - 1)]
    else
      compute_capable.includes?(ans) ? ans : default
    end
  end

  # Sélection SSH key côté provider (réutilise la logique de l'ancien
  # init.cr). Peut retourner nil si l'utilisateur annule ou si l'API
  # provider est indisponible.
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
                 STDERR.puts "[beryl add-domain] 3 Clé #{provider.name} : #{auto.first[:remote].name} ↔ #{auto.first[:local]}"
                 auto.first
               when 0
                 raise Beryl::CLI::AccountUtils::Aborted.new if non_interactive
                 STDERR.puts "[beryl add-domain] 3 Aucun ~/.ssh/*.pub ne correspond. Clés #{provider.display_name} :"
                 remote_keys.each_with_index { |k, i| STDERR.puts "  #{i + 1}. #{k.name}" }
                 ans = Beryl::CLI::AccountUtils.ask("Laquelle utiliser ? :", "1")
                 idx = (ans.to_i? || 1).clamp(1, remote_keys.size) - 1
                 {remote: remote_keys[idx], local: nil.as(String?)}
               else
                 raise Beryl::CLI::AccountUtils::Aborted.new if non_interactive
                 STDERR.puts "[beryl add-domain] 3 Plusieurs correspondances :"
                 auto.each_with_index { |m, i| STDERR.puts "  #{i + 1}. #{m[:remote].name} ↔ #{File.basename(m[:local].not_nil!)}" }
                 ans = Beryl::CLI::AccountUtils.ask("Laquelle utiliser ? :", "1")
                 idx = (ans.to_i? || 1).clamp(1, auto.size) - 1
                 auto[idx]
               end
             end

    admin_key_ref = if admin_key_flag
                      ssh_dir = File.expand_path("~/.ssh", home: true)
                      if admin_key_flag.starts_with?(ssh_dir + "/") || admin_key_flag.starts_with?(ssh_dir + File::SEPARATOR)
                        File.basename(admin_key_flag)
                      else
                        File.read_lines(admin_key_flag).map(&.strip).reject(&.empty?).first? || ""
                      end
                    elsif local = chosen[:local]
                      File.basename(local)
                    else
                      chosen[:remote].public_key
                    end

    {provider_key_id: chosen[:remote].id, admin_key_content: admin_key_ref}
  end

  private def self.list_local_pub_files : Array(String)
    ssh_dir = File.expand_path("~/.ssh", home: true)
    return [] of String unless File.directory?(ssh_dir)
    Dir.children(ssh_dir).select(&.ends_with?(".pub")).sort.map { |f| File.join(ssh_dir, f) }
  end

  # Rend le contenu du `<domaine>.yml` avec dns_provider, provider,
  # bloc <provider>:, et ssh_keys:.
  private def self.render_domain_yaml(
    dns_provider : String,
    provider : String,
    compute_prov : Beryl::Provider,
    provider_key_id : String,
    admin_key : String,
  ) : String
    String.build do |io|
      io << "# Domaine géré par beryl — ADR-014\n"
      io << "#\n"
      io << "# dns_provider : qui héberge la zone DNS (records A/AAAA, reverse).\n"
      io << "# provider     : hébergeur par défaut des hosts de ce domaine.\n"
      io << "#                Peut être surchargé par host (provider: scaleway\n"
      io << "#                dans un fichier host précis).\n"
      io << "# Les credentials (API keys) sont dans .env.yml[<société>][<provider>].\n\n"
      io << "dns_provider: " << dns_provider << '\n'
      io << "provider: " << provider << "\n\n"

      fragment = compute_prov.ssh_key_yaml_fragment(provider_key_id)
      io << compute_prov.name << ":\n"
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
        io << "  # TODO : ajoutez au moins une clé SSH publique ici.\n"
        io << "  # - philippe.example.com.pub  # nom de fichier dans ~/.ssh/\n"
        io << "  # - ssh-ed25519 AAAA... votre@email  # contenu inline\n"
      else
        io << "  - " << admin_key << '\n'
      end
    end
  end
end
