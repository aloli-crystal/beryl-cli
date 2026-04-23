require "option_parser"
require "../config"
require "../bootstrap/qemu_in_rescue"
require "ssh"
require "./account_utils"

# Sous-commande `beryl follow-install <host>` : tail en direct du log
# `bsdinstall` dans la VM mfsBSD pendant un `beryl bootstrap` en cours.
#
# **Pourquoi cette commande existe** : le bootstrap ouvre une VM QEMU
# sur le rescue Linux, qui elle-même exécute `bsdinstall`. Pour suivre
# la progression, il faut ssh jusqu'au rescue, puis depuis le rescue
# ssh vers la VM (password `mfsroot` — c'est un secret public du mfsBSD
# SE), puis `tail -f /tmp/bsdinstall.log`.
#
# En copier-coller manuel, la commande dépendait implicitement du
# `~/.ssh/config` de l'utilisateur pour résoudre la clé SSH vers le
# rescue. Depuis l'isolation SSH du 0.1.8 (shard `crystal-ssh`), beryl
# n'utilise plus `~/.ssh/config` et le copie-coller ne serait donc plus
# portable. Cette sous-commande porte toute la résolution elle-même :
# clé via `SSH::KeyStore` + convention Aloli, user depuis le merge,
# password mfsbsd en dur.
module Beryl::CLI::FollowInstall
  EXIT_OK         = 0
  EXIT_USAGE      = 1
  EXIT_SSH_FAILED = 2
  EXIT_UNEXPECTED = 3

  def self.run(config_root : String, args : Array(String)) : Int32
    account_hint : String? = nil
    domain_hint : String? = nil
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "USAGE : beryl follow-install <host> [options]"
      p.on("-a NAME", "--account=NAME", "Forcer la société (si ambiguë)") { |v| account_hint = v }
      p.on("-d NAME", "--domain=NAME", "Forcer le domaine") { |v| domain_hint = v }
      p.on("-h", "--help", "Aide") { puts p; exit 0 }
      p.unknown_args { |rest, _| positional = rest }
    end
    parser.parse(args)

    raw = positional.first?
    unless raw
      STDERR.puts "beryl : hôte non précisé. USAGE : beryl follow-install <host>"
      return EXIT_USAGE
    end

    parsed = Beryl::CLI::AccountUtils.split_host_path(raw)
    host_name = parsed[:host]
    account_hint ||= parsed[:account]
    domain_hint ||= parsed[:domain]

    root = Beryl::Config::Root.load(config_root)
    host = root.resolve(host_name, account_hint: account_hint, domain_hint: domain_hint)

    # Construit la commande shell exécutée CÔTÉ RESCUE : attente de
    # l'apparition du log dans la VM, puis tail avec filtre de bruit.
    vm_cmd = build_vm_command
    conn = host.connection
    ssh_args = conn.ssh_args(vm_cmd)

    log "connexion au rescue #{Beryl.format_ssh_target(host)} puis tunnel vers VM mfsBSD (port #{Beryl::Bootstrap::QemuInRescue::VM_SSH_PORT})..."
    log "Ctrl-C pour arrêter."
    log ""

    status = Process.run(
      command: "ssh",
      args: ssh_args,
      output: STDOUT,
      error: STDERR,
      input: STDIN,
    )
    status.success? ? EXIT_OK : EXIT_SSH_FAILED
  rescue ex : Beryl::Config::Root::HostNotFound
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::AmbiguousHost
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex : Beryl::Config::Root::UnknownDomain
    STDERR.puts "beryl : #{ex.message}"
    EXIT_USAGE
  rescue ex
    STDERR.puts "beryl : erreur inattendue — #{ex.class}: #{ex.message}"
    EXIT_UNEXPECTED
  end

  # Commande shell exécutée sur le rescue Linux. Elle lance sshpass
  # pour se connecter dans la VM QEMU (127.0.0.1:2223), attend que le
  # log bsdinstall existe, puis le tail en filtrant les lignes
  # `DEBUG:` très verbeuses de bsdinstall (dialog, variables,
  # périphériques, etc.).
  #
  # Exposée publiquement pour permettre aux specs de vérifier la
  # construction sans lancer de ssh réel.
  def self.build_vm_command : String
    port = Beryl::Bootstrap::QemuInRescue::VM_SSH_PORT
    vm_host = Beryl::Bootstrap::QemuInRescue::VM_SSH_HOST
    vm_pwd = Beryl::Bootstrap::QemuInRescue::MFSBSD_ROOT_PASSWORD
    log_file = Beryl::Bootstrap::QemuInRescue::VM_BSDINSTALL_LG

    # Filtre le bruit de debug de bsdinstall (dialog, variables,
    # devices, geom, strings, frameworks f_*, init, ARGV, UNAME_S).
    noise = %q{DEBUG: (dialog\.|common\.|struct\.|variable\.|device\.|geom\.|strings\.|password/|f_dialog|f_debug|f_include|f_variable|f_getvar)|DEBUG_SELF_INITIALIZE|UNAME_S=|ARGV=}

    vm_inner = "while [ ! -f #{log_file} ]; do sleep 2; done; " \
               "tail -f #{log_file} | grep --line-buffered -vE #{Process.quote(noise)}"

    "sshpass -p #{Process.quote(vm_pwd)} " \
    "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " \
    "-o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no " \
    "-p #{port} root@#{vm_host} #{Process.quote(vm_inner)}"
  end

  private def self.log(message : String) : Nil
    STDERR.puts "[#{Beryl.format_timestamp(Time.local)}] [beryl follow-install] #{message}"
  end
end
