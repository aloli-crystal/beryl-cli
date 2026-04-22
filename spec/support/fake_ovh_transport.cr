# Transport HTTP factice pour tester Beryl::Providers::Ovh.
# Équivalent du FakeTransport du shard ovh-api, namespacé pour éviter
# le conflit avec le FakeTransport de scaleway-api (même nom de classe
# top-level dans les deux shards).

require "ovh-api/ovh_api"

class FakeOvhTransport < OvhApi::HttpTransport
  record Request,
    method : String,
    url : String,
    headers : HTTP::Headers,
    body : String

  record Stub,
    method : String,
    url_pattern : Regex,
    status : Int32,
    body : String

  getter requests = [] of Request
  getter stubs = [] of Stub

  def stub(method : String, url_pattern : Regex, status : Int32, body : String) : Nil
    @stubs << Stub.new(method: method, url_pattern: url_pattern, status: status, body: body)
  end

  def request(method, url, headers, body) : {Int32, String}
    @requests << Request.new(method: method, url: url, headers: headers, body: body)

    match = @stubs.reverse.find { |s| s.method == method && s.url_pattern.matches?(url) }
    unless match
      raise "Aucun stub ne correspond à #{method} #{url} (stubs déclarés : " \
            "#{@stubs.map { |s| "#{s.method} #{s.url_pattern.source}" }.join(", ")})"
    end
    {match.status, match.body}
  end
end

def build_fake_ovh_client(transport : FakeOvhTransport, time : Int64 = 1_700_000_000_i64) : OvhApi::Client
  transport.stub("GET", /auth\/time/, status: 200, body: time.to_s)
  OvhApi::Client.new(
    application_key: "app-key",
    application_secret: "app-secret",
    consumer_key: "consumer-key",
    endpoint: :eu,
    transport: transport,
  )
end
