require "../spec_helper"

describe "primitives jail (registre)" do
  it "enregistre jail-create / jail-base / jail-exec / jail-proxy / jail-destroy" do
    %w[jail-create jail-base jail-exec jail-proxy jail-destroy].each do |n|
      Beryl::Apply::Primitive[n]?.should_not be_nil
    end
  end
end

describe Beryl::Jail do
  describe ".loopback_ip" do
    it "alloue 127.0.1.<index>" do
      Beryl::Jail.loopback_ip(1).should eq("127.0.1.1")
      Beryl::Jail.loopback_ip(42).should eq("127.0.1.42")
    end

    it "refuse un index hors 1..254" do
      expect_raises(ArgumentError, /hors plage/) { Beryl::Jail.loopback_ip(0) }
      expect_raises(ArgumentError, /hors plage/) { Beryl::Jail.loopback_ip(255) }
    end
  end

  describe ".valid_name?" do
    it "accepte des noms d'appli sûrs" do
      Beryl::Jail.valid_name?("myapp").should be_true
      Beryl::Jail.valid_name?("fds-prod").should be_true
      Beryl::Jail.valid_name?("app_1").should be_true
    end

    it "refuse ce qui pourrait casser jail.conf / les chemins" do
      Beryl::Jail.valid_name?("").should be_false
      Beryl::Jail.valid_name?("../escape").should be_false
      Beryl::Jail.valid_name?("My App").should be_false
      Beryl::Jail.valid_name?("1app").should be_false # doit commencer par une lettre
    end
  end

  describe ".jail_conf" do
    it "génère un bloc jail.conf complet et confiné" do
      conf = Beryl::Jail.jail_conf("myapp", "127.0.1.5", "/jails/myapp")
      conf.should contain("myapp {")
      conf.should contain(%(path = "/jails/myapp";))
      conf.should contain(%(ip4.addr = "lo1|127.0.1.5";))
      conf.should contain(%(mount.fstab = "/jails/myapp.fstab";))
      conf.should contain("allow.raw_sockets = 0;")
      conf.should contain("allow.mount = 0;")
      conf.should contain("persist;")
    end
  end

  describe ".skeleton_script" do
    it "crée les répertoires rw + points de montage RO et peuple etc/var" do
      sh = Beryl::Jail.skeleton_script("/jails/myapp", "/jails/.base")
      sh.should contain("mkdir -p")
      sh.should contain("/jails/myapp/etc")       # rw
      sh.should contain("/jails/myapp/usr/local") # rw (l'appli)
      sh.should contain("/jails/myapp/bin")       # point de montage RO
      sh.should contain("chmod 1777 /jails/myapp/tmp")
      sh.should contain("cp -a /jails/.base/etc/. /jails/myapp/etc/")
      sh.should contain("BSD.var.dist")
      sh.should contain("ifconfig lo1")
      sh.should contain("sysrc -q jail_enable=YES")
    end
  end

  describe ".base_install_script" do
    it "build le base via pkgbase (pkg --rootdir, ABI/clés du host)" do
      sh = Beryl::Jail.base_install_script("/jails/.base")
      sh.should contain("pkg --rootdir /jails/.base update -f -r FreeBSD-base")
      sh.should contain("ABI=$(pkg config ABI)")
      sh.should contain("FreeBSD-set-base")                 # voie meta si dispo
      sh.should contain("grep -vE '(-dbg|-lib32|-tests)$'") # repli : tous les base
    end
  end

  describe ".nginx_proxy" do
    it "génère un server block nginx vers la jail (loopback)" do
      n = Beryl::Jail.nginx_proxy("app.example.net", "127.0.1.5", 3000)
      n.should contain("server_name app.example.net;")
      n.should contain("proxy_pass http://127.0.1.5:3000;")
      n.should contain("proxy_set_header Host $host;")
    end
  end

  describe ".thin_fstab" do
    it "monte chaque RO_DIR du base en nullfs read-only dans la jail" do
      fstab = Beryl::Jail.thin_fstab("/jails/myapp", "/jails/.base")
      fstab.should contain("/jails/.base/bin  /jails/myapp/bin  nullfs  ro  0  0")
      fstab.should contain("/jails/.base/usr/lib  /jails/myapp/usr/lib  nullfs  ro  0  0")
      fstab.should contain("/jails/.base/rescue  /jails/myapp/rescue  nullfs  ro  0  0")
      # autant de lignes que de RO_DIRS, toutes en `ro`.
      lines = fstab.lines.reject(&.empty?)
      lines.size.should eq(Beryl::Jail::RO_DIRS.size)
      lines.all? { |l| l.includes?("nullfs  ro") }.should be_true
    end

    it "ne monte PAS les répertoires rw (etc/var/home/usr/local)" do
      fstab = Beryl::Jail.thin_fstab("/jails/myapp", "/jails/.base")
      fstab.should_not contain("/jails/myapp/etc ")
      fstab.should_not contain("/jails/myapp/home ")
      fstab.should_not contain("/jails/myapp/usr/local ")
    end
  end
end
