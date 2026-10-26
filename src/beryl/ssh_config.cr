require "./config"

# Accès SSH « à la main » aux hosts CACHÉS derrière le vRack (port 22 public
# fermé, `sshd-vrack-only`) : un fichier `~/.ssh/beryl.conf`, inclus en tête
# de `~/.ssh/config`, donne pour chacun son IP vRack et un `ProxyCommand` qui
# essaie son bastion préféré puis les autres (`ResolvedHost#proxy_jumps`) —
# même repli que les connexions de beryl. Les sauts lisent VOTRE config ssh
# (clé, agent) comme un `ssh` ordinaire.
module Beryl::SshConfig
  extend self

  FILE_NAME = "beryl.conf"
  # Ligne ajoutée en tête de `~/.ssh/config` (chemin relatif à `~/.ssh`).
  INCLUDE_LINE = "Include #{FILE_NAME}"
  # Délai par bastion avant de passer au suivant.
  JUMP_TIMEOUT = 5

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

  # Contenu de `beryl.conf` pour les hosts cachés, triés par FQDN. Le bloc
  # FQDN ne pose QUE l'adresse et le rebond (user, clé : ceux de votre
  # config, ex. `Host *.example.net`) ; le nom court, qu'aucun motif ne
  # couvre, porte aussi user et clé — sauf s'il est ambigu (deux sociétés).
  def render(hosts : Array(Beryl::Config::ResolvedHost)) : String
    hidden = hosts.select { |h| !h.proxy_jumps(h.connect_user).empty? && h.vrack_ips.first? }.sort_by(&.fqdn)
    shorts = hidden.map(&.short_name).tally
    String.build do |io|
      io << "# Généré par `beryl ssh-config --apply` — ne pas modifier à la main.\n"
      io << "# Hosts cachés derrière le vRack : IP vRack + bastion préféré, puis replis.\n"
      hidden.each do |h|
        jumps = h.proxy_jumps(h.connect_user)
        ip = h.vrack_ips.first
        hop = jump_line(jumps)
        io << "\n# " << h.fqdn << " — via " << jumps.map { |j| j.rpartition('@').last.split('.').first }.join(", puis ") << "\n"
        io << "Host " << h.fqdn << "\n"
        io << "  HostName " << ip << "\n"
        io << "  " << hop << "\n"
        next if h.short_name.includes?('.') || shorts[h.short_name] > 1
        io << "Host " << h.short_name << "\n"
        io << "  HostName " << ip << "\n"
        io << "  User " << h.connect_user << "\n"
        if key = h.identity_file
          io << "  IdentityFile " << key << "\n"
          io << "  IdentitiesOnly yes\n"
        end
        io << "  " << hop << "\n"
      end
    end
  end

  # `~/.ssh/config` avec l'`Include` en tête, ou nil s'il y est déjà. En
  # tête : hors de tout bloc `Host` (un `Include` dedans n'y vaudrait que
  # pour ce bloc), et premières valeurs lues = celles qui l'emportent. Pur.
  def with_include(config : String) : String?
    return if config.each_line.any? { |l| l.strip == INCLUDE_LINE }
    "# Hosts cachés derrière le vRack (fichier généré par beryl ssh-config)\n#{INCLUDE_LINE}\n\n#{config}"
  end

  private def jump_line(jumps : Array(String)) : String
    return "ProxyJump #{jumps.first}" if jumps.size == 1
    "ProxyCommand #{proxy_command(jumps)}"
  end
end
