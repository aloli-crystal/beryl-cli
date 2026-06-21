require "../../beryl"

# Auto-commit des écritures de beryl dans le dépôt git de config société.
#
# Contexte : le dépôt `~/.config/beryl/<société>/` (ex: acme/beryl-config)
# est versionné. Toute commande beryl qui ÉCRIT dans ce dépôt (`scan
# --write`, `add-domain`, `env migrate/edit`, …) doit committer le
# changement pour qu'il ne soit pas perdu/oublié (constaté le 9 juin
# 2026 sur qgra : config disques corrigée à la main, jamais commitée).
#
# UX : commit automatique par défaut, avec un message parlant. Chaque
# writer expose un flag `--no-commit` pour s'abstenir (CI, édition en
# rafale, etc.).
#
# Sécurité : `git add` respecte le `.gitignore` du dépôt. Un fichier
# ignoré (typiquement `.env.yml` en clair) n'est JAMAIS stagé, même
# nommé explicitement — on ne force jamais avec `-f`. Le commit ne
# portera donc jamais de secret en clair. Seul le coffre chiffré
# `.env.toml.age` (commitable) finit versionné.
module Beryl::CLI::ConfigGit
  extend self

  # Remonte depuis `path` (fichier ou dossier) jusqu'à trouver la racine
  # d'un dépôt git — présence d'un `.git`, dossier OU fichier (un
  # worktree git matérialise `.git` sous forme de fichier). Retourne le
  # chemin absolu de la racine, ou `nil` si `path` n'est sous aucun
  # dépôt.
  def repo_root_for(path : String) : String?
    current = File.expand_path(path)
    current = File.dirname(current) unless File.directory?(current)
    loop do
      return current if File.exists?(File.join(current, ".git"))
      parent = File.dirname(current)
      return nil if parent == current # racine du filesystem atteinte
      current = parent
    end
  end

  # Commite `paths` dans le dépôt qui les contient, avec `message`.
  #
  #   - `no_commit: true`            → ne fait rien (log explicite).
  #   - paths hors de tout dépôt git → log « pas un dépôt git, skip commit ».
  #   - rien à stager (écriture idempotente, ou fichier gitignore comme
  #     `.env.yml` en clair) → log « rien à committer ».
  #   - sinon → `git add` puis `git commit -m <message>` (scopé aux paths).
  #
  # `git add` peut renvoyer un code non-nul si un chemin est gitignore :
  # les autres chemins sont tout de même stagés. On ignore donc son code
  # retour et on laisse `git diff --cached` faire foi sur ce qui sera
  # réellement commité.
  def commit(paths : Array(String), message : String, no_commit : Bool) : Nil
    if no_commit
      log "--no-commit : #{joined(paths)} écrit mais NON commité"
      return
    end
    return if paths.empty?

    root = repo_root_for(paths.first)
    unless root
      log "#{joined(paths)} : pas un dépôt git, skip commit"
      return
    end

    run_git(root, ["add", "--"] + paths)

    # `git diff --cached --quiet` : exit 0 = rien de stagé pour nos
    # chemins → écriture idempotente (ou tout gitignore), on n'a rien à
    # committer. Évite l'erreur « nothing to commit » de git.
    diff, _ = run_git(root, ["diff", "--cached", "--quiet", "--"] + paths)
    if diff.success?
      log "rien à committer (#{File.basename(root)} déjà à jour)"
      return
    end

    status, err = run_git(root, ["commit", "-m", message, "--"] + paths)
    if status.success?
      log "commité dans #{File.basename(root)} : #{message}"
    else
      log "échec du commit git (#{File.basename(root)}) — modification écrite mais NON commitée#{err.empty? ? "" : " : #{err.strip}"}"
    end
  rescue ex : IO::Error
    # git absent du PATH, droits, etc. : on a déjà écrit le fichier, on
    # ne casse pas la commande pour autant.
    log "git indisponible (#{ex.message}) — modification écrite mais NON commitée"
  end

  private def run_git(root : String, args : Array(String)) : {Process::Status, String}
    err = IO::Memory.new
    status = Process.run(
      "git",
      ["-C", root] + args,
      output: Process::Redirect::Close,
      error: err,
      input: Process::Redirect::Close,
    )
    {status, err.to_s}
  end

  private def joined(paths : Array(String)) : String
    paths.map { |p| File.basename(p) }.join(", ")
  end

  private def log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl git] #{message}"
  end
end
