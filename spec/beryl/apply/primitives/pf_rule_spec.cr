require "../../../spec_helper"
require "../../../support/fake_shell"
require "../../../support/apply_helpers"

private RULE  = "block in quick proto tcp to port 23"
private BLOCK = "ext_if = em0\n# >>> beryl >>>\n#{RULE}\n# <<< beryl <<<\n"

describe Beryl::Apply::PfRule do
  it "ajoute une règle, valide puis recharge pf" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: "ext_if = em0\n")
    result = prim("pf-rule").apply(shell, apply_params({rule: RULE}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should contain(RULE)
    shell.ran?(/pfctl -nf/).should be_true
    shell.ran?(/pfctl -f/).should be_true
  end

  it "skip si la règle est déjà présente" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: BLOCK)
    result = prim("pf-rule").apply(shell, apply_params({rule: RULE}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "before: insère la règle devant un `block quick` déjà posé" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: BLOCK)
    pass = "pass in quick inet proto tcp from { 192.0.2.10/32 } to port 23"
    result = prim("pf-rule").apply(shell, apply_params({rule: pass, before: RULE}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    content = shell.writes.first.content
    (content.index!(pass) < content.index!(RULE)).should be_true
  end

  it "before: règle de référence absente → en fin de bloc" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: BLOCK)
    pass = "pass in quick inet proto tcp from { 192.0.2.10/32 } to port 22"
    prim("pf-rule").apply(shell, apply_params({rule: pass, before: "block in quick proto tcp to port 22"}.to_yaml), dry_run: false, context: ctx)
    content = shell.writes.first.content
    (content.index!(RULE) < content.index!(pass)).should be_true
  end

  it "if_set vide : étape sautée, pf.conf intact" do
    shell = FakeShell.new
    result = prim("pf-rule").apply(shell, apply_params({rule: "pass in quick from { } to port 23", if_set: ""}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end

  it "retire une règle existante (state: absent)" do
    shell = FakeShell.new
    shell.stub(/cat .*pf\.conf/, stdout: BLOCK)
    result = prim("pf-rule").apply(shell, apply_params({rule: RULE, state: "absent"}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    shell.writes.first.content.should_not contain(RULE)
  end

  it "nat: insère le bloc de translation AVANT la 1ʳᵉ règle filtre (ordre pf)" do
    shell = FakeShell.new
    # pf.conf typique : options/scrub, puis filtre.
    shell.stub(/cat .*pf\.conf/, stdout: "set skip on lo0\nscrub in all\nblock in all\npass out all keep state\n")
    natrule = "nat on egress from 100.64.0.0/10 to any -> (egress)"
    result = prim("pf-rule").apply(shell, apply_params({rule: natrule, nat: true}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Applied)
    content = shell.writes.first.content
    # le nat doit précéder la 1ʳᵉ règle filtre `block`
    (content.index!(natrule) < content.index!("block in all")).should be_true
    # et suivre scrub (translation après normalisation)
    (content.index!("scrub in all") < content.index!(natrule)).should be_true
    content.should contain("# >>> beryl nat >>>")
    shell.ran?(/pfctl -nf/).should be_true
  end

  it "nat: idempotent (skip si la règle nat est déjà dans le bloc translation)" do
    shell = FakeShell.new
    natrule = "nat on egress from 100.64.0.0/10 to any -> (egress)"
    shell.stub(/cat .*pf\.conf/, stdout: "scrub in all\n# >>> beryl nat >>>\n#{natrule}\n# <<< beryl nat <<<\nblock in all\n")
    result = prim("pf-rule").apply(shell, apply_params({rule: natrule, nat: true}.to_yaml), dry_run: false, context: ctx)
    result.outcome.should eq(Beryl::Apply::Outcome::Skipped)
    shell.writes.should be_empty
  end
end
