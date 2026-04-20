require "../../spec_helper"
require "../../../src/beryl/cli/rescue"

# Transport HTTP factice pour l'API OVH : enregistre chaque requête et
# répond avec un scénario pré-câblé. Les réponses sont consommées dans
# l'ordre (FIFO) pour refléter l'enchaînement `boots → boot → set_boot →
# set_boot (avec rescueSshKey) → reboot` de `prepare_rescue`.
private class StubOvhTransport < OvhApi::HttpTransport
  getter calls : Array({String, String, String}) = [] of {String, String, String}
  getter responses : Array({Int32, String})

  def initialize(@responses : Array({Int32, String}))
  end

  def request(method, url, headers, body) : {Int32, String}
    @calls << {method, url, body}
    raise "StubOvhTransport : plus de réponse programmée (appel ##{@calls.size})" if @responses.empty?
    @responses.shift
  end
end

# Transport HTTP factice pour Scaleway : même principe, mais sans la
# phase `/auth/time` (pas de signature côté Scaleway).
private class StubScalewayTransport < ScalewayApi::HttpTransport
  getter calls : Array({String, String, String}) = [] of {String, String, String}
  getter responses : Array({Int32, String})

  def initialize(@responses : Array({Int32, String}))
  end

  def request(method, url, headers, body) : {Int32, String}
    @calls << {method, url, body}
    raise "StubScalewayTransport : plus de réponse programmée (appel ##{@calls.size})" if @responses.empty?
    @responses.shift
  end
end

private def write_tmp_inventory(yaml : String) : String
  path = File.tempname(prefix: "beryl-rescue-spec-", suffix: ".yml")
  File.write(path, yaml)
  path
end

private OVH_INVENTORY = <<-YAML
  hosts:
    loulou.aloli.fr:
      provider: ovh
      ovh:
        service_name: ns3156789.ip-51-83-6.eu
        ssh_key_name: philippe-aloli-fr
  YAML

private SCW_INVENTORY = <<-YAML
  hosts:
    mysrv-scw.aloli.fr:
      provider: scaleway
      scaleway:
        zone: fr-par-2
        server_id: abc-123-def
  YAML

# Fake wait_for_ssh : enregistre l'appel et retourne un résultat fixe.
private class FakeSshWaiter
  getter calls : Array({String, Int32, String, Time::Span, Time::Span}) = [] of {String, Int32, String, Time::Span, Time::Span}
  property result : Bool = true

  def to_proc : Proc(String, Int32, String, Time::Span, Time::Span, Bool)
    ->(host : String, port : Int32, user : String, timeout : Time::Span, poll : Time::Span) do
      @calls << {host, port, user, timeout, poll}
      @result
    end
  end
end

