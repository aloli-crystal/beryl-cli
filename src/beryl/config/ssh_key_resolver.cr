module Beryl::Config
  # Dossier par défaut où vivent les clés publiques SSH côté opérateur.
  # Toutes les clés SSH référencées par nom dans les YAML sont cherchées
  # ici. Philippe, 22 avril 2026 : « Toutes les clés sont
  # systématiquement dans ~/.ssh pourquoi coder un chemin ? ».
  DEFAULT_SSH_DIR = File.expand_path("~/.ssh", home: true)

  # Résout une entrée `ssh_keys:` vers le contenu effectif à poser
  # dans `authorized_keys` côté serveur.
  #
  # Deux formes reconnues automatiquement :
  #
  #   1. Clé inline (commence par `ssh-`) :
  #        - ssh-ed25519 AAAAC3... philippe@aloli.fr
  #      Utilisée telle quelle, après `.strip`.
  #
  #   2. Nom de fichier (tout le reste, typiquement `nom.pub`) :
  #        - philippe.aloli.fr.pub
  #      Cherché dans `ssh_dir` (défaut `~/.ssh/`). On lit la première
  #      ligne non vide et non commentée du fichier.
  #
  # Permet à l'opérateur d'éviter la duplication (une clé vit à un
  # seul endroit : `~/.ssh/nom.pub`) et facilite la rotation : on
  # ajoute une 2ème entrée `ssh_keys:` temporairement pour déployer
  # la nouvelle clé, puis on retire l'ancienne ligne.
  def self.resolve_ssh_key(value : String, ssh_dir : String = DEFAULT_SSH_DIR) : String
    trimmed = value.strip
    return trimmed if trimmed.starts_with?("ssh-")
    path = File.join(ssh_dir, trimmed)
    unless File.exists?(path)
      raise SshKeyNotFound.new(
        "clé SSH introuvable : #{ssh_dir}/#{trimmed}. " \
        "Vérifiez que le fichier existe ou passez la clé inline (ssh-ed25519 AAAA...)."
      )
    end
    content = File.read_lines(path).map(&.strip).find { |l| !l.empty? && !l.starts_with?('#') }
    raise SshKeyEmpty.new("fichier de clé SSH vide : #{path}") unless content
    content
  end

  # Résout une liste d'entrées `ssh_keys:` en liste de clés effectives.
  # Helper pratique, signalement au premier échec.
  def self.resolve_ssh_keys(values : Array(String), ssh_dir : String = DEFAULT_SSH_DIR) : Array(String)
    values.map { |v| resolve_ssh_key(v, ssh_dir) }
  end

  class SshKeyNotFound < Exception
  end

  class SshKeyEmpty < Exception
  end
end
