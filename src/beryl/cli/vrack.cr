require "option_parser"
require "../providers/ovh"
require "../apply"

module Beryl::CLI
  # `beryl vrack <host> [--attach]` : interroge l'API OVH pour savoir si le
  # serveur d'un host est dans un vRack, et le rattache avec `--attach`.
  #
  #   beryl vrack han.quimeo.net              # statut seulement
  #   beryl vrack han.quimeo.net --attach     # rattache (task async + suivi)
  #   beryl vrack han.quimeo.net --attach --vrack pn-12345
  module Vrack
    EXIT_OK         = 0
    EXIT_USAGE      = 1
    EXIT_FAIL       = 2
    EXIT_UNEXPECTED = 3

    POLL_INTERVAL = 5.seconds
    POLL_MAX      = 36 # ~3 min

    def self.run(config_root : String, args : Array(String)) : Int32
      attach = false
      forced_vrack : String? = nil
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl vrack <host> [--attach] [--vrack pn-XXXX]"
        p.on("--attach", "Rattache le serveur au vRack s'il ne l'est pas (task async)") { attach = true }
        p.on("--vrack NAME", "Forcer le vRack cible si le compte en a plusieurs") { |v| forced_vrack = v }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      raw = positional.first?
      unless raw
        STDERR.puts "beryl : host non précisé. USAGE : beryl vrack <host> [--attach]"
        return EXIT_USAGE
      end
      parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
      account_hint ||= parsed[:account]
      domain_hint ||= parsed[:domain]

      root = Beryl::Config::Root.load(config_root)
      host = root.resolve(parsed[:host], account_hint: account_hint, domain_hint: domain_hint)
      host.apply_all_credentials_to_env!

      service = host.ovh_service_name
      unless service
        STDERR.puts "beryl : pas de `ovh.service_name` pour #{host.fqdn} (provider ovh ?)."
        return EXIT_USAGE
      end

      provider = Beryl::Providers::Ovh.new
      unless provider.available?
        STDERR.puts "beryl : credentials OVH absents pour #{host.account_name} (cf. les credentials de la société)."
        return EXIT_USAGE
      end

      log "host #{host.fqdn} → service OVH #{service}"

      current = provider.vrack_of_server(service)
      if current
        log "✅ #{service} est DÉJÀ dans le vRack #{current}."
        unless attach
          finalize_vrack(root, host, current)
          # finalize_vrack a pu RÉÉCRIRE le host.yml (rotation, consolidation
          # name/ip). `root` est un snapshot mémoire du démarrage → on RECHARGE
          # depuis le disque pour que le bilan reflète l'état RÉEL du fichier.
          host = Beryl::Config::Root.load(config_root).resolve(
            parsed[:host], account_hint: account_hint, domain_hint: domain_hint)
        end
        warn_if_no_vrack_ip(host)
        return EXIT_OK
      end

      vracks = provider.list_vracks
      if vracks.empty?
        STDERR.puts "beryl : aucun vRack sur le compte. Commandez-en un dans le manager OVH (gratuit)."
        return EXIT_FAIL
      end
      log "#{service} dans aucun vRack. vRack(s) du compte : #{vracks.join(", ")}"

      unless attach
        hint = vracks.size > 1 ? " --vrack <pn-...>" : ""
        log "pour rattacher : beryl vrack #{raw} --attach#{hint}"
        return EXIT_OK
      end

      target = forced_vrack || (vracks.size == 1 ? vracks.first : nil)
      unless target
        STDERR.puts "beryl : plusieurs vRacks (#{vracks.join(", ")}) — précisez --vrack <pn-...>."
        return EXIT_USAGE
      end

      log "rattachement de #{service} au vRack #{target}…"
      task_id = provider.attach_dedicated_server(target, service)
      if task_id.empty?
        STDERR.puts "beryl : pas d'id de task retourné par l'API."
        return EXIT_FAIL
      end
      log "task #{task_id} créée — suivi (1-2 min)…"

      POLL_MAX.times do
        sleep POLL_INTERVAL
        status = provider.vrack_task_status(target, task_id)
        # nil = task purgée par OVH une fois terminée → on considère OK.
        if status.nil? || status == "done"
          log "✅ #{service} rattaché au vRack #{target}. L'interface privée (ix1) montera dans quelques minutes."
          log "ℹ le rattachement peut REDÉMARRER le serveur → si vous enchaînez un bootstrap, re-lancez d'abord `beryl rescue #{host.fqdn}`."
          warn_if_no_vrack_ip(host)
          return EXIT_OK
        end
        log "  task #{task_id} : #{status}"
        if status == "error" || status == "cancelled"
          STDERR.puts "beryl : la task de rattachement a échoué (#{status})."
          return EXIT_FAIL
        end
      end
      log "task #{task_id} toujours en cours après #{(POLL_INTERVAL * POLL_MAX).total_seconds.to_i}s — vérifiez le manager OVH."
      EXIT_OK
    rescue ex
      STDERR.puts "beryl : erreur vrack — #{ex.class}: #{ex.message}"
      STDERR.puts "  (refus d'accès /vrack ? Ré-autorisez la clé OVH : les droits ont changé, regénérez les credentials.)"
      EXIT_UNEXPECTED
    end

    # Rattacher côté OVH ne suffit pas : sans `vrack-interface` dans le
    # host.yml, le serveur n'a pas d'IP privée. On le vérifie et on rappelle
    # quoi ajouter (l'IP vient de ResolvedHost#vrack_ip).
    private def self.warn_if_no_vrack_ip(host : Beryl::Config::ResolvedHost) : Nil
      if ip = host.vrack_ip
        log "config OK : #{host.fqdn} déclare une IP vRack (#{ip})."
      else
        short = host.fqdn.split('.').first
        STDERR.puts
        STDERR.puts "⚠ #{host.fqdn} : rattaché au vRack côté OVH, mais le host.yml n'a PAS"
        STDERR.puts "  d'IP vRack → pas d'IP privée tant qu'on ne la déclare pas. Dans"
        STDERR.puts "  #{short}.host.yml :"
        STDERR.puts "      vrack:"
        STDERR.puts "        name: pn-XXXXXXX     # id du vRack chez OVH"
        STDERR.puts "        ip: 192.168.42.N"
        STDERR.puts "  puis : beryl vrack #{host.fqdn}"
      end
    end

    # Host confirmé dans le vRack : monte la 1ʳᵉ IP (netif) PUIS propose le
    # chooser réseau (TTY). Best-effort sur le netif (logue, n'avorte pas).
    private def self.finalize_vrack(root : Beryl::Config::Root, host : Beryl::Config::ResolvedHost, vrack_name : String? = nil) : Nil
      # Consolide le nom du vRack (id OVH) dans la section `vrack:` si on le
      # connaît et qu'il n'y est pas encore (pas d'invention : c'est l'id OVH).
      if vrack_name && host.vrack_name.nil?
        write_vrack(host, "name", vrack_name)
      end
      ips = host.vrack_ips
      if ips.size >= 2 && STDIN.tty?
        # PLUSIEURS IP déclarées → rotation (§5.2). On NE monte PAS « la 1ʳᵉ
        # seule » (netif retirerait la 2ᵉ) : la rotation gère les deux.
        if offer_rotation(host, ips.first, ips.last)
          # Rotation effectuée → l'IP primaire a changé et l'ancienne est
          # RETIRÉE de l'interface. L'objet `host` en mémoire est PÉRIMÉ (il
          # pointe encore l'ancienne IP) : on NE poursuit PAS vers le toggle 22,
          # qui se connecterait à l'IP disparue et bloquerait. Re-lancez `beryl
          # vrack` pour gérer le 22 sur la nouvelle IP (config rechargée).
          log "relancez `beryl vrack #{host.short_name}` pour (re)fermer le 22 sur la nouvelle IP."
          return
        end
      elsif ip = ips.first?
        mount_primary_vrack_ip(host)
        # Consolide l'IP dans la section vrack: (depuis le legacy
        # vrack-interface au besoin) → bloc vrack: complet. On NE touche
        # PAS si vrack.ip est déjà déclaré (peut être une LISTE).
        write_vrack(host, "ip", ip) unless host.vrack_declares_ip?
      end
      configure_vrack(root, host) if STDIN.tty?
    end

    # Chooser interactif du rôle RÉSEAU → écrit `vrack:` dans le host.yml.
    # N'ouvre la question QUE si le rôle est encore inconnu : `proxy_jump`/
    # `bastion` déjà posé = rôle déterminé → on ne re-pose rien (pour un host
    # caché, le seul reste utile est (re)fermer le 22 public).
    private def self.configure_vrack(root : Beryl::Config::Root, host : Beryl::Config::ResolvedHost) : Nil
      return if host.virtual
      if host.vrack_role_declared?
        # Rôle déjà connu → pas de chooser. Pour un host caché, on propose
        # l'action pf pertinente (fermer si ouvert, RÉ-OUVRIR si fermé).
        if pj = host.proxy_jump(connect_user(host))
          offer_22(host, pj)
        end
        return
      end
      bastions = bastion_hosts(root)
      STDERR.puts
      STDERR.puts "Rôle réseau de #{host.fqdn} (actuel : #{vrack_label(host)}) :"
      STDERR.puts "  1) ce host EST un bastion          → vrack.bastion: true"
      STDERR.puts "  2) joindre via un bastion          → vrack.proxy_jump"
      STDERR.puts "  3) pas de bastion (public)         → vrack.bastion: false"
      STDERR.puts "  0) ne rien changer"
      STDERR.print "Choix [0] : "
      case (STDIN.gets || "").strip
      when "1"
        write_vrack(host, "bastion", "true")
        write_vrack_remove(host, "proxy_jump") # un bastion n'a pas de proxy_jump
      when "3"
        write_vrack(host, "bastion", "false")
        write_vrack_remove(host, "proxy_jump")
      when "2"
        choose_via_bastion(host, bastions)
      else
        log "rôle réseau inchangé."
      end
    end

    # Hosts marqués bastion (`vrack.bastion: true` ou legacy), triés par nom.
    private def self.bastion_hosts(root : Beryl::Config::Root) : Array(Beryl::Config::ResolvedHost)
      root.all_hosts_by_fqdn.keys.compact_map do |fqdn|
        h = begin
          root.resolve(fqdn)
        rescue
          next
        end
        h.bastion? ? h : nil
      end.sort_by(&.fqdn)
    end

    private def self.vrack_label(host : Beryl::Config::ResolvedHost) : String
      return "EST un bastion" if host.bastion?
      if pj = host.proxy_jump(connect_user(host))
        return "caché via #{pj}"
      end
      "aucun / public"
    end

    private def self.choose_via_bastion(host : Beryl::Config::ResolvedHost, bastions : Array(Beryl::Config::ResolvedHost)) : Nil
      if bastions.empty?
        log "aucun host `vrack.bastion: true` — marquez-en un d'abord (choix 1 sur un z)."
        return
      end
      STDERR.puts "  Bastions disponibles :"
      bastions.each_with_index { |b, i| STDERR.puts "    #{i + 1}) #{b.short_name}  (#{b.fqdn})" }
      STDERR.print "  Lequel ? : "
      sel = (STDIN.gets || "").strip.to_i?
      unless sel && (1..bastions.size).includes?(sel)
        log "choix invalide — rien changé."
        return
      end
      bastion = bastions[sel - 1]
      pj = derive_proxy_jump(connect_user(host), bastion.short_name, host.domain_name)
      # Garde-fou §6 : on VÉRIFIE le chemin caché AVANT d'écrire proxy_jump.
      log "vérification du chemin caché : ssh #{pj} → #{host.vrack_ips.first?} → uname…"
      unless verify_via_bastion(host, pj)
        log "✗ #{host.fqdn} injoignable par #{pj}. L'IP vRack est-elle montée et le bastion OK ?"
        log "  proxy_jump NON écrit (rien changé)."
        return
      end
      write_vrack(host, "proxy_jump", pj)
      log "✓ chemin vérifié — proxy_jump posé."
      offer_close_22(host, pj)
    end

    # Pose/maj `vrack.<key>: value` dans le host.yml (préserve le reste).
    private def self.write_vrack(host : Beryl::Config::ResolvedHost, key : String, value : String) : Nil
      path = host.node.source_path
      File.write(path, upsert_vrack_field(File.read(path), key, value))
      log "#{host.fqdn} : vrack.#{key}: #{value} (#{File.basename(path)})"
    end

    # Retire `vrack.<key>` du host.yml (no-op si absent).
    private def self.write_vrack_remove(host : Beryl::Config::ResolvedHost, key : String) : Nil
      path = host.node.source_path
      before = File.read(path)
      after = remove_vrack_field(before, key)
      return if before == after
      File.write(path, after)
      log "#{host.fqdn} : vrack.#{key} retiré (#{File.basename(path)})"
    end

    # ─────────────────────────────────────────────────────────────
    # Écriture du bloc `vrack:` du host.yml (fonctions PURES sur le
    # contenu — testables sans SSH ni I/O). `beryl vrack` est la SEULE
    # porte qui pose `vrack.proxy_jump`/`vrack.bastion` (spec §6).
    # ─────────────────────────────────────────────────────────────

    # Pose/maj `key: value` dans le bloc `vrack:` (indenté 2 espaces),
    # en préservant le reste. Crée le bloc `vrack:` s'il est absent (avant
    # `apply_recipes:` si présent, sinon en fin). Retourne le nouveau contenu.
    def self.upsert_vrack_field(content : String, key : String, value : String) : String
      lines = content.split('\n')
      field = "  #{key}: #{value}"
      if net = lines.index { |l| l.rstrip == "vrack:" }
        i = net + 1
        while i < lines.size && lines[i].starts_with?("  ")
          if lines[i].lstrip.starts_with?("#{key}:")
            lines[i] = field
            return lines.join('\n')
          end
          i += 1
        end
        lines.insert(i, field) # fin du bloc vrack:
        return lines.join('\n')
      end
      if ar = lines.index { |l| l.starts_with?("apply_recipes:") }
        lines.insert(ar, "vrack:")
        lines.insert(ar + 1, field)
      else
        # Insérer AVANT d'éventuelles lignes vides finales (le `\n` terminal du
        # fichier) pour ne pas créer de ligne blanche parasite.
        pos = lines.size
        while pos > 0 && lines[pos - 1].empty?
          pos -= 1
        end
        lines.insert(pos, field)
        lines.insert(pos, "vrack:")
      end
      lines.join('\n')
    end

    # Retire `key:` du bloc `vrack:` (et le bloc s'il devient vide).
    # No-op si absent. Retourne le nouveau contenu.
    def self.remove_vrack_field(content : String, key : String) : String
      lines = content.split('\n')
      net = lines.index { |l| l.rstrip == "vrack:" }
      return content unless net
      i = net + 1
      while i < lines.size && lines[i].starts_with?("  ")
        if lines[i].lstrip.starts_with?("#{key}:")
          lines.delete_at(i)
          # Bloc vrack: vide (plus d'enfant indenté juste après) → on le retire.
          if net + 1 >= lines.size || !lines[net + 1].starts_with?("  ")
            lines.delete_at(net)
          end
          return lines.join('\n')
        end
        i += 1
      end
      content
    end

    # ─────────────────────────────────────────────────────────────
    # Orchestration serveur (SSH). PARTIES SÛRES seulement : monter l'IP
    # (netif) et VÉRIFIER le chemin caché. AUCUNE fermeture du 22 ici → le
    # lockout est impossible. La phase pf (fermeture du 22) viendra à part,
    # avec validation in-vivo.
    # ⚠ Ces helpers exécutent du SSH réel → à valider sur un host de test.
    # ─────────────────────────────────────────────────────────────

    # User de connexion SSH : le PREMIER user sudo-capable de `freebsd.users`
    # (le SSH root est coupé sur les hôtes durcis), à défaut `host.user`.
    # Aligné sur `beryl apply` (sinon on tenterait `root` → injoignable).
    private def self.connect_user(host : Beryl::Config::ResolvedHost) : String
      freebsd = host.merged[YAML::Any.new("freebsd")]?.try(&.as_h?)
      if freebsd && (users = freebsd[YAML::Any.new("users")]?.try(&.as_a?))
        users.each do |u|
          uh = u.as_h?
          next unless uh
          name = uh[YAML::Any.new("name")]?.try(&.as_s?)
          next unless name
          wheel = uh[YAML::Any.new("groups")]?.try(&.as_a?).try(&.any? { |g| g.as_s? == "wheel" }) || false
          sudo = uh[YAML::Any.new("sudo")]?.try(&.as_bool?) == true
          return name if wheel || sudo
        end
      end
      host.user
    end

    # Connexion sudo-capable vers le host (même logique que `beryl apply` :
    # user sudo-capable, escalade SudoShell si non-root). nil si injoignable / sudo KO.
    private def self.network_shell(host : Beryl::Config::ResolvedHost) : Beryl::Apply::Shell?
      cu = connect_user(host)
      conn = host.connection(cu)
      uname = conn.exec("uname -s", raise_on_error: false).stdout.strip
      unless uname == "FreeBSD"
        log "✗ #{host.fqdn} injoignable ou pas FreeBSD (uname = #{uname.inspect})."
        return nil
      end
      return Beryl::Apply::SshShell.new(conn) if cu == "root"
      unless conn.exec("sudo -n true", raise_on_error: false).success?
        log "✗ #{cu}@#{host.fqdn} ne peut pas sudo sans mot de passe."
        return nil
      end
      Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(conn))
    end

    # Monte la 1ʳᵉ IP vRack sur l'interface (primitive `netif`, idempotente,
    # persistante). SÛR : ajoute une IP, ne ferme rien. true si OK.
    private def self.mount_primary_vrack_ip(host : Beryl::Config::ResolvedHost) : Bool
      ip = host.vrack_ips.first?
      return false unless ip
      shell = network_shell(host)
      return false unless shell
      result = run_netif(shell, ip)
      log "netif #{ip} : #{result.outcome} — #{result.message}"
      !result.outcome.failed?
    end

    # Lance la primitive `netif` (auto-détection d'interface) sur `shell`.
    # `alias_mode` → ajoute l'IP en alias transitoire (sans retirer les autres).
    private def self.run_netif(shell : Beryl::Apply::Shell, ip : String, alias_mode : Bool = false) : Beryl::Apply::StepResult
      params = {"iface" => YAML::Any.new("auto"), "ip" => YAML::Any.new(ip)}
      params["alias"] = YAML::Any.new(true) if alias_mode
      Beryl::Apply::Primitive["netif"]?.not_nil!.apply(shell, params, false, Beryl::Apply::Context.new)
    end

    # Rotation d'IP vRack (spec §5.2), en 2 temps, ANTI-LOCKOUT. Appelée quand
    # `vrack.ip` est une LISTE — on migre vers la DERNIÈRE IP et on
    # retire les autres. Jamais retirer l'ancienne avant d'avoir PROUVÉ la
    # nouvelle. Idempotent : ré-exécutable (reprend ou constate que c'est fini).
    private def self.rotate_vrack_ip(host : Beryl::Config::ResolvedHost, old_ip : String, new_ip : String) : Bool
      shell = network_shell(host)
      return false unless shell
      pj = host.proxy_jump(connect_user(host))

      if pj.nil?
        # Host PUBLIC : beryl se connecte par le FQDN public → changer l'IP vRack
        # ne coupe rien. On promeut directement (netif retire l'ancienne).
        r = run_netif(shell, new_ip)
        log "netif #{new_ip} : #{r.outcome} — #{r.message}"
        return false if r.outcome.failed?
        write_vrack(host, "ip", new_ip)
        log "✓ rotation #{old_ip} → #{new_ip} (host public)."
        return true
      end

      # Host CACHÉ : danse en 2 temps.
      # 1. Monter la nouvelle IP en ALIAS (les deux vivantes).
      r = run_netif(shell, new_ip, alias_mode: true)
      log "alias #{new_ip} : #{r.outcome} — #{r.message}"
      return false if r.outcome.failed?
      # 2. Vérifier la nouvelle IP joignable PAR LE BASTION (avant tout retrait).
      unless verify_via_bastion(host, pj, new_ip)
        log "✗ #{new_ip} injoignable par le bastion — rotation ANNULÉE (rien retiré)."
        return false
      end
      log "✓ #{new_ip} joignable par le bastion."
      # 3. Promouvoir la nouvelle + retirer l'ancienne, VIA une connexion à la
      #    NOUVELLE IP (la session passe par elle → retirer l'ancienne ne coupe pas).
      shell_new = bastion_shell(host, pj, new_ip)
      unless shell_new
        log "✗ connexion via #{new_ip} impossible — rotation ANNULÉE."
        return false
      end
      r = run_netif(shell_new, new_ip) # pose new primaire, retire old
      log "netif #{new_ip} (primaire) : #{r.outcome} — #{r.message}"
      return false if r.outcome.failed?
      # 4. Config : vrack.ip redevient SCALAIRE = nouvelle IP.
      write_vrack(host, "ip", new_ip)
      log "✓ rotation #{old_ip} → #{new_ip} terminée ; #{old_ip} retiré."
      true
    end

    # Propose (TTY) la rotation quand plusieurs IP sont déclarées. Retourne
    # `true` si une rotation a EFFECTIVEMENT eu lieu (IP primaire changée).
    private def self.offer_rotation(host : Beryl::Config::ResolvedHost, old_ip : String, new_ip : String) : Bool
      STDERR.puts
      STDERR.puts "#{host.fqdn} : #{host.vrack_ips.size} IP vRack déclarées (#{host.vrack_ips.join(", ")})."
      STDERR.print "Migrer vers #{new_ip} (monte #{new_ip}, vérifie, retire #{old_ip}) ? [o/N] : "
      unless (STDIN.gets || "").strip.downcase == "o"
        log "rotation laissée en attente (les IP restent déclarées)."
        return false
      end
      rotate_vrack_ip(host, old_ip, new_ip)
    end

    # Vérifie le chemin CACHÉ : `ssh <proxy_jump> → vrack_ip[0] → uname`.
    # Lecture seule (aucune écriture). true si le host répond FreeBSD par le
    # bastion. C'est le garde-fou avant d'écrire `proxy_jump` (spec §6).
    private def self.verify_via_bastion(host : Beryl::Config::ResolvedHost, proxy_jump : String, ip : String? = nil) : Bool
      target = ip || host.vrack_ips.first?
      return false unless target
      conn = SSH::Connection.new(
        host: target,
        user: connect_user(host),
        port: host.port,
        identity_file: host.identity_file,
        options: {"ProxyJump" => proxy_jump, "ConnectTimeout" => "10"},
      )
      conn.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
    end

    # Shell sudo-capable connecté EXPLICITEMENT par le bastion (host = vrack_ip,
    # ProxyJump = pj). C'est le chemin vRack → fermer le 22 PUBLIC via ce shell
    # ne coupe PAS la session (anti-lockout, spec §4). nil si injoignable / sudo KO.
    private def self.bastion_shell(host : Beryl::Config::ResolvedHost, pj : String, ip : String? = nil) : Beryl::Apply::Shell?
      target = ip || host.vrack_ips.first?
      return nil unless target
      cu = connect_user(host)
      conn = SSH::Connection.new(
        host: target, user: cu, port: host.port,
        identity_file: host.identity_file, options: {"ProxyJump" => pj, "ConnectTimeout" => "10"},
      )
      return nil unless conn.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
      return Beryl::Apply::SshShell.new(conn) if cu == "root"
      return nil unless conn.exec("sudo -n true", raise_on_error: false).success?
      Beryl::Apply::SudoShell.new(Beryl::Apply::SshShell.new(conn))
    end

    # Ferme le 22 PUBLIC (pf), avec FILET anti-lockout. À n'appeler qu'après que
    # `proxy_jump` est VÉRIFIÉ. Séquence sûre :
    #   1. (re)connexion PAR LE BASTION (vRack) → fermer le 22 public ne coupe pas ;
    #   2. dead-man switch : dans 120s, `pfctl -d` (rollback) SAUF si flag de commit ;
    #   3. pose des règles pf éprouvées (= recette sshd-vrack-only) + recharge ;
    #   4. re-vérif joignabilité par le bastion → commit (touch flag) ou rollback.
    private def self.close_public_22(host : Beryl::Config::ResolvedHost, pj : String) : Bool
      shell = bastion_shell(host, pj)
      unless shell
        log "✗ injoignable PAR LE BASTION — on ne ferme PAS le 22 (anti-lockout)."
        return false
      end
      close_public_22_on(shell, host)
    end

    # Cœur de la fermeture, sur un shell DÉJÀ établi PAR LE BASTION (réutilisé
    # par `offer_22`). Le shell EST la connexion vRack → fermer le 22 public ne
    # coupe pas la session (anti-lockout, spec §4).
    private def self.close_public_22_on(shell : Beryl::Apply::Shell, host : Beryl::Config::ResolvedHost) : Bool
      ip = host.vrack_ips.first?
      return false unless ip
      subnet = derive_subnet(ip)
      # `flags any` sur le pass : laisse passer les paquets MID-STREAM (pas que
      # les SYN) → la connexion DÉJÀ établie (par le bastion) survit au reload pf
      # (sinon ses paquets non-SYN sont jetés → blocage ~120s → faux lockout).
      pfconf = "# Généré par beryl vrack — NE PAS éditer à la main.\n" \
               "set skip on lo\n" \
               "pass in quick inet proto tcp from #{subnet} to port 22 flags any\n" \
               "block in quick proto tcp to port 22\n"

      shell.exec("rm -f /tmp/beryl-pf-committed", raise_on_error: false)
      # `daemon -f` détache PROPREMENT (session propre, fds → /dev/null) → ne
      # bloque pas la connexion SSH multiplexée (contrairement à `nohup … &`).
      shell.exec(
        "daemon -f /bin/sh -c 'sleep 120; [ -f /tmp/beryl-pf-committed ] || pfctl -d'",
        raise_on_error: false)
      log "filet dead-man armé : pf se DÉSACTIVE dans 120s si on perd la main."

      log "→ écriture /etc/pf.conf…"
      shell.write_file("/etc/pf.conf", pfconf, mode: "0644")
      log "→ sysrc pf_enable=YES…"
      shell.exec("sysrc pf_enable=YES", raise_on_error: false)
      log "→ pfctl -f (charge les règles)…"
      shell.exec("pfctl -f /etc/pf.conf", raise_on_error: false)
      log "→ pfctl -e (active pf, idempotent)…"
      shell.exec("pfctl -e", raise_on_error: false)
      log "pf chargé : 22 PUBLIC bloqué, vRack #{subnet} autorisé."

      # Vérif via la connexion EXISTANTE (`shell`, déjà établie par le bastion,
      # état gardé par pf) : si MA session a survécu à la fermeture, on n'est pas
      # lockout. On NE rouvre PAS de connexion neuve (son SYN se ferait jeter
      # brièvement après le reload pf → ~120s de retransmission TCP).
      if shell.exec("uname -s", raise_on_error: false).stdout.strip == "FreeBSD"
        shell.exec("touch /tmp/beryl-pf-committed", raise_on_error: false) # commit
        log "✓ session toujours vivante après fermeture → 22 public FERMÉ (commité, dead-man annulé)."
        true
      else
        log "✗ session COUPÉE après fermeture → le dead-man va ROLLBACK (pfctl -d) sous 120s."
        log "  rien commité ; vérifiez la config réseau puis recommencez."
        false
      end
    end

    # Dérive la chaîne `proxy_jump` `<user>@<bastion-fqdn>` depuis le nom (court
    # OU FQDN) du bastion et le domaine du host caché. Pur.
    def self.derive_proxy_jump(connect_user : String, bastion : String, domain : String) : String
      host = bastion.includes?('.') ? bastion : "#{bastion}.#{domain}"
      "#{connect_user}@#{host}"
    end

    # Dérive le /24 d'une IP (ex. 192.168.42.31 → 192.168.42.0/24). Pur.
    def self.derive_subnet(ip : String) : String
      p = ip.split('.')
      return ip unless p.size == 4
      "#{p[0]}.#{p[1]}.#{p[2]}.0/24"
    end

    # Propose (TTY) de fermer le 22 PUBLIC maintenant. Défaut = NON (sûr).
    # Utilisé au PREMIER paramétrage (le 22 est forcément ouvert).
    private def self.offer_close_22(host : Beryl::Config::ResolvedHost, pj : String) : Nil
      STDERR.print "Fermer le port 22 PUBLIC maintenant (pf, filet anti-lockout) ? [o/N] : "
      unless (STDIN.gets || "").strip.downcase == "o"
        log "22 public laissé OUVERT — relancez `beryl vrack` pour fermer plus tard."
        return
      end
      close_public_22(host, pj)
    end

    # Host DÉJÀ caché (re-run) : propose l'action pf PERTINENTE selon l'état
    # RÉEL du 22 vu du host — ouvert → propose de fermer (filet anti-lockout) ;
    # fermé → propose de RÉ-OUVRIR (dépannage). Une seule connexion par le
    # bastion sert la détection ET l'action. Défaut = NON dans les deux cas.
    private def self.offer_22(host : Beryl::Config::ResolvedHost, pj : String) : Nil
      shell = bastion_shell(host, pj)
      unless shell
        log "✗ injoignable par le bastion — état du 22 inconnu, on n'y touche pas."
        return
      end
      if public_22_closed_on?(shell)
        STDERR.print "Le 22 PUBLIC est FERMÉ. Le RÉ-OUVRIR (désactive pf) ? [o/N] : "
        unless (STDIN.gets || "").strip.downcase == "o"
          log "22 public laissé FERMÉ."
          return
        end
        reopen_public_22_on(shell, host)
      else
        STDERR.print "Le 22 PUBLIC est OUVERT. Le FERMER (pf, filet anti-lockout) ? [o/N] : "
        unless (STDIN.gets || "").strip.downcase == "o"
          log "22 public laissé OUVERT."
          return
        end
        close_public_22_on(shell, host)
      end
    end

    # État du 22 PUBLIC vu du host : FERMÉ ssi pf est ACTIF ET porte une règle
    # de blocage du port 22 (sinon ouvert). Lecture seule. ⚠ `pfctl -sr` rend
    # le port par son NOM de service (`/etc/services`) → le 22 s'affiche
    # `port = ssh`, pas `port = 22` : on reconnaît les deux formes.
    private def self.public_22_closed_on?(shell : Beryl::Apply::Shell) : Bool
      return false unless shell.exec("pfctl -si 2>/dev/null", raise_on_error: false).stdout.includes?("Status: Enabled")
      rules = shell.exec("pfctl -sr 2>/dev/null", raise_on_error: false).stdout
      rules.each_line.any? do |l|
        l.includes?("block") && (l.includes?("port = ssh") || l.includes?("port = 22"))
      end
    end

    # Ré-ouvre le 22 PUBLIC : désactive pf (immédiat) + persiste (`pf_enable=NO`)
    # pour que le redémarrage ne le referme pas. SÛR : ouvre l'accès, aucun
    # lockout possible. `beryl vrack` le refermera au besoin.
    private def self.reopen_public_22_on(shell : Beryl::Apply::Shell, host : Beryl::Config::ResolvedHost) : Bool
      shell.exec("pfctl -d", raise_on_error: false)
      shell.exec("sysrc pf_enable=NO", raise_on_error: false)
      log "✓ 22 public RÉ-OUVERT (pf désactivé, pf_enable=NO). Relancez `beryl vrack` pour le refermer."
      true
    end

    private def self.log(message : String) : Nil
      STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl vrack] #{message}"
    end
  end
end
