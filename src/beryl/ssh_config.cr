require "./config"

# Accès SSH « à la main » à TOUS les hosts gérés par beryl : un fichier par
# société, `~/.ssh/beryl--<société>.conf`, inclus en tête de `~/.ssh/config`
# (`Include beryl--*.conf`). Chaque host y est joignable par son FQDN et par
# son nom court ; un host CACHÉ derrière le vRack l'est par son IP vRack et un
# `ProxyCommand` qui essaie son bastion préféré puis les autres
# (`ResolvedHost#proxy_jumps`) — même repli que les connexions de beryl. Les
# sauts lisent VOTRE config ssh (clé, agent) comme un `ssh` ordinaire.
module Beryl::SshConfig
  extend self

  # Fichiers générés (un par société) et ligne d'inclusion (chemin relatif à
  # `~/.ssh`, motif accepté par `Include`).
  FILE_PREFIX     = "beryl--"
  INCLUDE_LINE    = "Include #{FILE_PREFIX}*.conf"
  INCLUDE_COMMENT = "# Hosts gérés par beryl (fichiers générés par beryl ssh-config)"
  # Ancien fichier unique (0.6.124), remplacé par les fichiers par société.
  LEGACY_FILE    = "beryl.conf"
  LEGACY_INCLUDE = "Include #{LEGACY_FILE}"
  LEGACY_COMMENT = "# Hosts cachés derrière le vRack (fichier généré par beryl ssh-config)"
  HEADER         = "# Généré par `beryl ssh-config --apply` — ne pas modifier à la main."
  # Délai par bastion avant de passer au suivant.
  JUMP_TIMEOUT = 5

  def file_name(account : String) : String
    "#{FILE_PREFIX}#{account}.conf"
  end

  # Options `ssh -o …` du rebond pour un `ssh` système : `ProxyJump` s'il n'y
  # a qu'un bastion, sinon `ProxyCommand` à replis. Vide sans rebond. Pur.
  def jump_options(jumps : Array(String)) : Array(String)
    return [] of String if jumps.empty?
    return ["-o", "ProxyJump=#{jumps.first}"] if jumps.size == 1
    ["-o", "ProxyCommand=#{proxy_command(jumps)}"]
  end

  # `sh -c '…'` qui essaie chaque bastion dans l'ordre (`ssh -W %h:%p`) et
  # annonce le repli sur stderr. `sh -c` : ssh lance la commande par `exec`,
  # qui ne garderait pas les `||`. Pur.
  def proxy_command(jumps : Array(String)) : String
    hop = ->(j : String) { "ssh -o ConnectTimeout=#{JUMP_TIMEOUT} -W %h:%p #{j}" }
    chain = String.build do |io|
      io << hop.call(jumps.first)
      jumps.each_cons_pair do |previous, nxt|
        io << " || { echo \"beryl : bastion " << previous << " injoignable, essai par " << nxt << "\" >&2; "
        io << hop.call(nxt) << "; }"
      end
    end
    "sh -c '#{chain}'"
  end

  # Contenu des fichiers, par société (noms triés, hosts triés par FQDN).
  # Un bloc par host, commun au FQDN et au nom court : adresse, port, user et
  # clé de la fiche, rebond (un user en ligne de commande, `ssh deploy@ke`,
  # l'emporte toujours). Nom court présent dans deux sociétés : FQDN seul.
  # Hosts en `ssh_config: false` écartés.
  def render(hosts : Array(Beryl::Config::ResolvedHost)) : Hash(String, String)
    hosts = hosts.select(&.ssh_config?)
    shorts = hosts.map(&.short_name).tally
    hosts.group_by(&.account_name).to_a.sort_by(&.[0]).to_h.transform_values do |list|
      String.build do |io|
        io << HEADER << "\n"
        io << "# Tous les hosts de la société : FQDN et nom court ; les hosts cachés\n"
        io << "# derrière le vRack passent par leur bastion, puis les autres.\n"
        list.sort_by(&.fqdn).each { |h| host_block(io, h, short_alias?(h, shorts)) }
      end
    end
  end

  # `~/.ssh/config` avec l'`Include` en tête (l'ancien `Include beryl.conf`
  # retiré), ou nil s'il n'y a rien à changer. En tête : hors de tout bloc
  # `Host` (un `Include` dedans n'y vaudrait que pour ce bloc), et premières
  # valeurs lues = celles qui l'emportent. Pur.
  def with_include(config : String) : String?
    lines = config.lines(chomp: false)
    has_new = lines.any? { |l| l.strip == INCLUDE_LINE }
    has_legacy = lines.any? { |l| l.strip == LEGACY_INCLUDE }
    return if has_new && !has_legacy
    body = lines.reject { |l| l.strip == LEGACY_INCLUDE || l.starts_with?(LEGACY_COMMENT) }.join
    body = body.lchop("\n") if has_legacy
    return body if has_new
    "#{INCLUDE_COMMENT}\n#{INCLUDE_LINE}\n\n#{body}"
  end

  # Ancien fichier unique à retirer : seulement s'il est bien de beryl. Pur.
  def legacy_generated?(content : String) : Bool
    content.starts_with?(HEADER)
  end

  private def host_block(io : IO, h : Beryl::Config::ResolvedHost, short : Bool) : Nil
    jumps = h.proxy_jumps(h.connect_user)
    address = hostname(h, jumps)
    io << "\n# " << h.fqdn << " — " << role(h, jumps) << "\n"
    io << "Host " << (short ? "#{h.short_name} " : "") << h.fqdn << "\n"
    io << "  HostName " << address << "\n"
    # Adresse ≠ nom : les clés d'hôte restent rangées sous le FQDN
    # (known_hosts déjà rempli, une seule entrée par serveur).
    io << "  HostKeyAlias " << h.fqdn << "\n" unless address == h.fqdn
    io << "  Port " << h.port << "\n" unless h.port == 22
    io << "  User " << h.connect_user << "\n"
    if key = h.identity_file
      io << "  IdentityFile " << key << "\n"
      io << "  IdentitiesOnly yes\n"
    end
    if pc = h.proxy_command
      io << "  ProxyCommand " << pc << "\n"
      # Même keepalive que la connexion de beryl : un rebond `nc -w <n>`
      # fermerait une session interactive inactive au bout de n s.
      io << "  ServerAliveInterval " << Beryl::Config::ResolvedHost::SERVER_ALIVE_INTERVAL << "\n"
    elsif jumps.size == 1
      io << "  ProxyJump " << jumps.first << "\n"
    elsif jumps.size > 1
      io << "  ProxyCommand " << proxy_command(jumps) << "\n"
    end
  end

  # Caché → IP vRack ; `ssh_host:` explicite → lui ; sinon le FQDN (DNS, et
  # clés d'hôte déjà connues sous ce nom).
  private def hostname(h : Beryl::Config::ResolvedHost, jumps : Array(String)) : String
    if !jumps.empty? && (ip = h.vrack_ips.first?)
      return ip
    end
    h.merged[YAML::Any.new("ssh_host")]?.try(&.as_s?) || h.fqdn
  end

  private def role(h : Beryl::Config::ResolvedHost, jumps : Array(String)) : String
    return "bastion" if h.bastion?
    return "via #{h.proxy_command}" if h.proxy_command
    return "public" if jumps.empty?
    "caché, via " + jumps.map { |j| j.rpartition('@').last.split('.').first }.join(", puis ")
  end

  private def short_alias?(h : Beryl::Config::ResolvedHost, shorts : Hash(String, Int32)) : Bool
    !h.short_name.includes?('.') && shorts[h.short_name] == 1
  end
end
