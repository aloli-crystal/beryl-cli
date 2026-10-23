require "../primitive"

module Beryl::Apply
  # Primitive `pkg-versioned` : installe un paquet FreeBSD versionné du type
  # `<base><NN>-<composant>` (mariadb, postgresql, mysql…). Idempotente.
  #
  #     - pkg-versioned:
  #         base: mariadb
  #         version: latest      # défaut ; ou un numéro FreeBSD : 114, 1011…
  #         only: server         # optionnel : `server` ou `client`
  #         server_package: postgresql18-server-aloli   # optionnel, cf. plus bas
  #
  # Sans `only` → installe `server` ET `client`. `version: latest` (ou
  # absent) → résolu par la VRAIE version (`pkg rquery '%v %n' | sort -V`),
  # car l'encodage FreeBSD sans point piège un tri des noms (mariadb 10.11
  # = `1011` se classerait après 11.4 = `114`). Capacité ÉTROITE : installer
  # un paquet versionné, rien d'autre.
  #
  # `latest` ne vaut qu'à la PREMIÈRE installation : si une version majeure
  # est déjà en place (`<base>NN-server` ou `-client`), elle est gardée. Sinon
  # `pkg install` de la majeure suivante remplacerait le paquet (conflit) et le
  # cluster existant (`/var/db/postgres/data18`) ne serait plus servi : le
  # serveur repartirait sur un data dir vide, ou ne démarrerait pas. Une montée
  # de majeure est une migration (pg_upgrade, mariadb-upgrade), pas un apply.
  #
  # `server_package` : NOM EXACT du serveur, à la place de `<base>NN-server` —
  # un paquet maison de la même majeure (options différentes, ex. PostgreSQL
  # sans JIT), le client restant l'officiel. Exige une `version` explicite (un
  # paquet maison n'existe que pour SA majeure) et un nom qui commence par
  # `<base><version>-server`. Remplacer le serveur officiel déjà installé par
  # le maison est le travail de la recette (arrêt, retrait, installation,
  # redémarrage) : ici, on ne fait qu'installer ce qui manque.
  class PkgVersioned < Primitive
    def name : String
      "pkg-versioned"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      base = required_string(params, "base")
      version = (string(params, "version") || "latest")
      version = "latest" if version.empty?
      only = string(params, "only").try(&.lchop(':')) # tolère `:server`

      components =
        case only
        when "server" then ["server"]
        when "client" then ["client"]
        else               ["server", "client"]
        end

      num =
        if version == "latest" && (kept = installed_major(shell, base))
          kept
        elsif version == "latest"
          resolved = resolve_latest(shell, base)
          return StepResult.failed("aucun paquet #{base}*-server dans le dépôt (réseau ? pkg update ?)") unless resolved
          resolved
        else
          version
        end

      server_package = string(params, "server_package").try(&.strip).presence
      if sp = server_package
        if version == "latest"
          return StepResult.failed("`server_package` (#{sp}) exige une `version` explicite : un paquet maison n'existe que pour sa majeure")
        end
        unless sp.starts_with?("#{base}#{version}-server")
          return StepResult.failed("`server_package` #{sp} n'est pas un serveur #{base}#{version} (attendu : #{base}#{version}-server…)")
        end
      end

      packages = components.map { |c| c == "server" && server_package ? server_package : "#{base}#{num}-#{c}" }
      missing = packages.reject { |p| Primitive.probe?(shell, "pkg info -e #{Process.quote(p)}") }
      return StepResult.skipped("#{packages.join(", ")} déjà installé(s)") if missing.empty?
      return StepResult.applied("installerait #{missing.join(", ")} (dry-run)") if dry_run

      shell.exec("pkg install -y #{missing.map { |p| Process.quote(p) }.join(" ")}")
      StepResult.applied("installé : #{missing.join(", ")}")
    end

    # Numéro de version (encodé FreeBSD) d'un `<base>NN-server`/`-client`
    # déjà installé ; le serveur prime sur le client. nil si aucun.
    private def installed_major(shell : Shell, base : String) : String?
      names = shell.exec("pkg query '%n'", raise_on_error: false).stdout.lines.map(&.strip)
      # Suffixe toléré : un serveur maison (`postgresql18-server-aloli`) compte.
      pattern = /^#{Regex.escape(base)}(\d+)-(server|client)(?:-[A-Za-z0-9_.]+)?$/
      found = names.compact_map { |n| n.match(pattern) }
      (found.find { |m| m[2] == "server" } || found.first?).try(&.[1])
    end

    # Numéro de version (encodé FreeBSD) du `<base>NN-server` le plus récent
    # du dépôt, déterminé sur la VRAIE version (%v), pas le nom. nil si aucun.
    private def resolve_latest(shell : Shell, base : String) : String?
      # Catalogue rafraîchi d'abord : `rquery -U` n'interroge que les
      # catalogues déjà téléchargés — un dépôt tout juste ajouté (ex. par une
      # recette `pkg-repo-*` dans le même apply) ferait échouer la requête et
      # la réponse serait vide (constaté sur un serveur neuf le 6 oct. 2026).
      shell.exec("pkg update -q", raise_on_error: false)
      line = shell.exec(
        "pkg rquery -U '%v %n' | awk '$2 ~ /^#{base}[0-9]+-server$/' | sort -V | tail -1",
        raise_on_error: false,
      ).stdout.strip
      return if line.empty?
      pkg_name = line.split(' ').last? || ""
      if m = pkg_name.match(/^#{Regex.escape(base)}(\d+)-server$/)
        m[1]
      end
    end
  end

  Primitive.register(PkgVersioned.new)
end
