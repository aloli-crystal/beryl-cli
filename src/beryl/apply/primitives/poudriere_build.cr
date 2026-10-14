require "../primitive"
require "../../freebsd_release"

module Beryl::Apply
  # Primitive `poudriere-build` : maintient un dépôt pkg poudriere à la
  # dernière MINEURE d'un majeur FreeBSD figé, construit depuis un ou
  # plusieurs OVERLAYS de ports, et publie l'alias par ABI
  # (`FreeBSD:<major>:<arch>` → set courant) pour un client agnostique à la
  # version (`url: https://…/${ABI}`).
  #
  # Idempotent & réconciliateur. À chaque apply :
  #
  # . compare la dernière release de la branche
  #   (`FreebsdRelease.latest_by_branch`) à ce que vise l'alias ;
  # . pour chaque overlay : clone s'il est absent, sinon mise à jour git
  #   en AVANCE RAPIDE uniquement (`fetch` + `merge --ff-only`, cf. plus
  #   bas), enregistrement dans poudriere s'il ne l'est pas
  #   (`poudriere ports -c -p <name> -m null -M <path>`) ;
  # . compare le commit de chaque overlay à celui du dernier build RÉUSSI
  #   (fichier d'état `<pkgdir>/.beryl-build-<major>.overlays`, une ligne
  #   `<name> <commit>`, écrit par le script de build seulement en fin de
  #   succès, juste après le repointage de l'alias).
  #
  # Nouvelle mineure OU commit d'overlay différent (ou état inconnu) →
  # build en DÉTACHÉ (daemon -f + log + lock anti-double-build), qui crée la
  # jail au besoin, met à jour l'arbre `default`, `poudriere bulk` avec
  # TOUS les overlays (`-O a -O b`, accumulés par poudriere) et la réunion
  # des build-lists (`-f x -f y`, idem), puis repointe l'alias et
  # enregistre les commits construits. Rien de changé → skip.
  #
  # Git : avance rapide seulement, jamais `reset --hard` sur un overlay.
  # Des modifications suivies non commitées, une branche autre que celle
  # attendue ou un historique divergé → Failed avec message (rien n'est
  # écrasé). Des commits locaux non poussés (en avance) sont conservés et
  # construits (signalés). Les fichiers non suivis (ex. un script local)
  # n'empêchent rien. En dry-run, le commit distant est lu par
  # `git ls-remote` (rien n'est modifié).
  #
  # `major` FIGÉ (ex. "15") : suit 15.0 → 15.1 → 15.2 (même ABI, sûr) mais
  # JAMAIS un saut de majeur (16.0 = nouvelle ABI). Pour ouvrir 16 : une 2ᵉ
  # instance `major: 16` → l'alias `FreeBSD:16:amd64` cohabite ; un client
  # bascule quand SA base passe en 16.
  #
  #     - poudriere-build:
  #         major: "15"
  #         overlays:
  #           - name: quimeo                  # nom de l'arbre poudriere (-O)
  #             pkglist: /usr/local/etc/poudriere.d/quimeo-pkglist
  #           - name: aloli
  #             git: https://github.com/aloli/aloli-ports  # optionnel : clone + MAJ
  #             branch: production            # optionnel (défaut : branche courante / distante par défaut)
  #             path: /usr/local/poudriere/aloli-ports      # optionnel (défaut : /usr/local/poudriere/<name>-ports)
  #             pkglist: /usr/local/etc/poudriere.d/aloli-pkglist   # optionnel
  #         reapply: /usr/local/poudriere/quimeo-ports/reapply-base-patches.sh  # optionnel
  #         schedule: "0 3 * * 0"         # optionnel : build planifié (cron)
  #         ports_branch: quarterly       # optionnel : branche de l'arbre de ports
  #
  # `ports_branch` : branche git de l'arbre de ports de base (`ports`), mise
  # en place avant chaque build. `quarterly` = branche du trimestre EN COURS
  # (`2026Q4`…), calculée par le script lui-même à chaque build — le build
  # planifié avance donc tout seul d'un trimestre à l'autre, comme le dépôt
  # officiel `quarterly` des serveurs (repli sur le trimestre précédent tant
  # que la nouvelle branche n'est pas publiée). Autre valeur = nom de branche
  # fixe (`main`…). Absent = branche laissée telle quelle. Changer de branche
  # reconstruit presque tout (versions différentes).
  #
  # `schedule` (5 champs cron) : pose sur le builder un script
  # `/usr/local/etc/poudriere.d/beryl-build-<majeur>.sh` et une entrée
  # `/usr/local/etc/cron.d/beryl-poudriere-<majeur>` qui relancent LE MÊME
  # build que `beryl apply` (verrou partagé, overlays gérés mis à jour en
  # avance rapide, arbre de ports frais → correctifs de sécurité), sur la
  # mineure visée au dernier apply. Régénérés à chaque apply. Échec signalé
  # par mail (sortie de cron), détail dans le journal des builds.
  #
  # Champs d'un overlay : `name` obligatoire ; sans `git`, l'overlay n'est
  # pas mis à jour par beryl (son commit est tout de même suivi si `path`
  # est un dépôt git) ; `path` par défaut = chemin enregistré dans poudriere,
  # sinon `/usr/local/poudriere/<name>-ports`. Au moins une `pkglist` est
  # requise (par overlay et/ou au niveau du step).
  #
  # Ancien schéma, toujours accepté tel quel (un seul overlay) :
  #
  #     - poudriere-build:
  #         major: "15"
  #         pkglist: /usr/local/etc/poudriere.d/quimeo-pkglist
  #         overlay: quimeo               # optionnel (défaut quimeo)
  class PoudriereBuild < Primitive
    DEFAULT_PKGDIR = "/usr/local/poudriere/data/packages"
    OVERLAY_ROOT   = "/usr/local/poudriere"

    # Overlay déclaré dans la recette.
    record Overlay, name : String, git : String? = nil, branch : String? = nil,
      path : String? = nil, pkglist : String? = nil

    # Overlay après lecture/synchronisation : chemin effectif, commit qui
    # sera construit (nil = non suivi, pas un dépôt git), `fresh` = clone
    # prévu (dry-run), `notes` = actions faites (ou prévues) sur l'overlay,
    # `infos` = constats sans action (ne rendent pas le step « Applied »).
    # Overlay vu par le build planifié : `branch` non nil = géré par beryl
    # (mis à jour en avance rapide avant le build ; "" = branche courante) ;
    # `tracked` = dépôt git dont le commit construit est enregistré.
    record ScheduledOverlay, name : String, path : String, branch : String?, tracked : Bool

    CRON_DIR      = "/usr/local/etc/cron.d"
    POUDRIERE_ETC = "/usr/local/etc/poudriere.d"

    record OverlayState, overlay : Overlay, path : String, commit : String?,
      fresh : Bool, notes : Array(String), infos : Array(String)

    # Source des dernières releases par majeur — injectable pour les tests.
    class_property release_lookup : Proc(Hash(Int32, String)) = -> { Beryl::FreebsdRelease.latest_by_branch }

    def name : String
      "poudriere-build"
    end

    # "15.1" + amd64 → "fbsd151amd64". Pur, exposé pour test.
    def self.jail_name(version : String, arch : String) : String
      "fbsd#{version.delete('.')}#{arch}"
    end

    # Alias par ABI : "FreeBSD:15:amd64". Pur.
    def self.alias_name(major : String, arch : String) : String
      "FreeBSD:#{major}:#{arch}"
    end

    # Nom du set poudriere : "fbsd151amd64-default". Pur.
    def self.set_name(version : String, arch : String, ports : String) : String
      "#{jail_name(version, arch)}-#{ports}"
    end

    # Fichier d'état des commits construits, à côté du lock et du log.
    def self.state_path(pkgdir : String, major : String) : String
      "#{pkgdir}/.beryl-build-#{major}.overlays"
    end

    # Reconstruit la version depuis un nom de set ("fbsd151amd64-default" +
    # major "15" → "15.1"). nil si le nom ne correspond pas. Pur.
    def self.set_version(setname : String, major : String, arch : String, ports : String) : String?
      suffix = "#{arch}-#{ports}"
      return nil unless setname.starts_with?("fbsd") && setname.ends_with?(suffix)
      digits = setname[4...(setname.size - suffix.size)]
      return nil unless digits.starts_with?(major)
      minor = digits[major.size..]
      minor.empty? ? nil : "#{major}.#{minor}"
    end

    # Fichier d'état → {nom => commit}. Pur.
    def self.parse_state(text : String) : Hash(String, String)
      h = {} of String => String
      text.each_line do |line|
        parts = line.split
        h[parts[0]] = parts[1] if parts.size >= 2
      end
      h
    end

    # Sortie de `poudriere ports -lq` → {arbre => chemin}. Pur.
    def self.parse_trees(text : String) : Hash(String, String)
      h = {} of String => String
      text.each_line do |line|
        parts = line.split
        h[parts.first] = parts.last if parts.size >= 2
      end
      h
    end

    # Script de build (lancé en détaché sur le builder). Pur, exposé pour test.
    # `overlays` : noms des arbres passés en `-O` ; `pkglists` : fichiers
    # passés en `-f` ; `commits` : {overlay => commit} écrit dans `state`
    # après succès (nil = pas d'état à écrire).
    def self.build_script(version : String, arch : String, ports : String,
                          overlays : Array(String), pkglists : Array(String), pkgdir : String,
                          reapply : String?, commits : Hash(String, String)? = nil,
                          state : String? = nil, ports_branch : String? = nil) : String
      major = version.split('.').first
      jail = jail_name(version, arch)
      set = set_name(version, arch, ports)
      ali = "#{pkgdir}/#{alias_name(major, arch)}"
      # reapply : ré-applique les patches quimeo sur l'arbre base APRÈS le pull
      # (ex. retirer du MOVED les ports expirés que l'overlay ré-introduit). On
      # lui passe le chemin de l'arbre ($PTDIR) et on PRÉVIENT dans le log s'il
      # est configuré mais absent/non exécutable (au lieu d'un skip silencieux).
      reapply_line =
        if reapply
          r = Process.quote(reapply)
          "if [ -x #{r} ]; then #{r} \"$PTDIR\"; else echo \"beryl: reapply absent ou non exécutable, patches base NON appliqués : #{reapply}\"; fi"
        else
          "true"
        end
      branch_block = ports_branch ? branch_script(ports_branch) : ""
      ov_args = overlays.map { |o| " -O #{Process.quote(o)}" }.join
      list_args = pkglists.map { |f| " -f #{Process.quote(f)}" }.join
      # État « construit » : écrit seulement ici, après un bulk et un
      # repointage réussis (`set -e` interrompt le script avant sinon).
      state_line =
        if commits && state
          lines = commits.map { |n, c| Process.quote("#{n} #{c}") }.join(" ")
          tmp = Process.quote("#{state}.tmp")
          "printf '%s\\n' #{lines} > #{tmp}\nmv -f #{tmp} #{Process.quote(state)}"
        else
          "true"
        end
      <<-SH
      #!/bin/sh
      set -eu
      if ! poudriere jail -l -q 2>/dev/null | awk '{print $1}' | grep -qx #{Process.quote(jail)}; then
        poudriere jail -c -j #{Process.quote(jail)} -v #{Process.quote("#{version}-RELEASE")} -a #{Process.quote(arch)}
      fi
      # Arbre de ports PROPRE avant le git pull : un `reapply` précédent laisse
      # des modifs non commitées → `poudriere ports -u` (git pull --rebase)
      # échoue (« You have unstaged changes »). On remet l'arbre à l'état git
      # (les patches seront ré-appliqués juste après par le reapply).
      PTDIR=$(poudriere ports -lq 2>/dev/null | awk -v p=#{Process.quote(ports)} '$1==p{print $NF}')
      [ -d "$PTDIR/.git" ] || PTDIR=/usr/local/poudriere/ports/#{Process.quote(ports)}
      if [ -d "$PTDIR/.git" ]; then
        git -C "$PTDIR" reset -q --hard 2>/dev/null || true
        git -C "$PTDIR" clean -qfd 2>/dev/null || true
      fi
      #{branch_block}poudriere ports -u -p #{Process.quote(ports)}
      #{reapply_line}
      poudriere bulk -j #{Process.quote(jail)} -p #{Process.quote(ports)}#{ov_args}#{list_args}
      ln -sfh #{Process.quote(set)} #{Process.quote(ali)}
      #{state_line}
      echo "poudriere-build #{version} OK ($(date -u +%FT%TZ))"
      SH
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      major = required_string(params, "major")
      arch = string(params, "arch") || "amd64"
      ports = string(params, "ports") || "default"
      pkgdir = string(params, "pkgdir") || DEFAULT_PKGDIR
      reapply = string(params, "reapply")
      ports_branch = string(params, "ports_branch").try(&.strip).presence
      if ports_branch && !ports_branch.matches?(/\A[A-Za-z0-9._\/-]+\z/)
        raise PrimitiveError.new("`ports_branch` invalide : #{ports_branch.inspect}")
      end
      # `force` : build lancé même si rien n'a changé (bascule de branche de
      # l'arbre de ports, reconstruction voulue). Booléen ou chaîne (valeur
      # interpolée d'un paramètre de recette : "true", "1", "yes", "oui").
      force = params["force"]?.try { |v| v.as_bool? || %w(true 1 yes oui).includes?(v.as_s?.try(&.strip.downcase) || "") } || false
      overlays = parse_overlays(params)
      pkglists = (overlays.compact_map(&.pkglist) + [string(params, "pkglist")].compact).uniq
      if pkglists.empty?
        raise MissingParam.new("aucune `pkglist` (par overlay ou au niveau du step) pour la primitive `#{name}`.")
      end

      alias_path = "#{pkgdir}/#{self.class.alias_name(major, arch)}"
      cur_set = shell.exec("readlink #{Process.quote(alias_path)} 2>/dev/null", raise_on_error: false).stdout.strip
      current = cur_set.empty? ? nil : self.class.set_version(cur_set, major, arch, ports)

      latest = begin
        self.class.release_lookup.call[major.to_i]?
      rescue
        nil
      end
      # Détection indisponible : on peut encore reconstruire la mineure
      # courante si un overlay a changé ; sans alias, rien à faire.
      target = latest || current
      return StepResult.skipped("détection FreeBSD indisponible — pas de build (majeur #{major})") if target.nil?
      if current && Beryl::FreebsdRelease.version_key(current) > Beryl::FreebsdRelease.version_key(target)
        target = current
      end
      new_minor = current.nil? || current != target

      # Lock AVANT toute mise à jour git : on ne touche pas aux arbres
      # pendant qu'un build les lit.
      lock = "#{pkgdir}/.beryl-build-#{major}.lock"
      if shell.exec("test -f #{Process.quote(lock)}", raise_on_error: false).success?
        return StepResult.skipped("build majeur #{major} déjà en cours (lock présent)")
      end

      trees = self.class.parse_trees(shell.exec("poudriere ports -lq 2>/dev/null", raise_on_error: false).stdout)
      states = [] of OverlayState
      overlays.each do |ov|
        st = sync_overlay(shell, ov, trees, dry_run)
        return st if st.is_a?(StepResult)
        states << st
      end

      # Build PLANIFIÉ (`schedule:`, format cron) : script + entrée cron.d
      # posés sur le builder, régénérés à chaque apply (la version visée suit).
      sched_notes = [] of String
      if schedule = string(params, "schedule")
        unless schedule.split.size == 5
          raise PrimitiveError.new("`schedule` attend 5 champs cron (ex. \"0 3 * * 0\"), reçu #{schedule.inspect}")
        end
        sched = states.map do |s|
          ScheduledOverlay.new(s.overlay.name, s.path, s.overlay.git ? (s.overlay.branch || "") : nil,
            !s.commit.nil? || s.fresh)
        end
        script = self.class.scheduled_script(target, arch, ports, sched, pkglists, pkgdir, reapply, ports_branch)
        if note = install_schedule(shell, major, schedule, script, pkgdir, dry_run)
          sched_notes << note
        end
      end

      state_file = self.class.state_path(pkgdir, major)
      built = self.class.parse_state(shell.exec("cat #{Process.quote(state_file)} 2>/dev/null", raise_on_error: false).stdout)
      changed = states.select { |s| s.fresh || ((c = s.commit) && built[s.overlay.name]? != c) }
      notes = states.flat_map(&.notes) + sched_notes
      infos = states.flat_map(&.infos)

      unless new_minor || !changed.empty? || force
        summary = states.map { |s| s.commit ? "#{s.overlay.name}@#{short(s.commit)}" : s.overlay.name }.join(", ")
        msg = "dépôt majeur #{major} déjà à jour sur #{current} (overlays inchangés : #{summary})"
        msg = "#{msg} ; #{infos.join(" ; ")}" unless infos.empty?
        return StepResult.skipped(msg) if notes.empty?
        return StepResult.applied("#{notes.join(" ; ")} ; #{msg}#{dry_run ? " (dry-run)" : ""}")
      end

      reasons = [] of String
      reasons << "FreeBSD #{target}#{current ? " (← #{current})" : " (initial)"}" if new_minor
      reasons << "forcé (force)" if force && !new_minor && changed.empty?
      changed.each do |s|
        prev = built[s.overlay.name]?
        reasons << "overlay #{s.overlay.name} #{prev ? short(prev) : "∅"} → #{s.commit ? short(s.commit) : "nouveau"}"
      end
      msg = "build #{reasons.join(", ")} [majeur #{major}, #{target}]"
      msg = "#{notes.join(" ; ")} ; #{msg}" unless notes.empty?
      msg = "#{msg} ; #{infos.join(" ; ")}" unless infos.empty?
      return StepResult.applied("#{msg} — serait lancé (dry-run)") if dry_run

      commits = {} of String => String
      states.each { |s| (c = s.commit) && (commits[s.overlay.name] = c) }
      script_path = "/tmp/beryl-poudriere-build-#{major}.sh"
      script = self.class.build_script(target, arch, ports, overlays.map(&.name), pkglists, pkgdir,
        reapply, commits, state_file, ports_branch)
      shell.write_file(script_path, script, "0755")
      # Lock AVANT lancement (les applies concurrents skippent). Le script
      # détaché retire le lock à la fin (succès ou échec).
      shell.exec("touch #{Process.quote(lock)}")
      log = "#{pkgdir}/.beryl-build-#{major}.log"
      # Détachement via `daemon -f` (FreeBSD n'a PAS `setsid`) : fork + nouvelle
      # session, survit à la fermeture SSH ; `daemon` rend la main aussitôt. Le
      # script redirige lui-même sa sortie vers `log` et retire le `lock` à la fin.
      shell.exec(
        "daemon -f sh -c 'sh #{Process.quote(script_path)} > #{Process.quote(log)} 2>&1; rm -f #{Process.quote(lock)}'; echo lancé",
      )
      StepResult.applied("#{msg} lancé en détaché — suivi : tail -f #{log}")
    end

    # `overlays:` (nouveau schéma) ou `overlay:` (ancien, un seul nom).
    private def parse_overlays(params : Hash(String, YAML::Any)) : Array(Overlay)
      raw = params["overlays"]?
      unless raw
        return [Overlay.new(string(params, "overlay") || "quimeo")]
      end
      if params.has_key?("overlay")
        raise PrimitiveError.new("`overlay:` et `overlays:` sont exclusifs (primitive `#{name}`).")
      end
      items = raw.as_a? || raise PrimitiveError.new("`overlays:` doit être une liste (primitive `#{name}`).")
      raise MissingParam.new("`overlays:` vide (primitive `#{name}`).") if items.empty?
      list = items.map do |item|
        if s = item.as_s?
          Overlay.new(validate_name(s))
        elsif h = item.as_h?
          f = {} of String => YAML::Any
          h.each { |k, v| (ks = k.as_s?) && (f[ks] = v) }
          Overlay.new(
            name: validate_name(string(f, "name") || raise MissingParam.new("overlay sans `name` (primitive `#{name}`).")),
            git: string(f, "git"), branch: string(f, "branch"),
            path: string(f, "path"), pkglist: string(f, "pkglist"))
        else
          raise PrimitiveError.new("entrée d'`overlays:` invalide : #{item.inspect} (primitive `#{name}`).")
        end
      end
      dup = list.map(&.name).tally.select { |_, c| c > 1 }.keys
      raise PrimitiveError.new("overlay(s) en double : #{dup.join(", ")}") unless dup.empty?
      list
    end

    private def validate_name(n : String) : String
      return n if n.matches?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
      raise PrimitiveError.new("nom d'overlay invalide : #{n.inspect} (primitive `#{name}`).")
    end

    # Clone / met à jour / enregistre un overlay ; renvoie son état, ou un
    # `StepResult` d'échec.
    # Fragment shell (dans `build_script`) qui place l'arbre de ports ($PTDIR)
    # sur la branche voulue. `quarterly` : trimestre courant calculé À
    # L'EXÉCUTION (date UTC), repli sur le précédent si la branche n'existe pas
    # encore. L'arbre poudriere est un clone superficiel à branche unique : la
    # branche est ajoutée aux refspecs (sans quoi `poudriere ports -u` ne la
    # mettrait jamais à jour), puis récupérée et suivie. Pur.
    def self.branch_script(ports_branch : String) : String
      pick =
        if ports_branch == "quarterly"
          <<-'SH'
          Y=$(date -u +%Y); M=$(date -u +%m); M=${M#0}; Q=$(( (M - 1) / 3 + 1 ))
          BR="${Y}Q${Q}"
          if ! git -C "$PTDIR" ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
            if [ "$Q" -eq 1 ]; then BR="$((Y - 1))Q4"; else BR="${Y}Q$((Q - 1))"; fi
          fi
          SH
        else
          "BR=#{Process.quote(ports_branch)}"
        end
      String.build do |io|
        io << pick << '\n'
        io << <<-'SH'
        if [ -d "$PTDIR/.git" ] && [ "$(git -C "$PTDIR" rev-parse --abbrev-ref HEAD)" != "$BR" ]; then
          git -C "$PTDIR" remote set-branches --add origin "$BR"
          git -C "$PTDIR" fetch -q --depth 1 origin "+refs/heads/$BR:refs/remotes/origin/$BR"
          git -C "$PTDIR" checkout -q -B "$BR" "origin/$BR"
          git -C "$PTDIR" branch -q --set-upstream-to="origin/$BR" "$BR"
          echo "beryl: arbre de ports $PTDIR basculé sur $BR"
        fi
        SH
        io << '\n'
      end
    end

    # Script du build PLANIFIÉ (cron) : le MÊME build que celui lancé par
    # `beryl apply` (`build_script`), précédé du verrou partagé et de la mise
    # à jour en avance rapide des overlays gérés par beryl, suivi de
    # l'enregistrement des commits réellement construits (lus à l'exécution).
    # Reconstruit la mineure visée au dernier apply ; une NOUVELLE mineure
    # reste l'affaire de `beryl apply` (qui régénère ce script). Pur.
    def self.scheduled_script(version : String, arch : String, ports : String,
                              overlays : Array(ScheduledOverlay), pkglists : Array(String),
                              pkgdir : String, reapply : String?, ports_branch : String? = nil) : String
      major = version.split('.').first
      lock = Process.quote("#{pkgdir}/.beryl-build-#{major}.lock")
      state = state_path(pkgdir, major)
      updates = overlays.compact_map do |o|
        next unless br = o.branch
        p = Process.quote(o.path)
        ref = br.empty? ? "\"$(git -C #{p} rev-parse --abbrev-ref HEAD)\"" : Process.quote(br)
        "git -C #{p} fetch -q origin #{ref}\ngit -C #{p} merge -q --ff-only FETCH_HEAD"
      end
      record_lines = overlays.select(&.tracked).map do |o|
        "printf '%s %s\\n' #{Process.quote(o.name)} \"$(git -C #{Process.quote(o.path)} rev-parse HEAD)\" >> \"$TMP\""
      end
      body = build_script(version, arch, ports, overlays.map(&.name), pkglists, pkgdir, reapply,
        ports_branch: ports_branch)
        .sub("#!/bin/sh\nset -eu\n", "")
      String.build do |io|
        io << "#!/bin/sh\n"
        io << "# Géré par beryl (poudriere-build, schedule) — build planifié du majeur #{major}.\n"
        io << "set -eu\n"
        io << "if [ -f #{lock} ]; then echo \"build majeur #{major} déjà en cours (lock) — rien à faire\"; exit 0; fi\n"
        io << "touch #{lock}\ntrap 'rm -f #{lock}' EXIT\n"
        updates.each { |u| io << u << '\n' }
        io << body.chomp << '\n'
        unless record_lines.empty?
          io << "TMP=#{Process.quote("#{state}.tmp")}\n: > \"$TMP\"\n"
          record_lines.each { |l| io << l << '\n' }
          io << "mv -f \"$TMP\" #{Process.quote(state)}\n"
        end
      end
    end

    # Pose (ou met à jour) le script planifié et son entrée cron.d. Renvoie une
    # note si quelque chose change, nil sinon. Un échec du build est signalé
    # par mail (sortie de cron → root → relais) ; le détail va dans le journal
    # des builds beryl.
    private def install_schedule(shell : Shell, major : String, schedule : String, script : String,
                                 pkgdir : String, dry_run : Bool) : String?
      script_path = "#{POUDRIERE_ETC}/beryl-build-#{major}.sh"
      cron_path = "#{CRON_DIR}/beryl-poudriere-#{major}"
      log = "#{pkgdir}/.beryl-build-#{major}.log"
      cron = "# Géré par beryl (poudriere-build, schedule) — build planifié du majeur #{major}.\n" \
             "SHELL=/bin/sh\n" \
             "#{schedule} root /bin/sh #{script_path} > #{log} 2>&1 || echo \"build poudriere #{major} en échec — voir #{log}\"\n"
      changed = [] of String
      {script_path => {script, "0755"}, cron_path => {cron, "0644"}}.each do |path, (content, mode)|
        current = shell.exec("cat #{Process.quote(path)} 2>/dev/null", raise_on_error: false).stdout
        next if current == content
        changed << path
        shell.write_file(path, content, mode) unless dry_run
      end
      changed.empty? ? nil : "build planifié « #{schedule} » → #{changed.join(", ")}"
    end

    private def sync_overlay(shell : Shell, ov : Overlay, trees : Hash(String, String), dry_run : Bool) : OverlayState | StepResult
      registered = trees[ov.name]?
      if (p = ov.path) && registered && registered != p
        return StepResult.failed("overlay #{ov.name} : déjà enregistré dans poudriere sur #{registered}, pas sur #{p}")
      end
      path = ov.path || registered || "#{OVERLAY_ROOT}/#{ov.name}-ports"
      notes = [] of String
      infos = [] of String
      commit : String? = nil
      fresh = false
      is_git = shell.exec("test -d #{Process.quote("#{path}/.git")}", raise_on_error: false).success?

      if url = ov.git
        if is_git
          r = update_git(shell, ov, path, dry_run, notes, infos)
          return r if r.is_a?(StepResult)
          commit = r
        else
          if shell.exec("test -e #{Process.quote(path)}", raise_on_error: false).success?
            return StepResult.failed("overlay #{ov.name} : #{path} existe mais n'est pas un dépôt git — refus de l'écraser")
          end
          branch_opt = ov.branch.try { |b| " -b #{Process.quote(b)}" } || ""
          notes << "clone #{url}#{ov.branch.try { |b| " (#{b})" }} → #{path}"
          if dry_run
            fresh = true
          else
            res = shell.exec("git clone -q#{branch_opt} #{Process.quote(url)} #{Process.quote(path)}", raise_on_error: false)
            return StepResult.failed("overlay #{ov.name} : git clone a échoué : #{first_line(res)}") unless res.success?
            commit = head(shell, path)
          end
        end
      elsif is_git
        # Overlay non géré par beryl : on suit seulement son commit.
        commit = head(shell, path)
      end

      unless registered
        exists = fresh || commit || shell.exec("test -d #{Process.quote(path)}", raise_on_error: false).success?
        unless exists
          return StepResult.failed("overlay #{ov.name} introuvable : ni enregistré dans poudriere, ni présent sur #{path} (ajoutez `git:` pour le cloner)")
        end
        notes << "enregistrement poudriere #{ov.name} → #{path}"
        unless dry_run
          res = shell.exec("poudriere ports -c -p #{Process.quote(ov.name)} -m null -M #{Process.quote(path)}", raise_on_error: false)
          return StepResult.failed("overlay #{ov.name} : enregistrement poudriere échoué : #{first_line(res)}") unless res.success?
        end
      end

      OverlayState.new(ov, path, commit, fresh, notes, infos)
    end

    # Mise à jour d'un clone existant en avance rapide. Renvoie le commit
    # qui sera construit, ou un `StepResult` d'échec (rien n'est écrasé).
    private def update_git(shell : Shell, ov : Overlay, path : String, dry_run : Bool, notes : Array(String), infos : Array(String)) : String | StepResult
      g = "git -C #{Process.quote(path)}"
      cur_branch = shell.exec("#{g} symbolic-ref -q --short HEAD", raise_on_error: false).stdout.strip
      return StepResult.failed("overlay #{ov.name} : HEAD détachée dans #{path} — à remettre sur une branche") if cur_branch.empty?
      branch = ov.branch || cur_branch
      if branch != cur_branch
        return StepResult.failed("overlay #{ov.name} : #{path} est sur la branche #{cur_branch}, pas #{branch} — à basculer à la main")
      end
      dirty = shell.exec("#{g} status --porcelain --untracked-files=no", raise_on_error: false).stdout.strip
      unless dirty.empty?
        files = dirty.lines.map { |l| l.strip.split.last? || l }.first(5).join(", ")
        return StepResult.failed("overlay #{ov.name} : modifications locales non commitées dans #{path} (#{files}) — commitez/poussez-les ou annulez-les ; beryl ne les écrase pas")
      end
      local = head(shell, path)
      return StepResult.failed("overlay #{ov.name} : commit courant illisible dans #{path}") unless local

      if dry_run
        res = shell.exec("#{g} ls-remote origin #{Process.quote("refs/heads/#{branch}")}", raise_on_error: false)
        remote = res.stdout.split.first?
        return StepResult.failed("overlay #{ov.name} : branche distante #{branch} illisible (git ls-remote) : #{first_line(res)}") if !res.success? || remote.nil?
        return local if remote == local
        if shell.exec("#{g} merge-base --is-ancestor #{remote} HEAD", raise_on_error: false).success?
          infos << "overlay #{ov.name} : commits locaux non poussés (conservés)"
          return local
        end
        notes << "overlay #{ov.name} : serait mis à jour #{short(local)} → #{short(remote)} (avance rapide)"
        return remote
      end

      ref = "refs/remotes/origin/#{branch}"
      res = shell.exec("#{g} fetch -q origin #{Process.quote("+refs/heads/#{branch}:#{ref}")}", raise_on_error: false)
      return StepResult.failed("overlay #{ov.name} : git fetch a échoué : #{first_line(res)}") unless res.success?
      remote = shell.exec("#{g} rev-parse #{Process.quote(ref)}", raise_on_error: false).stdout.strip
      return StepResult.failed("overlay #{ov.name} : #{ref} introuvable après fetch") if remote.empty?
      return local if remote == local

      if shell.exec("#{g} merge-base --is-ancestor HEAD #{Process.quote(ref)}", raise_on_error: false).success?
        m = shell.exec("#{g} merge -q --ff-only #{Process.quote(ref)}", raise_on_error: false)
        return StepResult.failed("overlay #{ov.name} : avance rapide impossible : #{first_line(m)}") unless m.success?
        notes << "overlay #{ov.name} mis à jour #{short(local)} → #{short(remote)}"
        return remote
      end
      if shell.exec("#{g} merge-base --is-ancestor #{Process.quote(ref)} HEAD", raise_on_error: false).success?
        infos << "overlay #{ov.name} : commits locaux non poussés (conservés)"
        return local
      end
      StepResult.failed("overlay #{ov.name} : historique divergé entre #{path} (#{short(local)}) et origin/#{branch} (#{short(remote)}) — à réconcilier à la main ; beryl n'écrase rien")
    end

    private def head(shell : Shell, path : String) : String?
      out = shell.exec("git -C #{Process.quote(path)} rev-parse HEAD", raise_on_error: false).stdout.strip
      out.empty? ? nil : out
    end

    private def short(commit : String?) : String
      (commit || "?")[0, 7]
    end

    private def first_line(res : SSH::Result) : String
      text = res.stderr.strip.empty? ? res.stdout : res.stderr
      text.lines.map(&.strip).reject(&.empty?).first? || "pas de message"
    end
  end

  Primitive.register(PoudriereBuild.new)
end