describe Beryl::CLI::Rescue do
  describe ".run — OVH" do
    it "déclenche prepare_rescue puis retourne 0 si SSH répond" do
      inventory = write_tmp_inventory(OVH_INVENTORY)
      begin
        transport = StubOvhTransport.new([
          # /auth/time (non signé)
          {200, "1745000000"},
          # GET boots
          {200, "[1, 2, 3]"},
          # GET boot 1 : type harddisk → rejeté
          {200, %({"bootId": 1, "bootType": "harddisk"})},
          # GET boot 2 : type rescue, UEFI compatible → retenu
          {200, %({"bootId": 2, "bootType": "rescue", "kernel": "rescue64-pro", "supportsUEFI": "yes"})},
          # GET boot 3 : type power → ignoré
          {200, %({"bootId": 3, "bootType": "power"})},
          # GET /me/sshKey/philippe-aloli-fr → contenu brut (requis depuis
          # ovh-api 0.2.2, car OVH refuse les noms et exige la clé brute
          # dans le corps du PUT).
          {200, %({"keyName":"philippe-aloli-fr","key":"ssh-ed25519 AAAA... philippe@aloli.fr","default":false})},
          # PUT /dedicated/server/... (set_boot avec bootId + rescueSshKey=<contenu>) → vide
          {200, ""},
          # POST /reboot → Task
          {200, %({"taskId": 42, "function": "hardReboot", "status": "todo"})},
        ])

        client = OvhApi::Client.new(
          application_key: "AK", application_secret: "AS", consumer_key: "CK",
          endpoint: :eu, transport: transport,
        )

        waiter = FakeSshWaiter.new
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["loulou.aloli.fr"],
          ovh_client_factory: -> { client },
          scaleway_client_factory: -> { raise "ne devrait pas être appelé" },
          wait_for_ssh: waiter.to_proc,
        )

        exit_code.should eq(0)
        waiter.calls.size.should eq(1)
        waiter.calls[0][0].should eq("loulou.aloli.fr")
        waiter.calls[0][2].should eq("root")
        # Vérifie que prepare_rescue a atteint le reboot (dernier appel POST
        # sur /reboot).
        transport.calls.last[0].should eq("POST")
        transport.calls.last[1].should contain("/reboot")
        # Vérifie que le PUT set_boot a bien inclus rescueSshKey avec le
        # contenu brut de la clé (depuis 0.2.2, pas le nom).
        put = transport.calls.find { |c| c[0] == "PUT" }.not_nil!
        put[2].should contain(%("rescueSshKey":"ssh-ed25519 AAAA... philippe@aloli.fr"))
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "retourne un code non-zéro si SSH ne répond pas (timeout)" do
      inventory = write_tmp_inventory(OVH_INVENTORY)
      begin
        transport = StubOvhTransport.new([
          {200, "1745000000"},
          {200, "[2]"},
          {200, %({"bootId": 2, "bootType": "rescue", "kernel": "rescue64-pro", "supportsUEFI": "yes"})},
          {200, %({"keyName":"philippe-aloli-fr","key":"ssh-ed25519 AAAA...","default":false})},
          {200, ""},
          {200, %({"taskId": 42, "function": "hardReboot", "status": "todo"})},
        ])
        client = OvhApi::Client.new(
          application_key: "AK", application_secret: "AS", consumer_key: "CK",
          endpoint: :eu, transport: transport,
        )
        waiter = FakeSshWaiter.new
        waiter.result = false

        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["loulou.aloli.fr", "--timeout=1"],
          ovh_client_factory: -> { client },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: waiter.to_proc,
        )

        exit_code.should eq(Beryl::CLI::Rescue::EXIT_SSH_FAILED)
        waiter.calls[0][3].should eq(1.minutes)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "retourne EXIT_OK sans attendre SSH avec --no-wait" do
      inventory = write_tmp_inventory(OVH_INVENTORY)
      begin
        transport = StubOvhTransport.new([
          {200, "1745000000"},
          {200, "[2]"},
          {200, %({"bootId": 2, "bootType": "rescue", "kernel": "rescue64-pro", "supportsUEFI": "yes"})},
          {200, %({"keyName":"philippe-aloli-fr","key":"ssh-ed25519 AAAA...","default":false})},
          {200, ""},
          {200, %({"taskId": 42, "function": "hardReboot", "status": "todo"})},
        ])
        client = OvhApi::Client.new(
          application_key: "AK", application_secret: "AS", consumer_key: "CK",
          endpoint: :eu, transport: transport,
        )
        waiter = FakeSshWaiter.new

        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["loulou.aloli.fr", "--no-wait"],
          ovh_client_factory: -> { client },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: waiter.to_proc,
        )

        exit_code.should eq(0)
        waiter.calls.should be_empty
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "échoue proprement si le champ ovh.service_name manque" do
      yaml = <<-YAML
        hosts:
          mystery.aloli.fr:
            provider: ovh
        YAML
      inventory = write_tmp_inventory(yaml)
      begin
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["mystery.aloli.fr", "--no-wait"],
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_MISSING_CONFIG)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end
  end

  describe ".run — Scaleway" do
    it "déclenche reboot(Rescue) puis retourne 0 si SSH répond" do
      inventory = write_tmp_inventory(SCW_INVENTORY)
      begin
        transport = StubScalewayTransport.new([
          # POST /reboot → Server JSON
          {200, %({"id": "abc-123-def", "status": "stopping"})},
        ])
        client = ScalewayApi::Client.new(
          secret_key: "sk", default_zone: "fr-par-2", transport: transport,
        )
        waiter = FakeSshWaiter.new

        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["mysrv-scw.aloli.fr"],
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { client },
          wait_for_ssh: waiter.to_proc,
        )

        exit_code.should eq(0)
        transport.calls.size.should eq(1)
        transport.calls[0][0].should eq("POST")
        transport.calls[0][1].should contain("/baremetal/v1/zones/fr-par-2/servers/abc-123-def/reboot")
        transport.calls[0][2].should contain(%("boot_type":"rescue"))
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "échoue proprement si scaleway.server_id manque" do
      yaml = <<-YAML
        hosts:
          mystery.aloli.fr:
            provider: scaleway
            scaleway:
              zone: fr-par-2
        YAML
      inventory = write_tmp_inventory(yaml)
      begin
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["mystery.aloli.fr", "--no-wait"],
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_MISSING_CONFIG)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end
  end

  describe ".run — cas d'erreur génériques" do
    it "retourne EXIT_USAGE si aucun hôte n'est passé" do
      inventory = write_tmp_inventory(OVH_INVENTORY)
      begin
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: [] of String,
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_USAGE)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "retourne EXIT_USAGE si l'hôte est absent de l'inventaire" do
      inventory = write_tmp_inventory(OVH_INVENTORY)
      begin
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["inconnu.aloli.fr"],
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_USAGE)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "retourne EXIT_BAD_PROVIDER si le provider est inconnu" do
      yaml = <<-YAML
        hosts:
          web01.aloli.fr:
            provider: hetzner
        YAML
      inventory = write_tmp_inventory(yaml)
      begin
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["web01.aloli.fr", "--no-wait"],
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_BAD_PROVIDER)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "retourne EXIT_BAD_PROVIDER si le provider n'est pas précisé" do
      yaml = <<-YAML
        hosts:
          web01.aloli.fr: {}
        YAML
      inventory = write_tmp_inventory(yaml)
      begin
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["web01.aloli.fr", "--no-wait"],
          ovh_client_factory: -> { raise "skip" },
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_BAD_PROVIDER)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    it "retourne EXIT_BAD_CREDS si les variables OVH sont absentes" do
      inventory = write_tmp_inventory(OVH_INVENTORY)
      begin
        factory = -> do
          raise Beryl::CLI::Credentials::MissingCredentials.new("OVH_APPLICATION_KEY manquante")
          OvhApi::Client.new(application_key: "x", application_secret: "x", consumer_key: "x")
        end
        exit_code = Beryl::CLI::Rescue.run(
          inventory_path: inventory,
          args: ["loulou.aloli.fr", "--no-wait"],
          ovh_client_factory: factory,
          scaleway_client_factory: -> { raise "skip" },
          wait_for_ssh: FakeSshWaiter.new.to_proc,
        )
        exit_code.should eq(Beryl::CLI::Rescue::EXIT_BAD_CREDS)
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end
  end
end
