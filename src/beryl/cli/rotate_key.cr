require "yaml"
require "../config"
require "../apply"

module Beryl::CLI::RotateKey
  EXIT_OK    = 0
  EXIT_FAIL  = 1
  EXIT_USAGE = 2

  # Une paire de rotation trouvée dans un fichier de conf.
  # `user` nil = paire au niveau racine `ssh_keys:` (concerne TOUS les users).
  record Pair, user : String?, active : String, suivante : String

  # `beryl rotate-key <host-fqdn | domaine>`
  #
  # Fait tourner les PAIRES de clés `[active, suivante]` déclarées dans le
  # fichier de la portée (host ou domaine). Par (host, user) : connexion
  # avec l'active → pose la suivante → VÉRIFIE que la suivante se connecte →
  # connexion avec la suivante → retire l'active. La 2ᵉ vérif garantit
  # qu'on ne se verrouille jamais dehors. Le fichier de conf n'est mis à
  # jour (`[active, suivante]` → `[suivante]`) que si TOUT a réussi.
  def self.run(config_root : String, args : Array(String)) : Int32
    scope = args.first?
    unless scope
      STDERR.puts "USAGE : beryl rotate-key <host-fqdn | domaine>"
      return EXIT_USAGE
    end

    root = Beryl::Config::Root.load(config_root)
    ssh_dir = root.ssh_dir

    prim = Beryl::Apply::Primitive["user-update-keys"]?
    unless prim
      STDERR.puts "beryl : primitive user-update-keys absente (bug)."
      return EXIT_FAIL
    end

    file_path, hosts = resolve_scope(root, scope)
    if hosts.empty?
      STDERR.puts "beryl : portée `#{scope}` introuvable (ni host ni domaine connu)."
      return EXIT_USAGE
    end

    pairs = find_pairs(read_raw(file_path))
    if pairs.empty?
      log "aucune paire de rotation [active, suivante] dans #{file_path} — rien à faire."
      return EXIT_OK
    end

    all_users = user_names(hosts.first)
    log "portée : #{hosts.size} host(s), #{pairs.size} paire(s) — fichier #{file_path}"

    failures = 0
    hosts.each do |host|
      pairs.each do |pair|
        users = (u = pair.user) ? [u] : all_users
        users.each do |user|
          failures += 1 unless rotate_one(prim, host, user, pair, ssh_dir)
        end
      end
    end

    if failures > 0
      STDERR.puts "beryl : #{failures} rotation(s) en échec — fichier de conf NON modifié (sécurité)."
      return EXIT_FAIL
    end

    pairs.each { |pair| swap_pair_in_file(file_path, pair) }
    log "rotation terminée pour toutes les paires. #{file_path} mis à jour."
    EXIT_OK
  end

  # Portée → (fichier à éditer, hosts résolus). Host d'abord, sinon domaine.
  private def self.resolve_scope(root, scope) : Tuple(String, Array(Beryl::Config::ResolvedHost))
    begin
      host = root.resolve(scope)
      return {host.node.source_path, [host]}
    rescue Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost | Beryl::Config::Root::UnknownDomain
      # pas un host → on tente un domaine.
    end

    root.accounts.each_value do |account|
      if domain = account.domain?(scope)
        hosts = domain.all_hosts.keys.compact_map do |hn|
          begin
            root.resolve(hn, account_hint: account.name, domain_hint: domain.name)
          rescue
            nil
          end
        end
        return {domain.source_path, hosts}
      end
    end
    {"", [] of Beryl::Config::ResolvedHost}
  end

  # Une rotation (host, user, paire). Retourne false en cas d'échec (et
  # alors l'ancienne clé reste — jamais de lock-out).
  private def self.rotate_one(prim, host, user, pair, ssh_dir) : Bool
    active_pub = Beryl::Config.resolve_ssh_key(pair.active, ssh_dir)
    suivante_pub = Beryl::Config.resolve_ssh_key(pair.suivante, ssh_dir)
    active_priv = derive_priv(pair.active, ssh_dir)
    suivante_priv = derive_priv(pair.suivante, ssh_dir)
    unless active_priv && suivante_priv
      missing = active_priv ? pair.suivante : pair.active
      STDERR.puts "  ✗ #{host.fqdn}/#{user} : clé privée introuvable pour #{missing}"
      return false
    end

    conn_a = SSH::Connection.new(host: host.ssh_host, user: user, port: host.port, identity_file: active_priv)

    # Reprise / idempotence : si l'ancienne ne se connecte PLUS mais la
    # nouvelle OUI, ce (host, user) est DÉJÀ rotationné → succès. Évite de
    # casser un host déjà fait lors d'un re-run après un échec partiel.
    unless conn_a.exec("true", raise_on_error: false).success?
      conn_chk = SSH::Connection.new(host: host.ssh_host, user: user, port: host.port, identity_file: suivante_priv)
      if conn_chk.exec("true", raise_on_error: false).success?
        log "  ✓ #{host.fqdn}/#{user} : déjà rotationné (nouvelle clé active)"
        return true
      end
      STDERR.puts "  ✗ #{host.fqdn}/#{user} : ni l'ancienne ni la nouvelle clé ne se connectent"
      return false
    end

    # Passe 1 : connexion avec l'ACTIVE → pose la suivante (garde l'active).
    sh_a = Beryl::Apply::SshShell.new(conn_a)
    ctx_a = Beryl::Apply::Context.new(protected_keys: [active_pub])
    r1 = prim.apply(sh_a, params(user, [active_pub, suivante_pub]), false, ctx_a)
    if r1.outcome.failed?
      STDERR.puts "  ✗ #{host.fqdn}/#{user} : pose de la nouvelle clé échouée (#{r1.message})"
      return false
    end

    # Passe 2 : VÉRIFIE que la SUIVANTE se connecte AVANT de retirer l'active.
    conn_b = SSH::Connection.new(host: host.ssh_host, user: user, port: host.port, identity_file: suivante_priv)
    unless conn_b.exec("true", raise_on_error: false).success?
      STDERR.puts "  ✗ #{host.fqdn}/#{user} : la NOUVELLE clé ne se connecte pas → on GARDE l'ancienne (zéro lock-out)."
      return false
    end

    # Passe 3 : connexion avec la SUIVANTE → retire l'active.
    sh_b = Beryl::Apply::SshShell.new(conn_b)
    ctx_b = Beryl::Apply::Context.new(protected_keys: [suivante_pub])
    r3 = prim.apply(sh_b, params(user, [suivante_pub]), false, ctx_b)
    if r3.outcome.failed?
      STDERR.puts "  ✗ #{host.fqdn}/#{user} : retrait de l'ancienne clé échoué (#{r3.message})"
      return false
    end

    log "  ✓ #{host.fqdn}/#{user} : #{pair.active} → #{pair.suivante}"
    true
  end

  private def self.params(user : String, keys : Array(String)) : Hash(String, YAML::Any)
    {
      "user" => YAML::Any.new(user),
      "keys" => YAML::Any.new(keys.map { |k| YAML::Any.new(k) }),
    }
  end

  # Clé privée depuis un nom public `X.pub` : `~/.ssh/X.key` (beryl) puis
  # `~/.ssh/X` (officiel, ex. id_ed25519). 1ʳᵉ qui existe.
  private def self.derive_priv(pubname : String, ssh_dir : String) : String?
    base = pubname.ends_with?(".pub") ? pubname[0...-4] : pubname
    [File.join(ssh_dir, "#{base}.key"), File.join(ssh_dir, base)].find { |p| File.exists?(p) }
  end

  private def self.read_raw(path : String) : Hash(YAML::Any, YAML::Any)
    return {} of YAML::Any => YAML::Any if path.empty? || !File.exists?(path)
    YAML.parse(File.read(path)).as_h? || {} of YAML::Any => YAML::Any
  end

  # Paires dans un raw de conf : racine `ssh_keys:` (user nil) +
  # `freebsd.users[].ssh_keys` (user nommé). Public pour les tests.
  def self.find_pairs(raw : Hash(YAML::Any, YAML::Any)) : Array(Pair)
    pairs = [] of Pair
    if arr = raw[YAML::Any.new("ssh_keys")]?.try(&.as_a?)
      each_pair(arr) { |a, s| pairs << Pair.new(nil, a, s) }
    end
    users = raw[YAML::Any.new("freebsd")]?.try(&.as_h?).try(&.[YAML::Any.new("users")]?).try(&.as_a?)
    users.try do |arr|
      Beryl::Config::Users.list(arr).each do |e|
        if keys = e.fields[YAML::Any.new("ssh_keys")]?.try(&.as_a?)
          each_pair(keys) { |a, s| pairs << Pair.new(e.name, a, s) }
        end
      end
    end
    pairs
  end

  private def self.each_pair(arr : Array(YAML::Any), &)
    arr.each do |e|
      if (p = e.as_a?) && p.size == 2 && (a = p[0].as_s?) && (s = p[1].as_s?)
        yield a, s
      end
    end
  end

  private def self.user_names(host : Beryl::Config::ResolvedHost) : Array(String)
    users = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?).try(&.[YAML::Any.new("users")]?).try(&.as_a?)
    return [] of String unless users
    Beryl::Config::Users.list(users).map(&.name)
  end

  # Remplace l'entrée `[active, suivante]` par `suivante` dans le fichier,
  # en laissant le reste (commentaires inclus) intact. Public pour les tests.
  def self.swap_pair_in_file(path : String, pair : Pair) : Nil
    return if path.empty? || !File.exists?(path)
    content = File.read(path)
    re = /\[\s*#{Regex.escape(pair.active)}\s*,\s*#{Regex.escape(pair.suivante)}\s*\]/
    File.write(path, content.sub(re, pair.suivante))
  end

  private def self.log(msg : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl rotate-key] #{msg}"
  end
end
