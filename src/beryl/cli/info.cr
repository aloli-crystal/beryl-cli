require "option_parser"
require "../apply"
require "./apply" # Beryl::CLI::Apply.recipes_search_path (paquets gérés par recettes)

module Beryl::CLI
  # `beryl info [host] [--usage]` : inventaire des serveurs.
  #   - sans host  : tableau récap de TOUS les hosts (gamme, CPU, RAM, disques)
  #                  + total parc. Lecture HORS-LIGNE (depuis les host.yml
  #                  alimentés par `beryl scan` — instantané, pas de réseau).
  #   - avec host  : fiche détaillée d'un host.
  #   - --usage    : utilisation LIVE (zpool/df/uptime via SSH) en plus.
  module Info
    EXIT_OK    = 0
    EXIT_USAGE = 1

    def self.run(config_root : String, args : Array(String)) : Int32
      usage = false
      system_ssh = false
      refresh = false
      adoc = false
      html = false
      versions = false
      updates = false
      all_pkgs = false
      adoc_name : String? = nil
      account_hint : String? = nil
      domain_hint : String? = nil
      positional = [] of String

      # OptionParser ne gère pas l'argument OPTIONNEL d'un flag : on extrait
      # `--adoc=NOM` AVANT le parse, et on laisse `--adoc` nu à OptionParser.
      args = args.reject do |a|
        if a.starts_with?("--adoc=")
          adoc = true
          v = a.split('=', 2)[1]
          adoc_name = v unless v.empty? # `--adoc=` (vide) → stdout, pas un fichier ".adoc"
          true
        else
          false
        end
      end

      parser = OptionParser.new do |p|
        p.banner = "USAGE : beryl info [host] [--usage [--system-ssh]] [--adoc[=NOM]|--html]\n" \
                   "        beryl info --versions [--all-pkgs] [société|domaine]   (matrice serveurs × paquets, live)\n" \
                   "        beryl info --updates [société|domaine]                 (versions dispo vs installées, recettes)\n" \
                   "        beryl info --refresh [société|domaine]                 (MAJ specs via API OVH)"
        p.on("--usage", "Utilisation LIVE (zpool/df via SSH)") { usage = true }
        p.on("--system-ssh", "Pour --usage : utilise VOTRE ssh (~/.ssh/config + agent) au lieu de la clé beryl") { system_ssh = true }
        p.on("--adoc", "Document AsciiDoc sur stdout ; `--adoc=NOM` → écrit NOM.adoc, le convertit en PDF (crystal-asciidoctor-pdf) et l'ouvre") { adoc = true }
        p.on("--html", "Génère un site HTML triable dans <config>/<scope>/info/ (index + 1 page par serveur)") { html = true }
        p.on("--refresh", "Rafraîchit gamme + specs + prix via l'API OVH (écrit les host.yml, SANS SSH)") { refresh = true }
        p.on("--versions", "Tableau LIVE des versions de paquets (serveurs en colonnes, paquets en lignes)") { versions = true }
        p.on("--updates", "Pour les paquets des recettes : version DISPONIBLE au dépôt vs installée (retards)") { updates = true }
        p.on("--all-pkgs", "Avec --versions : TOUS les paquets installés (défaut : seulement ceux des recettes)") { all_pkgs = true }
        p.on("-a NAME", "--account=NAME", "Forcer la société") { |v| account_hint = v }
        p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
        p.on("-h", "--help", "Aide") { puts p; exit 0 }
        p.unknown_args { |rest, _| positional = rest }
      end
      parser.parse(args)

      root = Beryl::Config::Root.load(config_root)
      return refresh_metadata(root, positional.first?) if refresh
      if versions
        return render_pkg_versions(config_root, root, positional.first?, all_pkgs, system_ssh)
      end
      if updates
        return render_pkg_updates(config_root, root, positional.first?, system_ssh)
      end
      if html
        hosts = scoped_hosts(root, positional.first?)
        usage_map, os_map = usage ? gather_usage_map(hosts, system_ssh) : {nil, nil}
        return render_html_site(config_root, positional.first?, hosts, usage_map, os_map)
      end
      if adoc
        hosts = scoped_hosts(root, positional.first?)
        usage_map, os_map = usage ? gather_usage_map(hosts, system_ssh) : {nil, nil}
        doc = build_adoc(hosts, positional.first?, usage_map, os_map)
        return render_adoc_pdf(doc, adoc_name) if adoc_name
        puts doc
        return EXIT_OK
      end

      if raw = positional.first?
        parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
        host = root.resolve(parsed[:host],
          account_hint: account_hint || parsed[:account],
          domain_hint: domain_hint || parsed[:domain])
        show_host(host, usage, system_ssh)
      else
        show_all(root, usage)
      end
      EXIT_OK
    rescue ex : Beryl::Config::Root::HostNotFound | Beryl::Config::Root::AmbiguousHost
      STDERR.puts "beryl : #{ex.message}"
      EXIT_USAGE
    end

    # Tableau récap de tous les hosts + total parc.
    private def self.show_all(root : Beryl::Config::Root, usage : Bool) : Nil
      hosts = root.all_hosts_by_fqdn.keys.sort.compact_map do |fqdn|
        begin
          root.resolve(fqdn)
        rescue
          nil
        end
      end

      header = ["HOST", "GAMME", "CPU", "RAM", "DISQUES"]
      rows = hosts.map do |h|
        hw = h.hardware
        [
          h.short_name,
          h.ovh_commercial_name || "—",
          hw ? "#{hw.cores}c/#{hw.threads}t" : "(non scanné)",
          hw ? "#{hw.ram_gb} Go" : "—",
          hw ? (hw.disks.empty? ? "—" : hw.disks.join(" + ")) : "—",
        ]
      end
      print_table(header, rows)

      scanned = hosts.count(&.hardware)
      puts
      puts "#{hosts.size} host(s) — #{scanned} scanné(s), #{hosts.size - scanned} à scanner."
      if usage
        puts
        puts "ℹ --usage est ignoré sans host précis : `beryl info <host> --usage`."
      end
    end

    # Fiche détaillée d'un host (specs hors-ligne + utilisation live si --usage).
    private def self.show_host(host : Beryl::Config::ResolvedHost, usage : Bool, system_ssh : Bool) : Nil
      # Si --usage, on collecte AVANT d'afficher la fiche : l'OS LIVE (uname -sr)
      # remplace alors l'`os:` théorique du YAML (avec version + patch).
      res = usage ? gather_usage(host, system_ssh) : nil
      live_os = res.try(&.os)
      puts "host:           #{host.fqdn}"
      puts "provider:       #{host.provider || "—"}"
      puts "service_name:   #{host.ovh_service_name || host.scaleway_server_id || "—"}"
      puts "gamme:          #{host.ovh_commercial_name || "—"}"
      puts "baie (rack):    #{host.ovh_rack || "—"}"
      puts "prix/mois:      #{host.ovh_price ? "#{host.ovh_price} €" : "—"}"
      puts "ipv4 publique:  #{host.ovh_ipv4 || "—"}"
      puts "ipv6 publique:  #{host.ovh_ipv6 || "—"}"
      puts "ip vRack:       #{host.vrack_ip || "—"}"
      puts "os:             #{live_os ? "#{live_os} (live)" : host.os}"
      if hw = host.hardware
        puts "cpu:            #{hw.cpu} (#{hw.cores}c/#{hw.threads}t)"
        puts "ram:            #{hw.ram_gb} Go"
        puts "raid:           #{hw.raid || "aucun (RAID logiciel/ZFS)"}"
        puts "disques (provider) :"
        hw.disks.each { |d| puts "  - #{d}" }
      else
        puts "(host non scanné — lancez `beryl scan #{host.fqdn}` pour les specs/disques)"
      end

      return unless res
      puts
      puts "utilisation (live#{system_ssh ? ", via votre ssh" : ""}) :"
      display_usage(res, host, system_ssh)
    end

    # Affiche l'utilisation disque LIVE d'un host (table) à partir d'un résultat
    # déjà collecté. En cas d'échec, on DÉTAILLE la raison par utilisateur tenté
    # (auth, timeout, DNS…) plutôt qu'un « injoignable » muet.
    private def self.display_usage(res : UsageResult, host : Beryl::Config::ResolvedHost, system_ssh : Bool) : Nil
      if rows = res.rows
        if rows.empty?
          puts "  (connecté en #{res.via}, mais aucun volume détecté)"
        else
          print_table(["VOLUME", "TAILLE", "UTILISÉ", "LIBRE", "% LIBRE"],
            rows.map { |r| [r.label, r.size, r.used, r.free, r.pct] })
        end
        return
      end
      puts "  ✗ utilisation indisponible :"
      res.notes.each { |n| puts "    · #{n}" }
      if !system_ssh && (diag = host.ssh_key_diagnostic)
        puts "    ⚠️  #{diag}"
      end
      puts "    → ajoutez --system-ssh pour passer par VOTRE ssh (clé perso)." unless system_ssh
    end

    # Utilisation disque normalisée (une ligne par volume).
    record UsageRow, label : String, size : String, used : String, free : String, pct : String

    # Issue d'une collecte d'usage : `rows` = volumes (nil si aucun user n'a
    # répondu) ; `via` = user qui a réussi ; `notes` = raison d'échec par user ;
    # `os` = OS LIVE déduit du serveur (`uname -sr`, ex. « FreeBSD 15.0-RELEASE-p10 »).
    record UsageResult, rows : Array(UsageRow)?, via : String?, notes : Array(String), os : String? = nil

    # Sortie brute d'une commande distante (lecture seule).
    record Probe, ok : Bool, stdout : String, stderr : String

    # Tentatives de connexion `{user, cible}` ordonnées :
    #   - `--system-ssh` : on IMITE `ssh <fqdn>` — on vise le FQDN et on laisse
    #     VOTRE `~/.ssh/config` résoudre user/hostname/proxyjump. user `nil` = login
    #     par défaut (1ʳᵉ tentative), puis `deploy` en repli (hosts beryl).
    #   - clé beryl : on vise l'hôte SSH réel (service name / IP vRack) en
    #     `connect_user` (admin…) puis `deploy`.
    def self.usage_attempts(host : Beryl::Config::ResolvedHost, system_ssh : Bool) : Array({String?, String})
      # Host CACHÉ derrière le vRack : aucune route publique (port 22 fermé).
      # On vise l'IP vRack (= ssh_host) via le ProxyJump du bastion (ajouté par
      # `remote`), en connect_user puis deploy — dans les DEUX modes. `--system-ssh`
      # par FQDN ne marcherait pas : le FQDN public ne répond pas.
      if host.hidden?
        return [host.connect_user, "deploy"].uniq.map { |u| {u.as(String?), host.ssh_host} }
      end
      # Route directe : on PRÉFÈRE le FQDN logique (ex. ke.example.net, qui résout
      # en DNS public et que vous joignez à la main) et on BASCULE sur le nom OVH
      # (service_name) en repli s'il diffère. Un `ssh_host:` explicite est respecté
      # tel quel (pas de FQDN deviné).
      targets = host.ssh_host_is_provider_name? ? [host.fqdn, host.ssh_host] : [host.ssh_host]
      users = system_ssh ? [nil.as(String?), "deploy".as(String?)] : [host.connect_user, "deploy"].uniq.map(&.as(String?))
      targets.flat_map { |t| users.map { |u| {u, t} } }
    end

    # Récupère l'utilisation disque EN LIVE (best-effort). Tente chaque
    # `{user, cible}` ; `zpool list` sinon `df -h` (sans sudo). Garde la raison
    # d'échec de chaque tentative qui n'a pas répondu.
    #
    # PAS de `2>/dev/null` : le shell de login distant peut être csh (défaut
    # FreeBSD pour `admin`), qui ne comprend PAS la redirection Bourne `2>` et
    # passerait `2` en argument (`uname 2` → « usage: uname »). On capture déjà
    # stderr séparément dans le Probe, donc la redirection est inutile.
    private def self.gather_usage(host : Beryl::Config::ResolvedHost, system_ssh : Bool) : UsageResult
      notes = [] of String
      usage_attempts(host, system_ssh).each do |user, target|
        dest = user ? "#{user}@#{target}" : target
        # `uname -sr` sert À LA FOIS de test d'accès ET de détection OS (nom +
        # version + patch, ex. « FreeBSD 15.0-RELEASE-p10 »). csh-safe (pas de redir).
        pr = remote(host, user, target, "uname -sr", system_ssh)
        unless pr.ok && !pr.stdout.strip.empty? # injoignable / auth KO → tentative suivante
          notes << "#{dest} : #{ssh_reason(pr)}"
          next
        end
        os = pr.stdout.strip
        zp = remote(host, user, target, "zpool list -H -o name,size,alloc,free,cap", system_ssh).stdout.strip
        rows = zp.empty? ? parse_df(remote(host, user, target, "df -h", system_ssh).stdout) : parse_zpool(zp)
        return UsageResult.new(sort_volumes(rows), dest, notes, os)
      end
      UsageResult.new(nil, nil, notes)
    end

    # Distille le stderr SSH en une cause courte et lisible.
    private def self.ssh_reason(pr : Probe) : String
      e = pr.stderr.downcase
      if e.includes?("permission denied")
        "auth refusée (clé beryl non installée ?)"
      elsif e.includes?("timed out") || e.includes?("timeout")
        "timeout (injoignable — derrière le vRack ?)"
      elsif e.includes?("could not resolve") || e.includes?("name or service not known")
        "DNS introuvable"
      elsif e.includes?("connection refused")
        "connexion refusée (sshd absent / mauvais port ?)"
      elsif e.includes?("no route to host")
        "pas de route"
      else
        pr.stderr.each_line.map(&.strip).reject(&.empty?).first? || "échec ssh"
      end
    end

    # Exécute une commande LECTURE SEULE sur `target` en tant que `user`
    # (`nil` = login par défaut de votre ssh).
    #   - `system_ssh` → shelle vers `ssh` SANS rien forcer d'autre que les
    #     timeouts : c'est VOTRE `~/.ssh/config` (+ agent) qui résout user, vrai
    #     hostname et ProxyJump — on imite `ssh <fqdn>`.
    #   - sinon → SSH HERMÉTIQUE de beryl (sa clé + son ProxyJump dérivé).
    # ConnectTimeout=10s pour ne pas pendouiller. Renvoie TOUJOURS un Probe.
    private def self.remote(host : Beryl::Config::ResolvedHost, user : String?, target : String, cmd : String, system_ssh : Bool) : Probe
      if system_ssh
        args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"]
        # Host caché derrière le vRack : rebond par le bastion. nil pour les
        # hosts à route directe (proxy_jump renvoie nil → pas d'option ajoutée).
        if pj = host.proxy_jump(user)
          args << "-o" << "ProxyJump=#{pj}"
        end
        args << (user ? "#{user}@#{target}" : target) << cmd
        obuf = IO::Memory.new
        ebuf = IO::Memory.new
        st = Process.run("ssh", args, output: obuf, error: ebuf)
        Probe.new(st.success?, obuf.to_s, ebuf.to_s)
      else
        eff_user = user || host.connect_user
        opts = {"ConnectTimeout" => "10"}
        if pj = host.proxy_jump(eff_user)
          opts["ProxyJump"] = pj
        end
        conn = SSH::Connection.new(host: target, user: eff_user, port: host.port,
          identity_file: host.identity_file, options: opts)
        res = conn.exec(cmd, raise_on_error: false)
        Probe.new(res.success?, res.stdout, res.stderr)
      end
    rescue ex
      Probe.new(false, "", ex.message || "erreur de connexion")
    end

    # ─── Versions de paquets (--versions / --updates) ───────────────────────

    # Paquets « gérés » = union des `packages:` des steps `pkg-install` de TOUTES
    # les recettes du chemin de recherche des hosts du périmètre (générique +
    # privé société). C'est la liste « logiciels nécessaires aux applications »,
    # fournie par la mise en œuvre des recettes (pas une liste à maintenir à part).
    def self.recipe_packages(config_root : String, hosts : Array(Beryl::Config::ResolvedHost)) : Array(String)
      dirs = hosts.flat_map { |h| Beryl::CLI::Apply.recipes_search_path(config_root, h) }.uniq
      packages_in_dirs(dirs)
    end

    # Extrait (trié, dédupliqué) les paquets des steps `pkg-install` de tous les
    # `*.recipe.yml` des dossiers donnés. Pur (filesystem) → testable.
    def self.packages_in_dirs(dirs : Array(String)) : Array(String)
      pkgs = [] of String
      dirs.each do |dir|
        next unless Dir.exists?(dir)
        Dir.glob(File.join(dir, "*.recipe.yml")).each do |file|
          doc =
            begin
              YAML.parse(File.read(file))
            rescue
              next
            end
          steps = doc["steps"]?
          next unless steps && steps.as_a?
          steps.as_a.each do |step|
            pi = step["pkg-install"]?
            next unless pi
            arr = pi["packages"]?
            next unless arr && arr.as_a?
            arr.as_a.each { |p| (s = p.as_s?) && pkgs << s }
          end
        end
      end
      pkgs.uniq.sort
    end

    # Parse une sortie `pkg query/rquery '%n %v'` (une ligne « nom version »
    # par paquet) en map nom→version. Pur → testable.
    def self.parse_pkg_lines(output : String) : Hash(String, String)
      map = {} of String => String
      output.each_line do |line|
        n, _, v = line.strip.partition(' ')
        map[n] = v unless n.empty?
      end
      map
    end

    # Map paquet→version pour un host (live SSH). `rquery: true` interroge le
    # dépôt (versions DISPONIBLES) au lieu de l'installé. Tente les users comme
    # `gather_usage`. {nil, nil} si injoignable. csh-safe (pas de redir Bourne).
    def self.gather_pkg_map(host : Beryl::Config::ResolvedHost, system_ssh : Bool, rquery : Bool) : {Hash(String, String)?, String?}
      cmd = rquery ? "pkg rquery -a '%n %v'" : "pkg query -a '%n %v'"
      usage_attempts(host, system_ssh).each do |user, target|
        pr = remote(host, user, target, cmd, system_ssh)
        next unless pr.ok && !pr.stdout.strip.empty?
        return {parse_pkg_lines(pr.stdout), user ? "#{user}@#{target}" : target}
      end
      {nil, nil}
    end

    # `--versions` : matrice serveurs (colonnes) × paquets (lignes), versions
    # INSTALLÉES (live). Lignes = paquets des recettes (défaut) ou TOUS installés.
    private def self.render_pkg_versions(config_root : String, root : Beryl::Config::Root, scope : String?, all_pkgs : Bool, system_ssh : Bool) : Int32
      hosts = scoped_hosts(root, scope)
      if hosts.empty?
        STDERR.puts "beryl : aucun host dans le périmètre."
        return EXIT_USAGE
      end
      STDERR.puts "Versions installées (live SSH) sur #{hosts.size} serveur(s)…"
      maps = {} of String => Hash(String, String)
      unreachable = [] of String
      hosts.each do |h|
        m, _ = gather_pkg_map(h, system_ssh, rquery: false)
        m ? (maps[h.short_name] = m) : (unreachable << h.short_name)
      end
      reachable = hosts.reject { |h| unreachable.includes?(h.short_name) }
      if reachable.empty?
        STDERR.puts "beryl : aucun serveur joignable."
        return EXIT_USAGE
      end

      packages =
        if all_pkgs
          maps.values.flat_map(&.keys).uniq.sort
        else
          recipe_packages(config_root, hosts)
        end
      if packages.empty?
        STDERR.puts "beryl : aucun paquet à afficher (#{all_pkgs ? "rien d'installé ?" : "aucune recette avec pkg-install"})."
        return EXIT_USAGE
      end

      header = ["PAQUET"] + reachable.map(&.short_name)
      rows = packages.map do |pkg|
        [pkg] + reachable.map { |h| maps[h.short_name][pkg]? || "—" }
      end
      print_table(header, rows)
      puts
      puts "#{packages.size} paquet(s) × #{reachable.size} serveur(s)#{all_pkgs ? " (tous installés)" : " (recettes)"}. « — » = non installé."
      puts "injoignables : #{unreachable.join(", ")}" unless unreachable.empty?
      EXIT_OK
    end

    # `--updates` : pour les paquets des recettes, version DISPONIBLE au dépôt vs
    # installée par serveur. « ↑ » = une autre version est disponible au dépôt.
    private def self.render_pkg_updates(config_root : String, root : Beryl::Config::Root, scope : String?, system_ssh : Bool) : Int32
      hosts = scoped_hosts(root, scope)
      if hosts.empty?
        STDERR.puts "beryl : aucun host dans le périmètre."
        return EXIT_USAGE
      end
      packages = recipe_packages(config_root, hosts)
      if packages.empty?
        STDERR.puts "beryl : aucun paquet de recette (pkg-install) dans le périmètre."
        return EXIT_USAGE
      end
      STDERR.puts "Installé + disponible (live SSH) sur #{hosts.size} serveur(s)…"
      installed = {} of String => Hash(String, String)
      avail = {} of String => String # paquet → version dispo (1ʳᵉ source qui répond)
      reachable = [] of Beryl::Config::ResolvedHost
      hosts.each do |h|
        inst, _ = gather_pkg_map(h, system_ssh, rquery: false)
        next unless inst
        reachable << h
        installed[h.short_name] = inst
        # Une seule interro dépôt (même repo pour la flotte) sur le 1er joignable.
        if avail.empty?
          rq, _ = gather_pkg_map(h, system_ssh, rquery: true)
          rq.try(&.each { |n, v| avail[n] = v })
        end
      end
      if reachable.empty?
        STDERR.puts "beryl : aucun serveur joignable."
        return EXIT_USAGE
      end

      header = ["PAQUET", "DISPO"] + reachable.map(&.short_name)
      rows = packages.map do |pkg|
        a = avail[pkg]? || "—"
        cells = reachable.map do |h|
          iv = installed[h.short_name][pkg]?
          if iv.nil?
            "—"
          elsif a != "—" && iv != a
            "↑ #{iv}"
          else
            iv
          end
        end
        [pkg, a] + cells
      end
      print_table(header, rows)
      puts
      puts "DISPO = version au dépôt. « ↑ <v> » = installé v, une autre version est dispo. « — » = absent."
      EXIT_OK
    end

    # Convertit un pourcentage d'UTILISÉ (ex. `zpool cap`, `df Capacity`) en
    # pourcentage de LIBRE (`36%` → `64%`). Renvoie la chaîne d'origine si on
    # n'arrive pas à la lire (jamais censé arriver).
    def self.free_pct(used : String) : String
      n = used.rstrip('%').to_i?
      n ? "#{100 - n}%" : used
    end

    # Entier d'un pourcentage (`64%` → 64), ou nil.
    def self.pct_int(s : String) : Int32?
      s.rstrip('%').to_i?
    end

    # Ordre des volumes : `zroot` TOUJOURS en premier, puis les autres pools par
    # ordre alphabétique (zdata, ztank…).
    def self.sort_volumes(rows : Array(UsageRow)) : Array(UsageRow)
      rows.sort_by { |r| {r.label == "zroot" ? 0 : 1, r.label} }
    end

    # Parse `zpool list -H -o name,size,alloc,free,cap` → une ligne par pool.
    # La colonne `%` retournée est le LIBRE (cap = utilisé → 100 − cap).
    def self.parse_zpool(output : String) : Array(UsageRow)
      output.each_line.compact_map do |l|
        f = l.split
        f.size >= 5 ? UsageRow.new(f[0], f[1], f[2], f[3], free_pct(f[4])) : nil
      end.to_a
    end

    # Parse `df -h` → utilisation par POOL : un dataset ZFS (`zroot/...`, `zdata`)
    # est regroupé sous son pool (segment avant le 1er `/`), en gardant le montage
    # le plus court (racine du pool) ; un device classique (UFS/ext4) = son montage.
    # Pseudo-FS (devfs/tmpfs/proc…) filtrés. Fonction PURE (sans sudo côté hôte).
    def self.parse_df(output : String) : Array(UsageRow)
      skip = {"devfs", "tmpfs", "procfs", "fdescfs", "linprocfs", "none", "run", "udev", "overlay"}
      best = {} of String => {mnt: String, row: UsageRow}
      order = [] of String
      output.split('\n')[1..].each do |l|
        f = l.split
        next if f.size < 6
        fs = f[0]
        mnt = f[5..].join(" ")
        next if skip.includes?(fs) || !mnt.starts_with?("/")
        next if {"/dev", "/proc", "/sys", "/run"}.any? { |p| mnt == p || mnt.starts_with?("#{p}/") }
        # Dataset ZFS (ne commence PAS par `/`, ex. `zroot/...` ou `zdata`) →
        # regroupé par pool ; device classique (`/dev/...`) → par montage.
        key = fs.starts_with?('/') ? mnt : fs.split('/').first
        cur = best[key]?
        if cur.nil? || mnt.size < cur[:mnt].size
          order << key unless best.has_key?(key)
          best[key] = {mnt: mnt, row: UsageRow.new(key, f[1], f[2], f[3], free_pct(f[4]))}
        end
      end
      order.map { |k| best[k][:row] }
    end

    # Collecte l'usage + l'OS live de chaque host (pour `--adoc`/`--html`).
    # Progrès sur STDERR (stdout = le document). Renvoie {carte d'usage (nil =
    # injoignable), carte OS live (fqdn → « FreeBSD 15.0-RELEASE-p10 »)}.
    private def self.gather_usage_map(hosts : Array(Beryl::Config::ResolvedHost), system_ssh : Bool) : {Hash(String, Array(UsageRow)?), Hash(String, String)}
      rows_map = {} of String => Array(UsageRow)?
      os_map = {} of String => String
      hosts.each do |h|
        STDERR.print "  usage #{h.short_name} … "
        res = gather_usage(h, system_ssh)
        # Diagnostic À L'ÉCRAN (STDERR) — le document (stdout/HTML) reste épuré :
        # il affiche juste `injoignable`, mais ici on dit POURQUOI (auth, timeout,
        # vRack…), host par host, pour savoir où ça coince.
        if rows = res.rows
          STDERR.puts rows.empty? ? "aucun volume" : "ok (#{res.via}, #{res.os})"
        else
          STDERR.puts "✗ injoignable"
          res.notes.each { |n| STDERR.puts "      · #{n}" }
          if !system_ssh && (diag = h.ssh_key_diagnostic)
            STDERR.puts "      ⚠️  #{diag}"
          end
        end
        rows_map[h.fqdn] = res.rows
        os_map[h.fqdn] = res.os.not_nil! if res.os
      end
      {rows_map, os_map}
    end

    # `--refresh [périmètre]` : pour chaque host OVH du périmètre (société,
    # domaine, host, ou tous), récupère gamme + specs via l'API OVH et les
    # écrit dans le host.yml. AUCUN SSH, aucune modif serveur. Le périmètre
    # filtre par société / domaine / fqdn / nom court.
    # Hosts résolus du périmètre (société / domaine / fqdn / nom court ; vide = tous).
    private def self.scoped_hosts(root : Beryl::Config::Root, scope : String?) : Array(Beryl::Config::ResolvedHost)
      hosts = root.all_hosts_by_fqdn.keys.sort.compact_map do |fqdn|
        begin
          root.resolve(fqdn)
        rescue
          nil
        end
      end
      return hosts unless (s = scope)
      hosts.select { |h| {h.account_name, h.domain_name, h.fqdn, h.short_name}.includes?(s) }
    end

    private def self.refresh_metadata(root : Beryl::Config::Root, scope : String?) : Int32
      ovh_targets = scoped_hosts(root, scope).reject(&.virtual).select { |h| h.provider == "ovh" }
      if ovh_targets.empty?
        puts "Aucun host OVH dans le périmètre #{scope || "(tous)"}."
        return EXIT_OK
      end

      ok = 0
      ovh_targets.group_by(&.account_name).each do |account, hosts|
        hosts.first.apply_all_credentials_to_env!
        ovh = Beryl::Providers::Ovh.new
        unless ovh.available?
          puts "⚠ #{account} : credentials OVH absents — #{hosts.size} host(s) ignoré(s)."
          next
        end
        puts "société #{account} : index des serveurs OVH (API)…"
        index = ovh.ip_to_service_index
        hosts.each do |h|
          sn = h.ovh_service_name
          if sn.nil?
            ip = Beryl::CLI::Scan.resolve_host_ipv4(h.ssh_host)
            sn = ip ? index[ip]? : nil
          end
          unless sn
            puts "  ⚠ #{h.short_name} : service_name introuvable (DNS/IP) — ignoré."
            next
          end
          detail = ovh.server_detail(sn)
          hw = ovh.server_hardware(sn)
          price = ovh.monthly_price(sn)
          ipv6 = Beryl::CLI::Scan.resolve_host_ipv6(h.fqdn)
          path = h.node.source_path
          content = File.read(path)
          content = upsert_block(content, "ovh",
            ovh_block(sn, detail[:commercial], detail[:rack], detail[:ipv4], ipv6, price))
          content = upsert_block(content, "hardware", hardware_block(hw)) if hw
          File.write(path, content)
          ok += 1
          puts "  ✓ #{h.short_name} : #{detail[:commercial] || "gamme ?"}" \
               "#{detail[:rack] ? " [#{detail[:rack]}]" : ""}#{price ? " — #{price} €/mois" : ""} — " \
               "#{hw ? "#{hw.cores}c/#{hw.threads}t, #{hw.ram_gb} Go, #{hw.disks.size} grp disque(s)" : "specs indisponibles"}"
        end
      end
      puts
      puts "#{ok}/#{ovh_targets.size} host(s) rafraîchi(s). `beryl info` pour la vue d'ensemble."
      EXIT_OK
    end

    # Lignes du bloc `ovh:` (service_name + gamme + rack + IPs + prix/mois).
    def self.ovh_block(service_name : String, commercial : String?, rack : String?,
                       ipv4 : String?, ipv6 : String?, price : String?) : Array(String)
      b = ["ovh:", "  service_name: #{service_name}"]
      b << "  commercial_name: #{commercial}" if commercial
      b << "  rack: #{rack}" if rack
      b << "  ipv4: #{ipv4}" if ipv4
      # IPv6 TOUJOURS quotée : pleine de `:` (et parfois finissant par `::`) →
      # YAML la mal-parserait sans guillemets.
      b << %(  ipv6: "#{ipv6}") if ipv6
      b << "  price_eur: #{price}" if price
      b
    end

    # Lignes du bloc `hardware:` (specs déclarées par le provider).
    private def self.hardware_block(hw : Beryl::HardwareSpec) : Array(String)
      b = ["hardware:", "  cpu: #{hw.cpu}", "  cores: #{hw.cores}",
           "  threads: #{hw.threads}", "  ram_gb: #{hw.ram_gb}"]
      b << "  raid: #{hw.raid}" if hw.raid
      unless hw.disks.empty?
        b << "  disks:"
        hw.disks.each { |d| b << "    - #{d}" }
      end
      b
    end

    # Remplace le bloc top-level `key:` (sa ligne + les lignes indentées qui
    # suivent) par `block`, en PRÉSERVANT tout le reste (commentaires inclus).
    # Si le bloc est absent, l'ajoute en fin de fichier (ligne vide de séparation).
    def self.upsert_block(content : String, key : String, block : Array(String)) : String
      lines = content.split('\n')
      if start = lines.index { |l| l.rstrip == "#{key}:" }
        i = start + 1
        while i < lines.size && lines[i].starts_with?(" ")
          i += 1
        end
        return (lines[0...start] + block + lines[i..]).join('\n')
      end
      out = lines.dup
      while !out.empty? && out.last.empty?
        out.pop
      end
      out << ""
      out.concat(block)
      out << ""
      out.join('\n')
    end

    # Document AsciiDoc récapitulatif : synthèse + matériel + réseau vRack +
    # (si `usage` fourni) utilisation disque LIVE. Régénérable :
    # `beryl info --adoc [--usage] <périmètre> > inventaire.adoc`.
    def self.build_adoc(
      hosts : Array(Beryl::Config::ResolvedHost),
      scope : String?,
      usage : Hash(String, Array(UsageRow)?)? = nil,
      os_map : Hash(String, String)? = nil,
      generated : String = Beryl.format_timestamp(Time.local),
    ) : String
      esc = ->(s : String) { s.gsub("|", "\\|") }
      String.build do |io|
        io << "= Inventaire des serveurs"
        io << " — " << scope if scope
        io << '\n'
        # Rendu PDF en PAYSAGE (crystal-asciidoctor-pdf) : tables larges lisibles.
        io << ":pdf-page-layout: landscape\n:pdf-page-size: A4\n"
        # Neutralise le sommaire injecté par la config user de
        # crystal-asciidoctor-pdf (`toc: macro` + `x-title-page-toc`) : inutile
        # pour un inventaire de quelques sections, et il s'affichait sur la page
        # de garde. Les attributs du doc priment sur la user config.
        io << ":toc!:\n:!x-title-page-toc:\n"
        io << ":generated: " << generated << "\n\n"
        io << "_Document généré le #{generated}._\n\n" # date d'écriture visible

        cores = hosts.sum { |h| h.hardware.try(&.cores) || 0 }
        ram = hosts.sum { |h| h.hardware.try(&.ram_gb) || 0 }
        price = hosts.sum { |h| h.ovh_price.try(&.to_f?) || 0.0 }
        io << "== Synthèse\n\n[cols=\"1,>1\",frame=ends,grid=rows]\n|===\n"
        io << "| Serveurs | #{hosts.size}\n"
        io << "| Cœurs (vCPU) | #{cores}\n"
        io << "| RAM totale | #{ram} Go\n"
        io << "| Coût mensuel _(prix connus)_ | #{"%.2f" % price} €\n"
        io << "|===\n\n"

        io << "== Matériel\n\n"
        io << "[options=\"header\",cols=\"2,2,2,3,1,3,>2\"]\n|===\n"
        io << "| Host | Nom commercial | Baie | CPU | RAM | Disques | Prix/mois\n\n"
        hosts.each do |h|
          hw = h.hardware
          # « Nom commercial » = la gamme SEULE (ex. RISE-1), sans le CPU qui
          # suit après `|` (redondant avec la colonne CPU).
          gamme = (h.ovh_commercial_name || "—").split('|').first.strip
          cells = [
            h.short_name,
            gamme,
            h.ovh_rack || "—",
            hw ? "#{hw.cpu} (#{hw.cores}c/#{hw.threads}t)" : "—",
            hw ? "#{hw.ram_gb} Go" : "—",
            # Un groupe de disques par LIGNE (`+` = saut de ligne AsciiDoc).
            (hw && !hw.disks.empty?) ? hw.disks.join(" +\n") : "—",
            h.ovh_price ? "#{h.ovh_price} €" : "—",
          ]
          io << "| " << cells.map { |c| esc.call(c) }.join(" | ") << '\n'
        end
        io << "|===\n\n"

        # Alerte CO-LOCALISATION : baies hébergeant ≥ 2 serveurs (panne baie =
        # perte simultanée → à éviter pour des serveurs redondants).
        racks = Hash(String, Array(String)).new
        hosts.each do |h|
          if r = h.ovh_rack
            (racks[r] ||= [] of String) << h.short_name
          end
        end
        shared = racks.select { |_, v| v.size >= 2 }
        unless shared.empty?
          io << "[WARNING]\n====\n"
          # Chaque baie sur SA ligne : sauts forcés AsciiDoc (` +`) — un simple
          # `\n` serait avalé (texte reflué) dans le bloc admonition.
          lines = ["Serveurs CO-LOCALISÉS (même baie → une panne de baie les perd ensemble) :"]
          shared.each { |r, hs| lines << "*#{esc.call(r)}* : #{hs.join(", ")}" }
          io << lines.join(" +\n") << "\n"
          io << "====\n\n"
        end

        net_hosts = hosts.select { |h| h.ovh_ipv4 || h.ovh_ipv6 || h.vrack_ip }
        unless net_hosts.empty?
          io << "== Réseau\n\n[options=\"header\",cols=\"2,2,3,2,2\"]\n|===\n"
          io << "| Host | IPv4 publique | IPv6 publique | vRack | Rôle\n\n"
          net_hosts.each do |h|
            io << "| #{h.short_name} | #{h.ovh_ipv4 || "—"} | #{h.ovh_ipv6 || "—"} "
            io << "| #{h.vrack_ip || "—"} | #{esc.call(adoc_role(h))}\n"
          end
          io << "|===\n\n"
        end

        if usage
          io << "== Utilisation disque _(live)_\n\n"
          io << "[options=\"header\",cols=\"2,2,2,1,1,1,>1\"]\n|===\n"
          io << "| Host | OS | Volume | Taille | Utilisé | Libre | % libre\n\n"
          low = [] of String # volumes sous 10% de libre (host / volume : N% libre)
          hosts.each do |h|
            os = os_map.try(&.[h.fqdn]?) || "—" # OS LIVE (uname -sr), colonne 2
            rows = usage[h.fqdn]?
            if rows.nil?
              io << "| #{h.short_name} | — | _injoignable_ | — | — | — | —\n"
            elsif rows.empty?
              io << "| #{h.short_name} | #{esc.call(os)} | _aucun volume_ | — | — | — | —\n"
            else
              rows.each_with_index do |r, i|
                io << "| #{i.zero? ? h.short_name : ""} | #{i.zero? ? esc.call(os) : ""} | #{esc.call(r.label)} | #{r.size} | #{r.used} | #{r.free} | #{r.pct}\n"
                if (fp = pct_int(r.pct)) && fp < 10
                  low << "*#{h.short_name}* / #{r.label} : #{r.pct} libre" # nom serveur en gras (esc.call appliqué plus bas)
                end
              end
            end
          end
          io << "|===\n\n"

          # Alerte SATURATION : un volume sous 10% de libre = risque imminent.
          unless low.empty?
            io << "[WARNING]\n====\n"
            lines = ["Volumes SOUS 10 % de libre (risque de saturation) :"]
            low.each { |l| lines << esc.call(l) }
            io << lines.join(" +\n") << "\n"
            io << "====\n\n"
          end
        end
      end
    end

    # URL du dépôt de l'outil de conversion PDF (message d'erreur s'il manque).
    ASCIIDOCTOR_PDF_TOOL = "crystal-asciidoctor-pdf"
    ASCIIDOCTOR_PDF_URL  = "https://github.com/aloli-crystal/crystal-asciidoctor-pdf"

    # `--adoc=NOM` : écrit `NOM.adoc`, le convertit en PDF via
    # crystal-asciidoctor-pdf (`NOM.adoc.pdf`) et l'ouvre (`open`). Si l'outil
    # est absent, on garde le `.adoc` et on pointe vers la page GitHub.
    private def self.render_adoc_pdf(doc : String, name : String) : Int32
      stem = name.rchop(".adoc") # tolère que l'utilisateur ait déjà mis .adoc
      adoc_path = "#{stem}.adoc"
      File.write(adoc_path, doc)
      puts "✓ #{adoc_path}"

      unless Process.find_executable(ASCIIDOCTOR_PDF_TOOL)
        STDERR.puts "beryl : `#{ASCIIDOCTOR_PDF_TOOL}` introuvable — PDF non généré."
        STDERR.puts "        Installez-le : #{ASCIIDOCTOR_PDF_URL}"
        STDERR.puts "        (#{adoc_path} est écrit ; vous pourrez le convertir ensuite.)"
        return EXIT_USAGE
      end

      unless Process.run(ASCIIDOCTOR_PDF_TOOL, [adoc_path], output: STDOUT, error: STDERR).success?
        STDERR.puts "beryl : échec de #{ASCIIDOCTOR_PDF_TOOL} sur #{adoc_path}."
        return EXIT_USAGE
      end

      pdf_path = "#{adoc_path}.pdf" # crystal-asciidoctor-pdf suffixe .pdf au nom complet
      puts "✓ #{pdf_path}"
      # Ouverture best-effort (macOS `open`) — n'échoue pas la commande.
      Process.run("open", [pdf_path], output: STDOUT, error: STDERR) rescue nil
      EXIT_OK
    end

    # Rôle réseau lisible : bastion / caché (via <z>) / public.
    private def self.adoc_role(h : Beryl::Config::ResolvedHost) : String
      return "bastion" if h.bastion?
      if pj = h.proxy_jump(h.connect_user)
        return "caché (via #{pj.split('@').last.split('.').first})"
      end
      "public"
    end

    # ─── Site HTML (`--html`) : index triable + 1 page par serveur ───────────

    # Échappe une valeur pour insertion HTML (texte ou attribut).
    def self.hesc(s : String) : String
      s.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
    end

    # Convertit une taille humaine (`14T`, `460G`, `512K`, `8.0G`) en octets,
    # pour un tri numérique correct des colonnes (`data-sort`). 0 si illisible.
    def self.size_bytes(s : String) : Int64
      m = s.strip.match(/^([\d.]+)\s*([KMGTP]?)/i)
      return 0_i64 unless m
      n = m[1].to_f? || 0.0
      mult = case (m[2]? || "").upcase
             when "K" then 1024.0
             when "M" then 1024.0 ** 2
             when "G" then 1024.0 ** 3
             when "T" then 1024.0 ** 4
             when "P" then 1024.0 ** 5
             else          1.0
             end
      (n * mult).to_i64
    end

    # Répertoire de sortie : `<config>/<société>/info` (périmètre société) ou
    # `<config>/<société>/<domaine>/info` (périmètre domaine ou host). Régénéré
    # à chaque lancement (comme la gem coverage).
    def self.info_dir(config_root : String, scope : String?, hosts : Array(Beryl::Config::ResolvedHost)) : String
      h = hosts.first?
      return File.join(config_root, "info") unless h
      if scope && scope == h.account_name
        File.join(config_root, h.account_name, "info")
      else
        File.join(config_root, h.account_name, h.domain_name, "info")
      end
    end

    # En-tête HTML commun (lie style.css + viewport).
    private def self.html_head(title : String) : String
      "<!DOCTYPE html>\n<html lang=\"fr\">\n<head>\n<meta charset=\"utf-8\">\n" \
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" \
      "<title>#{hesc(title)}</title>\n<link rel=\"stylesheet\" href=\"style.css\">\n</head>\n<body>\n"
    end

    private def self.html_foot : String
      "<script src=\"sort.js\"></script>\n</body>\n</html>\n"
    end

    # Génère le site complet sous `<config>/<scope>/info/` et ouvre l'index.
    private def self.render_html_site(config_root : String, scope : String?,
                                      hosts : Array(Beryl::Config::ResolvedHost),
                                      usage : Hash(String, Array(UsageRow)?)?,
                                      os_map : Hash(String, String)? = nil) : Int32
      if hosts.empty?
        STDERR.puts "beryl : aucun host pour le périmètre#{scope ? " « #{scope} »" : ""}."
        return EXIT_USAGE
      end
      dir = info_dir(config_root, scope, hosts)
      generated = Beryl.format_timestamp(Time.local)
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "style.css"), HTML_STYLE)
      File.write(File.join(dir, "sort.js"), HTML_SORT_JS)
      File.write(File.join(dir, "index.html"), build_html_index(hosts, scope, usage, generated, os_map))
      hosts.each do |h|
        rows = usage ? usage[h.fqdn]? : nil
        File.write(File.join(dir, "#{h.short_name}.html"),
          build_html_host(h, rows, !usage.nil?, generated, os_map.try(&.[h.fqdn]?)))
      end
      index = File.join(dir, "index.html")
      puts "✓ #{hosts.size + 3} fichier(s) écrit(s) dans #{dir}"
      puts "  → #{index}"
      Process.run("open", [index], output: STDOUT, error: STDERR) rescue nil
      EXIT_OK
    end

    # Page d'index : synthèse + alertes + tableaux TRIABLES (clic sur l'en-tête),
    # avec lien vers la page de chaque serveur.
    def self.build_html_index(hosts : Array(Beryl::Config::ResolvedHost), scope : String?,
                              usage : Hash(String, Array(UsageRow)?)?, generated : String,
                              os_map : Hash(String, String)? = nil) : String
      title = "Inventaire des serveurs#{scope ? " — #{scope}" : ""}"
      String.build do |io|
        io << html_head(title)
        io << "<h1>#{hesc(title)}</h1>\n"
        io << "<p class=\"meta\">Document généré le #{hesc(generated)}.</p>\n"

        cores = hosts.sum { |h| h.hardware.try(&.cores) || 0 }
        ram = hosts.sum { |h| h.hardware.try(&.ram_gb) || 0 }
        price = hosts.sum { |h| h.ovh_price.try(&.to_f?) || 0.0 }
        io << "<h2>Synthèse</h2>\n<table class=\"kv\">\n"
        io << "<tr><th>Serveurs</th><td>#{hosts.size}</td></tr>\n"
        io << "<tr><th>Cœurs (vCPU)</th><td>#{cores}</td></tr>\n"
        io << "<tr><th>RAM totale</th><td>#{ram} Go</td></tr>\n"
        io << "<tr><th>Coût mensuel <em>(prix connus)</em></th><td>#{"%.2f" % price} €</td></tr>\n</table>\n"

        racks = Hash(String, Array(String)).new
        hosts.each { |h| (racks[h.ovh_rack.not_nil!] ||= [] of String) << h.short_name if h.ovh_rack }
        shared = racks.select { |_, v| v.size >= 2 }
        unless shared.empty?
          io << "<div class=\"warn\"><strong>Serveurs CO-LOCALISÉS</strong> (même baie → une panne de baie les perd ensemble) :\n<ul>\n"
          shared.each { |r, hs| io << "<li><strong>#{hesc(r)}</strong> : #{hesc(hs.join(", "))}</li>\n" }
          io << "</ul></div>\n"
        end

        io << "<h2>Matériel</h2>\n<table class=\"sortable\">\n<thead><tr>"
        %w[Host Nom\ commercial Baie CPU Cœurs RAM Disques Prix/mois].each { |th| io << "<th>#{hesc(th)}</th>" }
        io << "</tr></thead>\n<tbody>\n"
        hosts.each do |h|
          hw = h.hardware
          gamme = (h.ovh_commercial_name || "—").split('|').first.strip
          io << "<tr>"
          io << "<td><a href=\"#{hesc(h.short_name)}.html\">#{hesc(h.short_name)}</a></td>"
          io << "<td>#{hesc(gamme)}</td>"
          io << "<td>#{hesc(h.ovh_rack || "—")}</td>"
          io << "<td>#{hesc(hw.try(&.cpu) || "—")}</td>"
          io << "<td data-sort=\"#{hw.try(&.cores) || 0}\">#{hw ? "#{hw.cores}c/#{hw.threads}t" : "—"}</td>"
          io << "<td data-sort=\"#{hw.try(&.ram_gb) || 0}\">#{hw ? "#{hw.ram_gb} Go" : "—"}</td>"
          io << "<td>#{hw && !hw.disks.empty? ? hesc(hw.disks.join(" / ")) : "—"}</td>"
          io << "<td data-sort=\"#{h.ovh_price.try(&.to_f?) || 0.0}\">#{(p = h.ovh_price) ? "#{hesc(p)} €" : "—"}</td>"
          io << "</tr>\n"
        end
        io << "</tbody></table>\n"

        net_hosts = hosts.select { |h| h.ovh_ipv4 || h.ovh_ipv6 || h.vrack_ip }
        unless net_hosts.empty?
          io << "<h2>Réseau</h2>\n<table class=\"sortable\">\n<thead><tr>"
          ["Host", "IPv4 publique", "IPv6 publique", "vRack", "Rôle"].each { |th| io << "<th>#{hesc(th)}</th>" }
          io << "</tr></thead>\n<tbody>\n"
          net_hosts.each do |h|
            io << "<tr><td><a href=\"#{hesc(h.short_name)}.html\">#{hesc(h.short_name)}</a></td>"
            io << "<td>#{hesc(h.ovh_ipv4 || "—")}</td><td>#{hesc(h.ovh_ipv6 || "—")}</td>"
            io << "<td>#{hesc(h.vrack_ip || "—")}</td><td>#{hesc(adoc_role(h))}</td></tr>\n"
          end
          io << "</tbody></table>\n"
        end

        if usage
          io << "<h2>Utilisation disque <em>(live)</em></h2>\n<table class=\"sortable\">\n<thead><tr>"
          ["Host", "OS", "Volume", "Taille", "Utilisé", "Libre", "% libre"].each { |th| io << "<th>#{hesc(th)}</th>" }
          io << "</tr></thead>\n<tbody>\n"
          low = [] of {String, String}
          hosts.each do |h|
            link = "<a href=\"#{hesc(h.short_name)}.html\">#{hesc(h.short_name)}</a>"
            os = os_map.try(&.[h.fqdn]?) || "—" # OS LIVE (uname -sr), colonne 2
            rows = usage[h.fqdn]?
            if rows.nil?
              io << "<tr><td>#{link}</td><td>—</td><td colspan=\"5\"><em>injoignable</em></td></tr>\n"
            elsif rows.empty?
              io << "<tr><td>#{link}</td><td>#{hesc(os)}</td><td colspan=\"5\"><em>aucun volume</em></td></tr>\n"
            else
              rows.each_with_index do |r, i|
                low_row = (fp = pct_int(r.pct)) && fp < 10
                io << "<tr#{low_row ? " class=\"low\"" : ""}><td>#{i.zero? ? link : ""}</td>"
                io << "<td>#{i.zero? ? hesc(os) : ""}</td>"
                io << "<td>#{hesc(r.label)}</td>"
                io << "<td data-sort=\"#{size_bytes(r.size)}\">#{hesc(r.size)}</td>"
                io << "<td data-sort=\"#{size_bytes(r.used)}\">#{hesc(r.used)}</td>"
                io << "<td data-sort=\"#{size_bytes(r.free)}\">#{hesc(r.free)}</td>"
                io << "<td data-sort=\"#{pct_int(r.pct) || 0}\">#{hesc(r.pct)}</td></tr>\n"
                low << {h.short_name, "#{r.label} : #{r.pct} libre"} if low_row
              end
            end
          end
          io << "</tbody></table>\n"
          unless low.empty?
            io << "<div class=\"warn\"><strong>Volumes SOUS 10 % de libre</strong> (risque de saturation) :\n<ul>\n"
            low.each { |s, rest| io << "<li><strong>#{hesc(s)}</strong> / #{hesc(rest)}</li>\n" }
            io << "</ul></div>\n"
          end
        end

        io << html_foot
      end
    end

    # Page détaillée d'UN serveur (fiche + son utilisation disque). `live_os` =
    # OS déduit du serveur (`uname -sr`) ; remplace l'`os:` théorique du YAML.
    def self.build_html_host(host : Beryl::Config::ResolvedHost, rows : Array(UsageRow)?,
                             show_usage : Bool, generated : String, live_os : String? = nil) : String
      hw = host.hardware
      String.build do |io|
        io << html_head(host.fqdn)
        io << "<p><a href=\"index.html\">← Inventaire</a></p>\n"
        io << "<h1>#{hesc(host.fqdn)}</h1>\n<table class=\"kv\">\n"
        kv = ->(k : String, v : String) { io << "<tr><th>#{hesc(k)}</th><td>#{hesc(v)}</td></tr>\n" }
        kv.call("Provider", host.provider || "—")
        kv.call("Service OVH", host.ovh_service_name || "—")
        kv.call("Nom commercial", host.ovh_commercial_name || "—")
        kv.call("Baie (rack)", host.ovh_rack || "—")
        kv.call("Prix/mois", (p = host.ovh_price) ? "#{p} €" : "—")
        kv.call("IPv4 publique", host.ovh_ipv4 || "—")
        kv.call("IPv6 publique", host.ovh_ipv6 || "—")
        kv.call("IP vRack", host.vrack_ip || "—")
        kv.call("Rôle réseau", adoc_role(host))
        kv.call("OS", live_os ? "#{live_os} (live)" : host.os)
        kv.call("CPU", hw ? "#{hw.cpu} (#{hw.cores}c/#{hw.threads}t)" : "—")
        kv.call("RAM", hw ? "#{hw.ram_gb} Go" : "—")
        kv.call("RAID", hw.try(&.raid) || "aucun (RAID logiciel/ZFS)")
        io << "</table>\n"

        if hw && !hw.disks.empty?
          io << "<h2>Disques (provider)</h2>\n<ul>\n"
          hw.disks.each { |d| io << "<li>#{hesc(d)}</li>\n" }
          io << "</ul>\n"
        end

        if show_usage
          io << "<h2>Utilisation disque <em>(live)</em></h2>\n"
          if rows.nil?
            io << "<p class=\"warn\">injoignable</p>\n"
          elsif rows.empty?
            io << "<p><em>aucun volume détecté</em></p>\n"
          else
            io << "<table class=\"sortable\">\n<thead><tr>"
            ["Volume", "Taille", "Utilisé", "Libre", "% libre"].each { |th| io << "<th>#{hesc(th)}</th>" }
            io << "</tr></thead>\n<tbody>\n"
            rows.each do |r|
              low_row = (fp = pct_int(r.pct)) && fp < 10
              io << "<tr#{low_row ? " class=\"low\"" : ""}><td>#{hesc(r.label)}</td>"
              io << "<td data-sort=\"#{size_bytes(r.size)}\">#{hesc(r.size)}</td>"
              io << "<td data-sort=\"#{size_bytes(r.used)}\">#{hesc(r.used)}</td>"
              io << "<td data-sort=\"#{size_bytes(r.free)}\">#{hesc(r.free)}</td>"
              io << "<td data-sort=\"#{pct_int(r.pct) || 0}\">#{hesc(r.pct)}</td></tr>\n"
            end
            io << "</tbody></table>\n"
          end
        end

        io << "<p class=\"meta\">Généré le #{hesc(generated)}.</p>\n"
        io << html_foot
      end
    end

    # Feuille de style du site (écrite une fois dans info/style.css).
    HTML_STYLE = <<-CSS
      :root { --fg:#1c1e21; --muted:#65676b; --line:#dfe1e5; --accent:#1a73e8; --warn-bg:#fff4e5; --warn-bd:#f0a020; --low:#fde8e8; }
      * { box-sizing:border-box; }
      body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; color:var(--fg); margin:0 auto; max-width:1100px; padding:1.5rem; line-height:1.45; }
      h1 { font-size:1.6rem; margin:.2rem 0 .4rem; }
      h2 { font-size:1.15rem; margin:1.6rem 0 .5rem; border-bottom:2px solid var(--line); padding-bottom:.2rem; }
      a { color:var(--accent); text-decoration:none; } a:hover { text-decoration:underline; }
      p.meta { color:var(--muted); font-size:.85rem; margin:.2rem 0 1rem; }
      table { border-collapse:collapse; width:100%; font-size:.9rem; margin:.3rem 0; }
      th, td { border:1px solid var(--line); padding:.35rem .55rem; text-align:left; }
      thead th { background:#f5f6f7; position:sticky; top:0; }
      table.sortable thead th { cursor:pointer; user-select:none; }
      table.sortable thead th::after { content:"\\2195"; color:var(--muted); font-size:.75em; margin-left:.35em; }
      table.sortable thead th[data-asc="true"]::after { content:"\\2191"; color:var(--accent); }
      table.sortable thead th[data-asc="false"]::after { content:"\\2193"; color:var(--accent); }
      table.kv th { background:#f5f6f7; width:14rem; }
      tbody tr:nth-child(even) { background:#fafbfc; }
      tr.low td { background:var(--low); }
      div.warn { background:var(--warn-bg); border-left:4px solid var(--warn-bd); padding:.6rem .9rem; margin:1rem 0; border-radius:3px; }
      div.warn ul { margin:.4rem 0 0; }
      CSS

    # Tri des tableaux `.sortable` au clic sur l'en-tête (numérique via data-sort,
    # sinon alphabétique ; bascule asc/desc). Vanilla JS, aucune dépendance.
    HTML_SORT_JS = <<-JS
      document.querySelectorAll("table.sortable").forEach(function (table) {
        var heads = table.tHead.rows[0].cells;
        Array.prototype.forEach.call(heads, function (th, idx) {
          th.addEventListener("click", function () {
            var asc = th.getAttribute("data-asc") !== "true";
            Array.prototype.forEach.call(heads, function (o) { o.removeAttribute("data-asc"); });
            th.setAttribute("data-asc", asc ? "true" : "false");
            var tb = table.tBodies[0];
            var rows = Array.prototype.slice.call(tb.rows);
            rows.sort(function (a, b) {
              var ca = a.cells[idx], cb = b.cells[idx];
              if (!ca || !cb) return 0;
              var xa = ca.getAttribute("data-sort"), xb = cb.getAttribute("data-sort");
              var na = parseFloat(xa !== null ? xa : ca.textContent);
              var nb = parseFloat(xb !== null ? xb : cb.textContent);
              var r;
              if (!isNaN(na) && !isNaN(nb)) { r = na - nb; }
              else { r = ca.textContent.trim().localeCompare(cb.textContent.trim()); }
              return asc ? r : -r;
            });
            rows.forEach(function (row) { tb.appendChild(row); });
          });
        });
      });
      JS

    # Table alignée (colonnes ljust), en-tête souligné.
    private def self.print_table(header : Array(String), rows : Array(Array(String))) : Nil
      all = [header] + rows
      widths = (0...header.size).map { |i| all.map { |r| r[i].size }.max }
      line = ->(r : Array(String)) do
        r.each_with_index.map { |c, i| c.ljust(widths[i]) }.to_a.join("  ")
      end
      puts line.call(header)
      puts widths.map { |w| "─" * w }.join("──")
      rows.each { |r| puts line.call(r) }
    end
  end
end
