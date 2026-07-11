require "../../spec_helper"
require "../../support/fake_ovh_transport"

describe Beryl::Providers::Ovh do
  describe "#owns?" do
    it "retourne true si le service_name est dans la liste du compte" do
      transport = FakeOvhTransport.new
      transport.stub(
        "GET",
        /dedicated\/server$/,
        status: 200,
        body: %(["ns3156789.ip-51-83-6.eu","ns42.ip-1-2-3.eu"]),
      )
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.owns?("ns3156789.ip-51-83-6.eu").should be_true
    end

    it "retourne false si le service_name n'est pas dans la liste" do
      transport = FakeOvhTransport.new
      transport.stub(
        "GET",
        /dedicated\/server$/,
        status: 200,
        body: %(["ns1.ip-1-2-3.eu"]),
      )
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.owns?("ns9999.ip-99-99-99.eu").should be_false
    end

    it "retourne false si l'API lève (rescue-friendly)" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /dedicated\/server$/, status: 500, body: %({"message":"boom"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.owns?("whatever").should be_false
    end
  end

  describe "#name / #display_name" do
    it "expose un nom court et un nom humain" do
      provider = Beryl::Providers::Ovh.new
      provider.name.should eq("ovh")
      provider.display_name.should eq("OVHcloud")
    end
  end

  describe "#ssh_key_yaml_fragment" do
    it "renvoie { ssh_key_name => label }" do
      provider = Beryl::Providers::Ovh.new
      fragment = provider.ssh_key_yaml_fragment("philippe-aloli-fr")
      fragment["ssh_key_name"].should eq("philippe-aloli-fr")
    end
  end

  describe "#credentials_env_vars" do
    it "APP_KEY + APP_SECRET sont obligatoires, CONSUMER_KEY et ENDPOINT optionnels" do
      # CONSUMER_KEY est marquée optional : beryl init la génère
      # automatiquement via le hook `bootstrap_credentials_if_needed`
      # (POST /auth/credential). ENDPOINT a un défaut `eu`.
      vars = Beryl::Providers::Ovh.new.credentials_env_vars
      required = vars.reject(&.optional).map(&.name)
      required.should eq(["OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET"])
      vars.find! { |v| v.name == "OVH_CONSUMER_KEY" }.optional.should be_true
      vars.find! { |v| v.name == "OVH_ENDPOINT" }.optional.should be_true
    end
  end

  describe "#capabilities" do
    it "expose :dns et :compute (ADR-014)" do
      ovh = Beryl::Providers::Ovh.new
      ovh.capabilities.sort.should eq([:compute, :dns])
      ovh.capable_of?(:dns).should be_true
      ovh.capable_of?(:compute).should be_true
      ovh.capable_of?(:cdn).should be_false
    end

    it "inclut les modules DnsProvider et ComputeProvider" do
      ovh = Beryl::Providers::Ovh.new
      ovh.is_a?(Beryl::DnsProvider).should be_true
      ovh.is_a?(Beryl::ComputeProvider).should be_true
    end
  end

  describe "#set_reverse" do
    it "IPv6 : poste le reverse sur le BLOC /64 (path), l'adresse précise en ipReverse" do
      # Régression terrain (qgra, 9 juin 2026) : OVH renvoyait 404
      # « This service does not exist » sur POST /ip/{/128}/reverse. Le
      # service IP est le bloc /64 routé, pas l'adresse individuelle.
      transport = FakeOvhTransport.new
      transport.stub(
        "POST",
        /ip\/.+\/reverse$/,
        status: 200,
        body: %({"ipReverse":"2001:41d0:306:2b67::1","reverse":"qgra.popi.net."}),
      )
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.set_reverse("2001:41d0:306:2b67::1", "qgra.popi.net")

      req = transport.requests.find! { |r| r.method == "POST" }
      # Bloc /64 dans le path (slash encodé %2F par le shard).
      req.url.should contain("/ip/2001:41d0:306:2b67::%2F64/reverse")
      req.url.should_not contain("::1/reverse")
      # Adresse /128 dans le body + FQDN terminé par un point.
      req.body.should contain(%("ipReverse":"2001:41d0:306:2b67::1"))
      req.body.should contain(%("reverse":"qgra.popi.net."))
    end

    it "IPv4 : poste le reverse sur l'adresse elle-même (bloc == /32)" do
      transport = FakeOvhTransport.new
      transport.stub(
        "POST",
        /ip\/.+\/reverse$/,
        status: 200,
        body: %({"ipReverse":"51.83.6.208","reverse":"qgra.popi.net."}),
      )
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.set_reverse("51.83.6.208", "qgra.popi.net.")

      req = transport.requests.find! { |r| r.method == "POST" }
      req.url.should contain("/ip/51.83.6.208/reverse")
      req.body.should contain(%("ipReverse":"51.83.6.208"))
    end
  end

  describe "#required_access_rules" do
    it "liste les routes OVH à injecter dans la consumer key générée" do
      rules = Beryl::Providers::Ovh.new.required_access_rules
      paths = rules.map { |r| r[:path] }
      paths.should contain("/services/*")         # rename displayName
      paths.should contain("/dedicated/server/*") # détails + sous-routes
      paths.should contain("/domain/zone/*")      # records d'une zone
      paths.should contain("/ip/*/reverse")       # DNS reverse
    end

    it "inclut les endpoints de LISTE en plus des wildcards (nécessaires pour GET /me/sshKey, etc.)" do
      # Le wildcard OVH `/me/sshKey/*` ne couvre PAS `/me/sshKey` nu
      # (endpoint de liste). Il faut les deux pour que beryl puisse
      # lister les clés SSH (cas découvert terrain 23 avril 2026).
      rules = Beryl::Providers::Ovh.new.required_access_rules
      paths = rules.map { |r| r[:path] }
      paths.should contain("/me/sshKey")
      paths.should contain("/me/sshKey/*")
      paths.should contain("/dedicated/server")
      paths.should contain("/domain/zone")
    end
  end

  describe "#credentials_help_details" do
    it "affiche les routes à autoriser dans le navigateur" do
      details = Beryl::Providers::Ovh.new.credentials_help_details.not_nil!
      details.should contain("Beryl générera la consumer key")
      details.should contain("/services/*")
    end
  end

  describe "#bootstrap_credentials_if_needed" do
    it "ne fait rien si OVH_CONSUMER_KEY est déjà présente (idempotent)" do
      env = {
        "OVH_APPLICATION_KEY"    => "k",
        "OVH_APPLICATION_SECRET" => "s",
        "OVH_CONSUMER_KEY"       => "existing",
      }
      result = Beryl::Providers::Ovh.new.bootstrap_credentials_if_needed(env)
      result["OVH_CONSUMER_KEY"].should eq("existing")
    end

    it "lève si APP_KEY ou APP_SECRET manquent" do
      env = {} of String => String
      expect_raises(Exception, /OVH_APPLICATION_KEY/) do
        Beryl::Providers::Ovh.new.bootstrap_credentials_if_needed(env)
      end
    end
  end

  describe "#server_detail" do
    it "extrait gamme + rack + IPv4 en un GET" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /dedicated\/server\/ns123\.eu$/, status: 200,
        body: %({"commercialRange":"Advance-2","rack":"16RA09","ip":"1.2.3.4"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      d = provider.server_detail("ns123.eu")
      d[:commercial].should eq("Advance-2")
      d[:rack].should eq("16RA09")
      d[:ipv4].should eq("1.2.3.4")
    end
  end

  describe "#commercial_range" do
    it "lit le champ commercialRange du serveur" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /dedicated\/server\/ns123\.eu$/, status: 200,
        body: %({"commercialRange":"Advance-2","ip":"1.2.3.4"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.commercial_range("ns123.eu").should eq("Advance-2")
    end

    it "renvoie nil si l'API lève (rescue-friendly)" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /dedicated\/server\/ns123\.eu$/, status: 500, body: %({"message":"boom"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.commercial_range("ns123.eu").should be_nil
    end
  end

  describe "#monthly_price" do
    it "résout serviceInfos → serviceId → /services/{id} → prix" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /ns123\.eu\/serviceInfos$/, status: 200, body: %({"serviceId":42}))
      transport.stub("GET", /services\/42$/, status: 200,
        body: %({"billing":{"pricing":{"price":{"value":89.99,"currencyCode":"EUR"}}}}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.monthly_price("ns123.eu").should eq("89.99")
    end

    it "renvoie nil si le prix n'est pas exposé" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /ns123\.eu\/serviceInfos$/, status: 200, body: %({"serviceId":42}))
      transport.stub("GET", /services\/42$/, status: 200, body: %({"billing":{}}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.monthly_price("ns123.eu").should be_nil
    end
  end

  describe "#ip_to_service_index" do
    it "construit la map IP => service_name en une passe" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /dedicated\/server$/, status: 200, body: %(["ns1.eu","ns2.eu"]))
      transport.stub("GET", /dedicated\/server\/ns1\.eu$/, status: 200, body: %({"ip":"1.1.1.1"}))
      transport.stub("GET", /dedicated\/server\/ns2\.eu$/, status: 200, body: %({"ip":"2.2.2.2"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      idx = provider.ip_to_service_index
      idx["1.1.1.1"].should eq("ns1.eu")
      idx["2.2.2.2"].should eq("ns2.eu")
    end
  end

  describe "#server_hardware" do
    it "extrait CPU, cœurs/threads, RAM et disques (groupes)" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /specifications\/hardware$/, status: 200, body: %({
        "processorName": "AMD EPYC 4344P",
        "numberOfProcessors": 1,
        "coresPerProcessor": 8,
        "threadsPerProcessor": 16,
        "memorySize": {"value": 64, "unit": "GB"},
        "diskGroups": [
          {"numberOfDisks": 2, "diskSize": {"value": 960, "unit": "GB"}, "diskType": "SSD"},
          {"numberOfDisks": 4, "diskSize": {"value": 7680, "unit": "GB"}, "diskType": "SSD", "raidController": "9361-4i"}
        ]
      }))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      hw = provider.server_hardware("ns123.eu").not_nil!
      hw.cpu.should eq("AMD EPYC 4344P")
      hw.cores.should eq(8)
      hw.threads.should eq(16)
      hw.ram_gb.should eq(64)
      hw.disks.should eq(["2 x 960 GB SSD", "4 x 7680 GB SSD"])
      hw.raid.should eq("9361-4i")
    end

    it "renvoie nil si l'API lève (rescue-friendly)" do
      transport = FakeOvhTransport.new
      transport.stub("GET", /specifications\/hardware$/, status: 500, body: %({"message":"boom"}))
      provider = Beryl::Providers::Ovh.new(build_fake_ovh_client(transport))
      provider.server_hardware("ns123.eu").should be_nil
    end
  end
end
