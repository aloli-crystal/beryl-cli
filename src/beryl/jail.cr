module Beryl
  # Génération de jails FreeBSD « thin » en RAW jail.conf (zéro dépendance) :
  # une appli web = une jail, base FreeBSD PARTAGÉ monté en lecture seule
  # (nullfs RO) + couche rw propre à l'appli (/etc, /var, /home, /usr/local…).
  # Depuis l'intérieur, `../` ne sort pas de la jail → une appli compromise ne
  # peut pas lire les secrets d'une autre appli ni du host.
  #
  # Ce module ne contient QUE les générateurs PURS (testables sans FreeBSD) :
  # contenu du `jail.conf.d/<nom>.conf`, du fstab nullfs, et l'allocation IP.
  # La partie impérative (build du base, montages, start) vit dans la primitive
  # `jail-create`.
  module Jail
    # Répertoires du base montés en LECTURE SEULE (nullfs) dans chaque thin
    # jail. Tout le reste (/etc, /var, /tmp, /root, /home, /usr/local, /dev…)
    # est rw et propre à la jail. `rescue` = binaires de secours statiques.
    RO_DIRS = %w[
      bin sbin lib libexec rescue
      usr/bin usr/sbin usr/lib usr/libexec usr/libdata usr/share usr/include
    ]

    # Répertoires rw créés dans le dataset de la jail (skeleton). /usr/local et
    # /home reçoivent l'appli ; /etc et /var sont peuplés depuis le base.
    RW_DIRS = %w[etc var tmp root home usr/local dev proc]

    # IP loopback dédiée à une jail (sur l'interface `lo1`). index 1..254.
    def self.loopback_ip(index : Int32) : String
      raise ArgumentError.new("index jail hors plage 1..254 : #{index}") unless 1 <= index <= 254
      "127.0.1.#{index}"
    end

    # Contenu de `/etc/jail.conf.d/<name>.conf`. `path` = racine de la jail,
    # `ip` = alias loopback. sshd/services internes via `/bin/sh /etc/rc`.
    def self.jail_conf(name : String, ip : String, path : String) : String
      <<-CONF
      # Géré par beryl (primitive jail-create). Édition manuelle écrasée.
      #{name} {
        host.hostname = "#{name}";
        path = "#{path}";
        ip4.addr = "lo1|#{ip}";
        mount.fstab = "#{path}.fstab";
        mount.devfs;
        devfs_ruleset = 4;          # devfs minimal (pas d'accès disque brut)
        exec.clean;
        exec.start = "/bin/sh /etc/rc";
        exec.stop = "/bin/sh /etc/rc.shutdown";
        exec.consolelog = "/var/log/jail_#{name}_console.log";
        persist;
        allow.set_hostname = 0;     # la jail ne change pas son hostname
        allow.raw_sockets = 0;      # pas de raw sockets (anti-spoof/scan)
        allow.mount = 0;
      }

      CONF
    end

    # Contenu du fstab nullfs (`<path>.fstab`) : monte chaque RO_DIR du base en
    # lecture seule dans la jail. Aligné en colonnes pour rester lisible.
    def self.thin_fstab(jail_path : String, base_path : String, ro_dirs : Array(String) = RO_DIRS) : String
      ro_dirs.map do |d|
        "#{base_path}/#{d}  #{jail_path}/#{d}  nullfs  ro  0  0"
      end.join("\n") + "\n"
    end

    # Validation d'un nom de jail (= nom d'appli/d'user) : minuscules, chiffres,
    # tirets/underscores. Évite l'injection dans jail.conf / les chemins.
    def self.valid_name?(name : String) : Bool
      !name.empty? && name.size <= 63 && name.matches?(/\A[a-z][a-z0-9_-]*\z/)
    end

    # Script (sh) qui build/rafraîchit le BASE PARTAGÉ d'une thin jail via
    # pkgbase (`pkg --rootdir`), réutilisable pour PATCHER le base (re-run =
    # upgrade). Mirroir d'install-pkgbase.sh : ABI + clés depuis le host. Au
    # re-run, `pkg install -U` met à jour → toutes les jails (nullfs RO) suivent
    # après redémarrage. PUR (renvoie le script) → testable.
    def self.base_install_script(base_path : String) : String
      <<-SH
      set -e
      ABI=$(pkg config ABI)
      VMAJ=$(freebsd-version | sed 's/[.-].*//')
      mkdir -p #{base_path}/usr/share/keys
      cp -R /usr/share/keys/pkgbase-${VMAJ} #{base_path}/usr/share/keys/ 2>/dev/null || true
      env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir #{base_path} update -f -r FreeBSD-base
      if pkg --rootdir #{base_path} rquery -U -r FreeBSD-base '%n' 2>/dev/null | grep -qx 'FreeBSD-set-base'; then
        env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir #{base_path} install -U -y -r FreeBSD-base FreeBSD-set-base
      else
        BASE=$(pkg --rootdir #{base_path} rquery -U -r FreeBSD-base '%n' 2>/dev/null | grep -vE '(-dbg|-lib32|-tests)$' | tr '\\n' ' ')
        env ABI="${ABI}" IGNORE_OSVERSION=yes pkg --rootdir #{base_path} install -U -y -r FreeBSD-base ${BASE}
      fi
      SH
    end

    # Bloc nginx (host) qui reverse-proxy `server_name` vers la jail (loopback).
    # TLS/certbot gérés séparément (recettes nginx/letsencrypt). PUR → testable.
    def self.nginx_proxy(server_name : String, ip : String, port : Int32) : String
      <<-NGINX
      # Géré par beryl (primitive jail-proxy). Édition manuelle écrasée.
      server {
          listen 80;
          server_name #{server_name};
          location / {
              proxy_pass http://#{ip}:#{port};
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
          }
      }
      NGINX
    end

    # Script shell (sh) qui crée le SKELETON rw d'une thin jail : répertoires rw
    # + points de montage RO (vides, pour les nullfs), /etc et /var peuplés
    # depuis le base, lo1 cloné, jail_enable. Idempotent (mkdir -p, sysrc -q).
    # PUR (renvoie le script) → testable ; exécuté par la primitive jail-create.
    def self.skeleton_script(jail_path : String, base_path : String,
                             ro_dirs : Array(String) = RO_DIRS,
                             rw_dirs : Array(String) = RW_DIRS) : String
      ro_mkdir = ro_dirs.map { |d| "#{jail_path}/#{d}" }.join(" ")
      rw_mkdir = rw_dirs.map { |d| "#{jail_path}/#{d}" }.join(" ")
      <<-SH
      set -e
      mkdir -p #{rw_mkdir} #{ro_mkdir}
      chmod 1777 #{jail_path}/tmp
      # /etc et /var propres à la jail, peuplés depuis le base RO.
      cp -a #{base_path}/etc/. #{jail_path}/etc/
      if [ -f #{base_path}/etc/mtree/BSD.var.dist ]; then
        mtree -deU -f #{base_path}/etc/mtree/BSD.var.dist -p #{jail_path}/var >/dev/null
      fi
      cp -a #{base_path}/root/. #{jail_path}/root/ 2>/dev/null || true
      # Interface loopback dédiée aux jails (persistée).
      ifconfig lo1 >/dev/null 2>&1 || ifconfig lo1 create
      sysrc -q cloned_interfaces+=lo1 >/dev/null
      sysrc -q jail_enable=YES >/dev/null
      SH
    end
  end
end
