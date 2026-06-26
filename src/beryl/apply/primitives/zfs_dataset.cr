require "../primitive"

module Beryl::Apply
  # Primitive `zfs-dataset` : crée (idempotent) un dataset ZFS « par client » sous
  # `<pool>/clients/<name>`, avec quota/compression/recordsize/mountpoint. Calquée
  # sur `jail-create`. Cf. spec `adoc/zfs-dataset-per-client-spec.adoc`.
  #
  #     - zfs-dataset:
  #         pool: tank          # zpool data existant
  #         name: acme          # = client → <pool>/clients/acme
  #         quota: 2T           # plafonne données + snapshots (garde-fou tenant)
  #         # compression: lz4  # défaut
  #         # recordsize: 1M    # défaut (16k si réception InnoDB)
  #         # mountpoint: /tank/clients/acme   # défaut ZFS sinon
  #
  # Idempotent : dataset présent → ajuste les props divergentes (zfs set) ; absent
  # → zfs create. Le conteneur `<pool>/clients` (canmount=off) est créé une fois.
  # JAMAIS de `zfs destroy` (retrait d'un client = opération explicite séparée).
  #
  # ⚠️ À VALIDER IN VIVO (ZFS non testable hors FreeBSD) : générateurs purs testés.
  class ZfsDataset < Primitive
    # Props gérées, dans un ordre déterministe (quota d'abord = garde-fou tenant).
    PROP_ORDER = %w[quota mountpoint compression recordsize]
    DEFAULTS   = {"compression" => "lz4", "recordsize" => "1M"}

    def name : String
      "zfs-dataset"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      pool = required_string(params, "pool")
      cname = required_string(params, "name")
      unless ZfsDataset.valid_pool?(pool) && ZfsDataset.valid_name?(cname)
        return StepResult.failed("pool/nom de dataset invalide : #{pool.inspect}/#{cname.inspect}")
      end
      container = "#{pool}/clients"
      dataset = "#{container}/#{cname}"
      props = ZfsDataset.build_props(params)

      if dry_run
        return StepResult.applied("dataset #{dataset} (#{props.map { |k, v| "#{k}=#{v}" }.join(", ")}) — " \
                                  "dry-run : #{ZfsDataset.create_cmd(dataset, props)}")
      end

      # 1. Conteneur <pool>/clients : canmount=off → non monté lui-même, mais les
      # enfants HÉRITENT le mountpoint (/<pool>/clients/<name>). PAS mountpoint=none
      # (qui ferait hériter « none » → enfants non montés). Créé une fois.
      unless ZfsDataset.exists?(shell, container)
        r = shell.exec("zfs create -o canmount=off #{Process.quote(container)}", raise_on_error: false)
        return StepResult.failed("création du conteneur #{container} échouée : #{r.stderr.strip.lines.last?}") unless r.success?
      end

      # 2. Dataset client : ajuste si présent, crée sinon.
      if ZfsDataset.exists?(shell, dataset)
        changed = [] of String
        props.each do |k, v|
          cur = shell.exec("zfs get -H -o value #{k} #{Process.quote(dataset)}", raise_on_error: false).stdout.strip
          next if cur == v
          set = shell.exec("zfs set #{k}=#{Process.quote(v)} #{Process.quote(dataset)}", raise_on_error: false)
          return StepResult.failed("zfs set #{k}=#{v} #{dataset} échoué : #{set.stderr.strip.lines.last?}") unless set.success?
          changed << k
        end
        return StepResult.skipped("dataset #{dataset} déjà conforme") if changed.empty?
        StepResult.applied("dataset #{dataset} : props ajustées (#{changed.join(", ")})")
      else
        cr = shell.exec(ZfsDataset.create_cmd(dataset, props), raise_on_error: false)
        return StepResult.failed("zfs create #{dataset} échoué : #{cr.stderr.strip.lines.last?}") unless cr.success?
        StepResult.applied("dataset #{dataset} créé (#{props.map { |k, v| "#{k}=#{v}" }.join(", ")})")
      end
    end

    # ── Helpers PURS (testables) ────────────────────────────────────────────

    # Props effectives : défauts (compression/recordsize) écrasés par les params,
    # + quota/mountpoint si fournis. Ordre déterministe (PROP_ORDER).
    def self.build_props(params : Hash(String, YAML::Any)) : Array({String, String})
      vals = DEFAULTS.dup
      {"quota", "compression", "recordsize", "mountpoint"}.each do |k|
        if v = string(params, k)
          vals[k] = v
        end
      end
      PROP_ORDER.compact_map { |k| vals[k]?.try { |v| {k, v} } }
    end

    # Commande `zfs create -o k=v … <dataset>` (props dans l'ordre).
    def self.create_cmd(dataset : String, props : Array({String, String})) : String
      opts = props.map { |k, v| "-o #{k}=#{Process.quote(v)}" }.join(" ")
      "zfs create #{opts} #{Process.quote(dataset)}"
    end

    # Le dataset existe-t-il ? (csh-safe : pas de redir Bourne ; SudoShell→sh).
    def self.exists?(shell : Shell, dataset : String) : Bool
      shell.exec("zfs list -H -o name #{Process.quote(dataset)}", raise_on_error: false).success?
    end

    # Nom de client : strict (c'est un tenant, va dans un chemin ZFS + montage).
    def self.valid_name?(name : String) : Bool
      !name.empty? && name.size <= 63 && name.matches?(/\A[a-z0-9][a-z0-9_-]*\z/)
    end

    # Nom de pool : alphanumérique + `_-.:` (pas de `/` — c'est un pool racine).
    def self.valid_pool?(pool : String) : Bool
      !pool.empty? && pool.matches?(/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z/)
    end

    # `string` helper de Primitive exposé en classe pour build_props (idem
    # comportement : lit un scalaire string d'un YAML::Any param).
    private def self.string(params : Hash(String, YAML::Any), key : String) : String?
      params[key]?.try { |v| v.as_s? || (v.as_i? || v.as_f?).try(&.to_s) }
    end
  end

  Primitive.register(ZfsDataset.new)
end
