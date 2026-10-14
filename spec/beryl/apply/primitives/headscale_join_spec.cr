require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

describe Beryl::Apply::HeadscaleJoin do
  it "skip si déjà joint" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 0)
    ENV["HS_AUTH_KEY"] = "k-abc"
    begin
      result = prim("headscale-join").apply(
        shell,
        apply_params(%({login_server: "https://headscale.initech.example", authkey_env_var: "HS_AUTH_KEY"})),
        dry_run: false, context: ctx,
      )
      result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
      shell.ran?(/tailscale up/).should be_false
    ensure
      ENV.delete("HS_AUTH_KEY")
    end
  end

  it "appelle tailscale up si non joint" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 1)
    shell.stub(/tailscale up/, exit_code: 0)
    ENV["HS_AUTH_KEY"] = "k-deadbeef"
    begin
      result = prim("headscale-join").apply(
        shell,
        apply_params(%({login_server: "https://headscale.initech.example", authkey_env_var: "HS_AUTH_KEY"})),
        dry_run: false, context: ctx,
      )
      result.outcome.should eq(Beryl::Apply::Outcome::Applied)
      shell.ran?(/tailscale up.*--login-server=https:\/\/headscale.initech.example/).should be_true
      shell.ran?(/tailscale up.*--authkey=k-deadbeef/).should be_true
    ensure
      ENV.delete("HS_AUTH_KEY")
    end
  end

  it "ajoute --ephemeral si demandé" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 1)
    shell.stub(/tailscale up/, exit_code: 0)
    ENV["HS_AUTH_KEY"] = "k-eph"
    begin
      prim("headscale-join").apply(
        shell,
        apply_params(%({login_server: "https://headscale.initech.example", authkey_env_var: "HS_AUTH_KEY", ephemeral: true})),
        dry_run: false, context: ctx,
      )
      shell.ran?(/tailscale up.*--ephemeral/).should be_true
    ensure
      ENV.delete("HS_AUTH_KEY")
    end
  end

  it "fail si la var d'env d'authkey est absente" do
    shell = FakeShell.new
    shell.stub(/tailscale status/, exit_code: 1)
    ENV.delete("HS_AUTH_KEY")
    result = prim("headscale-join").apply(
      shell,
      apply_params(%({login_server: "https://headscale.initech.example", authkey_env_var: "HS_AUTH_KEY"})),
      dry_run: false, context: ctx,
    )
    result.outcome.should eq(Beryl::Apply::Outcome::Failed)
    result.message.should contain("HS_AUTH_KEY")
  end
end
