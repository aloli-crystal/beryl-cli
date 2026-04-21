require "yaml"

module Beryl
  # Configuration FreeBSD d'un hôte, lue depuis le bloc `freebsd:` d'un
  # inventaire YAML. Toutes les valeurs sont **explicites** : pas de
  # défaut magique qui s'applique silencieusement (règle Aloli
  # `feedback_no_silent_defaults`).
  #
  # Exemple YAML :
  #
  # ```yaml
  # hosts:
  #   loulou.aloli.net:
  #     provider: ovh
  #     freebsd:
  #       hostname: loulou
  #       timezone: Europe/Paris
  #       pool_name: zroot
  #       swap_gb: 4
  #       disks: [/dev/sda]
  #       raid: stripe
  #       install_type: distribution_sets
  #       users:
  #         - name: admin
  #           primary_group: www
  #           secondary_groups: [wheel]
  #           shell: /bin/csh
  #           ssh_keys:
  #             - ssh-ed25519 AAAA… philippe@aloli
  #       packages:
  #         - sudo
  #         - zsh
  #         - chruby
  #       sudoers:
  #         - '%wheel ALL=(ALL) NOPASSWD:ALL'
  # ```
  class FreebsdConfig
    getter hostname : String?
    getter timezone : String?
    getter pool_name : String?
    getter swap_gb : Int32?
    getter disks : Array(String)
    getter raid : String?
    getter install_type : String?
    getter users : Array(UserSpecYaml)
    getter packages : Array(String)
    getter sudoers : Array(String)

    # Valeur valide de `install_type` (cohérent avec handbook FreeBSD 15).
    VALID_INSTALL_TYPES = %w[distribution_sets packages]
    VALID_RAID          = %w[stripe mirror raidz raidz2 raidz3]

    def initialize(
      @hostname : String? = nil,
      @timezone : String? = nil,
      @pool_name : String? = nil,
      @swap_gb : Int32? = nil,
      @disks : Array(String) = [] of String,
      @raid : String? = nil,
      @install_type : String? = nil,
      @users : Array(UserSpecYaml) = [] of UserSpecYaml,
      @packages : Array(String) = [] of String,
      @sudoers : Array(String) = [] of String,
    )
      if (v = @raid) && !VALID_RAID.includes?(v)
        raise ArgumentError.new("freebsd.raid invalide : #{v.inspect} (attendu : #{VALID_RAID.join(", ")})")
      end
      if (v = @install_type) && !VALID_INSTALL_TYPES.includes?(v)
        raise ArgumentError.new("freebsd.install_type invalide : #{v.inspect} (attendu : #{VALID_INSTALL_TYPES.join(", ")})")
      end
    end

    def self.from_yaml(value : YAML::Any?) : FreebsdConfig?
      return nil unless value
      h = value.as_h? || return nil

      disks = h[YAML::Any.new("disks")]?.try { |v| v.as_a.map(&.as_s) } || [] of String
      packages = h[YAML::Any.new("packages")]?.try { |v| v.as_a.map(&.as_s) } || [] of String
      sudoers = h[YAML::Any.new("sudoers")]?.try { |v| v.as_a.map(&.as_s) } || [] of String

      users_any = h[YAML::Any.new("users")]?
      users = if users_any
                users_any.as_a.map { |u| UserSpecYaml.from_yaml(u) }
              else
                [] of UserSpecYaml
              end

      new(
        hostname: h[YAML::Any.new("hostname")]?.try(&.as_s),
        timezone: h[YAML::Any.new("timezone")]?.try(&.as_s),
        pool_name: h[YAML::Any.new("pool_name")]?.try(&.as_s),
        swap_gb: h[YAML::Any.new("swap_gb")]?.try(&.as_i),
        disks: disks,
        raid: h[YAML::Any.new("raid")]?.try(&.as_s),
        install_type: h[YAML::Any.new("install_type")]?.try(&.as_s),
        users: users,
        packages: packages,
        sudoers: sudoers,
      )
    end
  end

  # Spec d'un user YAML (pendant du Bootstrap::UserSpec en Crystal). Pas
  # fusionné directement avec UserSpec pour garder la frontière inventory
  # → bootstrap clean (UserSpec valide côté runtime bootstrap, pas côté
  # parsing YAML).
  class UserSpecYaml
    getter name : String
    getter primary_group : String?
    getter secondary_groups : Array(String)
    getter shell : String?
    getter ssh_keys : Array(String)

    def initialize(
      @name : String,
      @primary_group : String? = nil,
      @secondary_groups : Array(String) = [] of String,
      @shell : String? = nil,
      @ssh_keys : Array(String) = [] of String,
    )
    end

    def self.from_yaml(value : YAML::Any) : UserSpecYaml
      h = value.as_h? || raise ArgumentError.new("freebsd.users[] : entrée non-hash")
      name = h[YAML::Any.new("name")]?.try(&.as_s) || raise ArgumentError.new("freebsd.users[] : 'name' requis")

      new(
        name: name,
        primary_group: h[YAML::Any.new("primary_group")]?.try(&.as_s),
        secondary_groups: h[YAML::Any.new("secondary_groups")]?.try { |v| v.as_a.map(&.as_s) } || [] of String,
        shell: h[YAML::Any.new("shell")]?.try(&.as_s),
        ssh_keys: h[YAML::Any.new("ssh_keys")]?.try { |v| v.as_a.map(&.as_s) } || [] of String,
      )
    end
  end
end
