require "../primitive"

module Beryl::Apply
  # Primitive `pkg-upgrade` : met à jour une liste FERMÉE de paquets
  # (seulement ceux qui sont installés) puis relance les services qui en
  # dépendent. Conçue pour les paquets maison publiés par poudriere
  # (ex. une application et ses scripts rc.d qui migrent au démarrage) :
  # beryl est le seul à mettre à jour ces paquets sur les serveurs.
  #
  #     - pkg-upgrade:
  #         packages: [myapp, myapp-worker]    # obligatoire, non vide
  #         restart: [myapp]                   # optionnel
  #
  # Lecture de l'état (idempotence) :
  #
  # . `pkg update -q` rafraîchit le catalogue (sinon « à jour » ne veut rien
  #   dire) ; fait aussi en dry-run : ne touche que le cache du catalogue,
  #   jamais les paquets installés.
  # . `pkg info -e <p>` : un paquet listé mais NON installé est ignoré
  #   (rapporté) — un serveur peut n'avoir que `monappli`.
  # . `pkg version -URv -l '<'` : les paquets installés plus anciens que le
  #   catalogue distant, avec la version disponible (« needs updating (remote
  #   has X) »). Choisi plutôt que d'analyser `pkg upgrade -n` : c'est la
  #   comparaison de versions de pkg lui-même (epoch, `_n`, `,n`), sortie
  #   ligne à ligne stable, VIDE quand tout est à jour — alors que
  #   `pkg upgrade -n` mêle dépendances, résumé et formulations variables
  #   (« Your packages are up to date. ») et sort en 1 dès qu'il y a quelque
  #   chose à faire.
  #
  # Rien à mettre à jour → Skipped. Sinon, en dry-run : plan (paquets
  # de → vers, services qui seraient relancés). En `--apply` :
  # `pkg upgrade -r <dépôt> -y <paquets en retard>`, un par dépôt d'origine
  # (`%R`) des paquets (pkg peut entraîner des dépendances : c'est normal),
  # puis `service <svc> restart` pour chaque
  # service de `restart` ACTIVÉ (`sysrc -n <svc>_enable` = YES, casse
  # ignorée) ; un service non activé est sauté et rapporté. Échec du
  # `pkg upgrade` ou d'un redémarrage → Failed (les autres services sont
  # tout de même tentés, pour ne pas laisser la moitié du parc arrêtée).
  #
  # Pourquoi `-r` : un paquet offert par deux dépôts (gmp, mpfr… republiés
  # par poudriere dans le dépôt maison, copies de FreeBSD-ports) échappe
  # sinon à la règle « ne pas installer ce qui n'est pas installé » du
  # solveur de pkg (posée seulement quand il n'en existe qu'UNE variante,
  # libpkg/pkg_solve.c) : pkg l'installait sans que rien ne le réclame
  # (loulou, quantas, 27 oct. 2026 ; même remède que `beryl upgrade`). Un
  # paquet absent de son dépôt d'origine mais disponible ailleurs : sans
  # `-r`.
  class PkgUpgrade < Primitive
    # Paquet en retard : nom, version installée, version disponible.
    record Outdated, name : String, from : String, to : String

    def name : String
      "pkg-upgrade"
    end

    # Analyse la sortie de `pkg version -URv -l '<'` et ne garde que les
    # paquets de `wanted`. Une ligne vaut
    # `monappli-1.2.3     <   needs updating (remote has 1.2.4)`.
    # Le nom se déduit en retirant le dernier `-<version>` (une version pkg
    # ne contient pas de tiret ; un nom, si : `monappli-devel`). Pur.
    def self.parse_outdated(output : String, wanted : Array(String)) : Array(Outdated)
      result = [] of Outdated
      output.each_line do |line|
        namever = line.split.first?
        next unless namever
        idx = namever.rindex('-')
        next unless idx
        pkg = namever[0...idx]
        next unless wanted.includes?(pkg)
        to = line.match(/has ([^)\s]+)\)/).try(&.[1]) || "?"
        result << Outdated.new(pkg, namever[(idx + 1)..], to)
      end
      result
    end

    # Groupes `{dépôt, paquets}` pour `pkg upgrade` : dépôt d'origine de
    # chaque paquet (`pkg query '%n %R'`) s'il l'offre encore (`pkg rquery -a
    # '%n %R'`), sinon nil (`pkg upgrade` sans `-r`). Ordre de `names`. Pur.
    def self.upgrade_groups(names : Array(String), installed : String, remote : String) : Array({String?, Array(String)})
      origin = installed.lines.compact_map { |l| a = l.split; {a[0], a[1]} if a.size >= 2 }.to_h
      offered = remote.lines.compact_map { |l| a = l.split; {a[0], a[1]} if a.size >= 2 }.to_set
      groups = [] of {String?, Array(String)}
      names.each do |n|
        repo = origin[n]?.try { |r| r if offered.includes?({n, r}) }
        if g = groups.find { |(r, _)| r == repo }
          g[1] << n
        else
          groups << {repo, [n]}
        end
      end
      groups
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      packages = string_array(params, "packages").map(&.strip).reject(&.empty?).uniq
      if packages.empty?
        raise MissingParam.new("paramètre `packages` obligatoire (liste non vide) pour la primitive `#{name}`.")
      end
      restart = string_array(params, "restart").map(&.strip).reject(&.empty?).uniq

      upd = shell.exec("pkg update -q", raise_on_error: false)
      unless upd.success?
        return StepResult.failed("pkg update a échoué (catalogue injoignable ?) : #{first_line(upd)}")
      end

      installed = packages.select do |p|
        Primitive.probe?(shell, "pkg info -e #{Process.quote(p)}")
      end
      absent = packages - installed
      absent_note = absent.empty? ? "" : " ; non installé(s), ignoré(s) : #{absent.join(", ")}"
      return StepResult.skipped("aucun des paquets n'est installé (#{packages.join(", ")})") if installed.empty?

      ver = shell.exec("pkg version -URv -l '<'", raise_on_error: false)
      outdated = self.class.parse_outdated(ver.stdout, installed)
      if outdated.empty?
        return StepResult.skipped("#{installed.join(", ")} à jour#{absent_note}")
      end

      plan = outdated.map { |o| "#{o.name} #{o.from} → #{o.to}" }.join(", ")
      enabled, disabled = restart.partition { |svc| enabled?(shell, svc) }
      skipped_note = disabled.empty? ? "" : " ; service(s) non activé(s), non relancé(s) : #{disabled.join(", ")}"
      svc_note = ->(verb : String) { (enabled.empty? ? "" : " ; #{verb} : #{enabled.join(", ")}") + skipped_note }

      return StepResult.applied("mettrait à jour #{plan}#{svc_note.call("relancerait")}#{absent_note} (dry-run)") if dry_run

      names = outdated.map(&.name)
      quoted = names.map { |n| Process.quote(n) }.join(" ")
      installed_repos = Primitive.read_probe(shell, "pkg query '%n %R' #{quoted}").stdout
      remote_repos = Primitive.read_probe(shell, "pkg rquery -a '%n %R' #{quoted}").stdout
      self.class.upgrade_groups(names, installed_repos, remote_repos).each do |repo, group|
        from = repo ? "-r #{Process.quote(repo)} " : ""
        res = shell.exec("pkg upgrade #{from}-y #{group.map { |n| Process.quote(n) }.join(" ")}", raise_on_error: false)
        unless res.success?
          return StepResult.failed("pkg upgrade a échoué (code #{res.exit_code}) pour #{group.join(", ")} : #{first_line(res)} — aucun service relancé")
        end
      end

      failures = [] of String
      enabled.each do |svc|
        r = shell.exec(Primitive.service_command(svc, "restart"), raise_on_error: false)
        failures << "#{svc} (code #{r.exit_code} : #{first_line(r)})" unless r.success?
      end
      unless failures.empty?
        return StepResult.failed(
          "mis à jour #{plan}, mais redémarrage en échec : #{failures.join(", ")} — " \
          "consultez le journal du service (ou de l'instance) pour la cause")
      end

      StepResult.applied("mis à jour #{plan}#{svc_note.call("relancé(s)")}#{absent_note}")
    end

    # `sysrc -n <svc>_enable` vaut-il YES (casse ignorée) ? Variable absente
    # → non activé.
    private def enabled?(shell : Shell, svc : String) : Bool
      Primitive.read_probe(shell, "sysrc -n #{Process.quote("#{svc}_enable")} 2>/dev/null")
        .stdout.strip.upcase == "YES"
    end

    # Première ligne non vide de stderr (sinon stdout) pour un message court.
    private def first_line(res : SSH::Result) : String
      text = res.stderr.strip.empty? ? res.stdout : res.stderr
      text.lines.map(&.strip).reject(&.empty?).first? || "pas de message"
    end
  end

  Primitive.register(PkgUpgrade.new)
end
