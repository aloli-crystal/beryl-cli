require "../config"
require "../ssh"

# Vérifications préalables à `beryl bootstrap` : s'assure que la
# config YAML est cohérente ET que les disques déclarés correspondent
# bien à ceux physiquement présents sur le serveur en rescue.
#
# Les commandes `bootstrap` et `bootstrap --dry-run` passent toutes
# les deux par `Precheck.run`. Seul `--force` bypass les vérifs
# disques (pas la validation config YAML, qui reste gratuite et
# sans danger).
module Beryl::CLI::Precheck
  # Résultat d'un précheck : succès + disques détectés, ou liste
  # d'erreurs/avertissements. Pas d'exception : on laisse l'appelant
  # décider du code de sortie et du log.
  struct Result
    getter ok : Bool
    getter detected_disks : Array(String) # noms courts (sda, sdb, …)
    getter errors : Array(String)
    getter warnings : Array(String)

    def initialize(@ok, @detected_disks, @errors, @warnings)
    end
  end

  # Enchaîne :
  # 1. Validation config ZFS (au moins 1 pool, pas de disque en
  #    double, raid/disks compatibles, etc.)
  # 2. Test SSH rescue (uname -s = Linux)
  # 3. Listing des disques physiques (lsblk)
  # 4. Comparaison YAML vs physique
  def self.run(
    host : Beryl::Config::ResolvedHost,
    conn : Beryl::SSH::Connection,
  ) : Result
    errors = [] of String
    warnings = [] of String
    detected = [] of String

    # 1. Validation config
    begin
      host.validate_zfs!
    rescue ex : Beryl::Config::Zpool::UnknownRaidLevel
      errors << ex.message.to_s
    rescue ex : Beryl::Config::Zpool::InvalidDiskCount
      errors << ex.message.to_s
    rescue ex : Beryl::Config::ResolvedHost::NoZFSPool
      errors << ex.message.to_s
    rescue ex : Beryl::Config::ResolvedHost::NoBootPool
      errors << ex.message.to_s
    rescue ex : Beryl::Config::ResolvedHost::MultipleBootPools
      errors << ex.message.to_s
    rescue ex : Beryl::Config::ResolvedHost::DuplicatedDisk
      errors << ex.message.to_s
    rescue ex : Beryl::Config::ResolvedHost::MissingMountpoint
      errors << ex.message.to_s
    end

    return Result.new(false, detected, errors, warnings) unless errors.empty?

    # 2. SSH rescue
    uname = conn.exec("uname -s", raise_on_error: false).stdout.strip
    if uname != "Linux"
      errors << "le rescue ne répond pas (uname -s = #{uname.inspect}). Lancez `beryl rescue #{host.fqdn}` d'abord."
      return Result.new(false, detected, errors, warnings)
    end

    # 3. lsblk → liste des disques physiques (sda, sdb, …)
    result = conn.exec("lsblk -b -d -n -o NAME,SIZE 2>/dev/null | cat", raise_on_error: false)
    result.stdout.each_line do |raw|
      line = raw.strip
      next if line.empty?
      tokens = line.split(/\s+/)
      next if tokens.size < 2
      name = tokens[0]
      next if name.starts_with?("zram") || name.starts_with?("loop") || name.starts_with?("sr")
      size = tokens[1].to_i64?
      next unless size
      next if size < 1_000_000_000 # < 1 Go : pas un vrai disque
      detected << name
    end

    # 4. Comparaison
    # Noms courts attendus (sda à partir de /dev/sda)
    declared_short = host.all_declared_disks.map { |d| File.basename(d) }.to_set
    detected_set = detected.to_set

    missing = (declared_short - detected_set).to_a.sort
    extra = (detected_set - declared_short).to_a.sort

    unless missing.empty?
      errors << "disques déclarés absents du serveur : #{missing.join(", ")}"
    end
    unless extra.empty?
      warnings << "disques physiques non déclarés (seront ignorés) : #{extra.join(", ")}"
    end

    Result.new(errors.empty?, detected, errors, warnings)
  end

  # Affichage convivial d'un résultat sur STDERR.
  def self.report(host : Beryl::Config::ResolvedHost, result : Result) : Nil
    STDERR.puts "[beryl bootstrap] Vérification préalable pour #{host.fqdn}"
    if result.ok
      STDERR.puts "  ✓ config ZFS cohérente (#{host.zpools.size} pool(s), boot=#{host.boot_zpool.name})"
      STDERR.puts "  ✓ rescue SSH joignable"
      STDERR.puts "  ✓ #{result.detected_disks.size} disque(s) détecté(s) : #{result.detected_disks.join(", ")}"
      if result.warnings.empty?
        STDERR.puts "  ✓ aucun disque orphelin"
      else
        result.warnings.each { |w| STDERR.puts "  ⚠ #{w}" }
      end
    else
      result.errors.each { |e| STDERR.puts "  ✗ #{e}" }
      unless result.warnings.empty?
        result.warnings.each { |w| STDERR.puts "  ⚠ #{w}" }
      end
    end
  end
end
