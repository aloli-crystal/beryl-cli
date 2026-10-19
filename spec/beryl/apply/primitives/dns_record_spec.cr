require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::DnsRecord do
  it "pose l'enregistrement par la pose DNS de beryl apply, sans toucher à l'hôte" do
    calls = [] of {String, String, String, Bool}
    hook = ->(fqdn : String, type : String, target : String, dry_run : Bool) do
      calls << {fqdn, type, target, dry_run}
      "#{type} #{fqdn} → #{target}"
    end
    shell = FakeShell.new
    context = Beryl::Apply::Context.new(dns: hook)
    result = prim("dns-record").apply(shell, apply_params("name: Svc.Example.net.\ntype: a\ntarget: 192.0.2.10"),
      dry_run: false, context: context)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    calls.should eq([{"svc.example.net", "A", "192.0.2.10", false}])
    shell.ran?(/./).should be_false
  end

  it "saute une cible vide (pas d'IPv6), refuse un type inconnu ou l'absence de pose DNS" do
    hook = ->(fqdn : String, type : String, target : String, dry_run : Bool) { "" }
    context = Beryl::Apply::Context.new(dns: hook)
    prim("dns-record").apply(FakeShell.new, apply_params("name: svc.example.net\ntype: AAAA\ntarget: \"\""), dry_run: false,
      context: context).outcome.should eq(Beryl::Apply::Outcome::Skipped)
    expect_raises(Beryl::Apply::Primitive::PrimitiveError) do
      prim("dns-record").apply(FakeShell.new, apply_params("name: svc.example.net\ntype: MX\ntarget: x"), dry_run: false,
        context: context)
    end
    expect_raises(Beryl::Apply::Primitive::PrimitiveError) do
      prim("dns-record").apply(FakeShell.new, apply_params("name: svc.example.net\ntype: A\ntarget: 192.0.2.1"), dry_run: false,
        context: ctx)
    end
  end
end
