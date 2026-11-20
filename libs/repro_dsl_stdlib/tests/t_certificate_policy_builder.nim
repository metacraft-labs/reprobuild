## The ``certificatePolicy`` builder, its snapshot rendering and the strict
## reader, against each other (Test-Certificates TC-9b, Test-Certificates.md
## §"The policy declaration" and §"The policy snapshot in `repro.lock`").
##
## The builder runs where a policy package runs it: in a ``const``, at compile
## time. Each case then renders the snapshot, reads it back with the strict
## reader the gates use, and checks the two agree, so a writer and a reader
## that drift apart fail here before any gate sees the difference.
##
## No mocks: the module under test is pure data and string handling.

import std/[strutils, unittest]

import repro_certificates

const spec = certificatePolicy "metacraft-default":
  ciTrust advisory
  rule "agents", "agents-to-dev-*":
    gateMode required
    commitGate advisory
    requires "pre-commit", platforms = anyPlatform
  rule "dev", "stable", "live":
    gateMode required
    requires "pre-commit", platforms = anyPlatform
    requires "unit-suite", platforms = ["linux/amd64", "macos/arm64"]
  rule detachedHead:
    gateMode off
  rule "**":
    gateMode advisory
    requires "unit-suite"

const withDefaults = certificatePolicy "defaults":
  rule "main":
    requires "lint"
  gateMode required          # a policy default written after the rule
  commitGate advisory
  untrackedInputs strict
  ciTrust skip
  rule "release/*":
    platforms ["linux/amd64"]
    requires "unit-suite"
    requires "smoke", platforms = ["macos/arm64"]

const extended = spec.withRule("never-reached"):
  gateMode required
  requires "unit-suite"

suite "certificatePolicy builder":

  test "the specification's example builds as written":
    check spec.name == "metacraft-default"
    check spec.ciTrust == pctAdvisory
    check spec.untrackedInputs == puiReadSet
    check spec.rules.len == 4
    check spec.rules[0].branches == @["agents", "agents-to-dev-*"]
    check spec.rules[0].gateMode == pmRequired
    check spec.rules[0].commitGate == pmAdvisory
    check spec.rules[0].requires == @[PolicyRequirement(
      certificate: "pre-commit", platforms: @["*"])]
    # commitGate omitted means = gateMode (D7).
    check spec.rules[1].commitGate == pmRequired
    check spec.rules[1].requires[1].platforms ==
      @["linux/amd64", "macos/arm64"]
    check spec.rules[2].branches == @[DetachedHeadPattern]
    check spec.rules[2].gateMode == pmOff
    # A requires with no platforms, in a rule with none, is anyPlatform.
    check spec.rules[3].requires[0].platforms == @[AnyPlatformMarker]
    check spec.declaredIn.endsWith("t_certificate_policy_builder.nim")

  test "policy defaults and rule platforms resolve, wherever they are written":
    check withDefaults.ciTrust == pctSkip
    check withDefaults.untrackedInputs == puiStrict
    check withDefaults.rules[0].gateMode == pmRequired
    check withDefaults.rules[0].commitGate == pmAdvisory
    check withDefaults.rules[1].requires[0].platforms == @["linux/amd64"]
    check withDefaults.rules[1].requires[1].platforms == @["macos/arm64"]

  test "withRule only adds, last":
    check extended.rules.len == spec.rules.len + 1
    check extended.rules[0 ..< spec.rules.len] == spec.rules
    check extended.rules[^1].branches == @["never-reached"]
    check extended.name == spec.name

  test "invalid policies are refused when built":
    proc refused(body: proc()): string =
      try:
        body()
      except CertificatePolicySnapshotError as err:
        return err.msg
      ""
    check "cannot be mixed" in refused(proc() =
      var b = initCertificatePolicyBuilder("p", "")
      b.beginRule(["main"], "rule \"main\"")
      b.ruleRequires("x", ["*", "linux/amd64"])
      discard b.finish())
    check "required twice" in refused(proc() =
      var b = initCertificatePolicyBuilder("p", "")
      b.beginRule(["main"], "rule \"main\"")
      b.ruleRequires("x")
      b.ruleRequires("x")
      discard b.finish())
    check "gateMode is set twice" in refused(proc() =
      var b = initCertificatePolicyBuilder("p", "")
      b.beginRule(["main"], "rule \"main\"")
      b.ruleGateMode(pmOff)
      b.ruleGateMode(pmRequired))
    check "SHORT branch names" in refused(proc() =
      var b = initCertificatePolicyBuilder("p", "")
      b.beginRule(["refs/heads/main"], "rule")
      discard b.finish())
    check "needs at least one branch pattern" in refused(proc() =
      var b = initCertificatePolicyBuilder("p", "")
      b.beginRule([], "rule")
      discard b.finish())

suite "the snapshot":

  test "renders deterministically and reads back strictly to the same value":
    var pinned = spec
    pinned.package = "metacraft-certificate-policy"
    let text = renderCertificatePolicySnapshot(pinned)
    check text == renderCertificatePolicySnapshot(pinned)
    check text.startsWith("[certificate_policy]\nschema = \"" &
      CertificatePolicySchemaV1 & "\"\n")
    check "branches = [\"agents\", \"agents-to-dev-*\"]\n" &
      "gate_mode = \"required\"\ncommit_gate = \"advisory\"\n" &
      "requires = [{ certificate = \"pre-commit\", platforms = [\"*\"] }]" in
      text
    # commit_gate is written only when it differs from gate_mode.
    check "branches = [\"(detached)\"]\ngate_mode = \"off\"\n" in text
    let back = parseCertificatePolicySnapshot(text)
    check back.rules == pinned.rules
    check back.name == pinned.name
    check back.package == pinned.package
    check renderCertificatePolicySnapshot(back) == text

  test "the emission carries the provenance and leaves the package to the lock":
    let emission = renderCertificatePolicyEmission(spec, "consumer")
    let parsed = parseCertificatePolicyEmission(emission)
    check parsed.enactedBy == "consumer"
    check parsed.declaredIn == spec.declaredIn
    check parsed.policy.package == ""
    check parsed.policy.rules == spec.rules

  test "a lock document splits into its lock part and its snapshot":
    var pinned = withDefaults
    pinned.package = "policy"
    let lock = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
      "platform = \"amd64-linux\"\n\n" & renderCertificatePolicySnapshot(pinned)
    let split = splitCertificatePolicySection(lock)
    check "name = " notin split.lockPart
    check "platform = \"amd64-linux\"" in split.lockPart
    check split.policySection == renderCertificatePolicySnapshot(pinned)
    let read = readCertificatePolicySnapshot(lock)
    check read.present
    check read.policy.rules == pinned.rules
    check not readCertificatePolicySnapshot(split.lockPart).present

suite "command sets (what a required name means)":
  # Test-Certificates.md §"What a required name means: its command set".
  # The DSL's policy carries none; a lock writer adds them, and the strict
  # reader checks their format.

  proc hexOf(c: char): string = repeat(c, 64)

  proc withSets(sets: openArray[CertificateCommandSet]):
      BranchCertificatePolicy =
    result = spec
    result.package = "metacraft-certificate-policy"
    result.commandSets = @sets

  let complete = withSets([
    CertificateCommandSet(name: "unit-suite", commands: @[
      "integration=blake3:" & hexOf('5'), "unit=blake3:" & hexOf('9')]),
    CertificateCommandSet(name: "pre-commit", commands: @[
      "pre-commit-checks=blake3:" & hexOf('3')])])

  proc refusal(text: string): string =
    try:
      discard parseCertificatePolicySnapshot(text)
    except CertificatePolicySnapshotError as err:
      return err.msg
    ""

  test "the required names, in first-requirement order":
    check requiredCertificateNames(spec) == @["pre-commit", "unit-suite"]
    check requiredCertificateNames(withDefaults) ==
      @["lint", "unit-suite", "smoke"]

  test "a name no rule requires may have a table; tables render sorted":
    var extra = complete
    extra.commandSets.insert(CertificateCommandSet(name: "zz-nightly",
      commands: @["n=blake3:" & hexOf('7')]), 0)
    extra.commandSets.add(CertificateCommandSet(name: "a-smoke",
      commands: @["s=blake3:" & hexOf('8')]))
    let text = renderCertificatePolicySnapshot(extra)
    let a = text.find("name = \"a-smoke\"")
    let p = text.find("name = \"pre-commit\"")
    let u = text.find("name = \"unit-suite\"")
    let z = text.find("name = \"zz-nightly\"")
    check a >= 0 and a < p and p < u and u < z
    let back = parseCertificatePolicySnapshot(text)
    check commandSetOf(back, "zz-nightly").commands ==
      @["n=blake3:" & hexOf('7')]
    check renderCertificatePolicySnapshot(back) == text

  test "render after the rules, sorted by name, and read back":
    let text = renderCertificatePolicySnapshot(complete)
    check text.endsWith("\n[[certificate_policy.certificate]]\n" &
      "name = \"pre-commit\"\n" &
      "commands = [\"pre-commit-checks=blake3:" & hexOf('3') & "\"]\n" &
      "\n[[certificate_policy.certificate]]\n" &
      "name = \"unit-suite\"\n" &
      "commands = [\"integration=blake3:" & hexOf('5') & "\", \"unit=blake3:" &
        hexOf('9') & "\"]\n")
    let back = parseCertificatePolicySnapshot(text)
    check back.rules == complete.rules
    check commandSetOf(back, "unit-suite").commands ==
      complete.commandSets[0].commands
    check commandSetOf(back, "pre-commit").recorded
    check renderCertificatePolicySnapshot(back) == text

  test "a snapshot that records none still reads (written before them)":
    var legacy = spec
    legacy.package = "metacraft-certificate-policy"
    let back = parseCertificatePolicySnapshot(
      renderCertificatePolicySnapshot(legacy))
    check back.commandSets.len == 0
    check not commandSetOf(back, "unit-suite").recorded

  test "the format is checked loudly":
    let text = renderCertificatePolicySnapshot(complete)
    let unitLine = "commands = [\"integration=blake3:" & hexOf('5') &
      "\", \"unit=blake3:" & hexOf('9') & "\"]"
    check unitLine in text
    check "unknown command-set key 'owner'" in refusal(text.replace(
      "name = \"unit-suite\"\n", "name = \"unit-suite\"\nowner = \"x\"\n"))
    check "sorted and unique" in refusal(text.replace(unitLine,
      "commands = [\"unit=blake3:" & hexOf('9') & "\", \"integration=blake3:" &
        hexOf('5') & "\"]"))
    check "sorted and unique" in refusal(text.replace(unitLine,
      "commands = [\"unit=blake3:" & hexOf('9') & "\", \"unit=blake3:" &
        hexOf('9') & "\"]"))
    check "must not be empty" in refusal(text.replace(unitLine,
      "commands = []"))
    check "is not <action id>=blake3:" in refusal(text.replace(unitLine,
      "commands = [\"unit=blake3:" & hexOf('A') & "\"]"))
    check "is not <action id>=blake3:" in refusal(text.replace(unitLine,
      "commands = [\"unit=sha256:" & hexOf('9') & "\"]"))
    check "is not <action id>=blake3:" in refusal(text.replace(unitLine,
      "commands = [\"=blake3:" & hexOf('9') & "\"]"))
    check "needs 'commands'" in refusal(text.replace(unitLine & "\n", ""))
    # A table may name a certificate no rule requires (the writers record
    # every marked name); a required name without one is the error.
    check "certificate 'unit-suite' is required but has no command set" in
      refusal(text.replace("name = \"unit-suite\"", "name = \"nightly\""))
    check "has two command sets" in refusal(text.replace(
      "name = \"unit-suite\"", "name = \"pre-commit\""))
    # All or none: a snapshot that records one set records every one.
    var partial = complete
    partial.commandSets.setLen(1)
    check "has no command set" in refusal(text.replace(
      "\n[[certificate_policy.certificate]]\nname = \"unit-suite\"\n" &
        unitLine & "\n", ""))
    expect CertificatePolicySnapshotError:
      discard renderCertificatePolicySnapshot(partial)

  test "an emission carries none":
    let emission = renderCertificatePolicyEmission(complete, "consumer")
    check "certificate_policy.certificate" notin emission
    check parseCertificatePolicyEmission(emission).policy.commandSets.len == 0
    let forged = emission & "\n[[certificate_policy.certificate]]\n" &
      "name = \"pre-commit\"\ncommands = [\"x=blake3:" & hexOf('1') & "\"]\n"
    expect CertificatePolicySnapshotError:
      discard parseCertificatePolicyEmission(forged)

  test "a candidate narrows a name by omitting any entry of the base":
    let base = @["a=blake3:" & hexOf('1'), "b=blake3:" & hexOf('2')]
    check omittedCommands(base, base).len == 0
    check omittedCommands(base, base & @["c=blake3:" & hexOf('3')]).len == 0
    check omittedCommands(base, @["a=blake3:" & hexOf('1')]) ==
      @["b=blake3:" & hexOf('2')]
    check omittedCommands(base, @["a=blake3:" & hexOf('1'),
      "b=blake3:" & hexOf('4')]) == @["b=blake3:" & hexOf('2')]
    check omittedCommands(base, []) == base

suite "branch patterns":

  test "git wildmatch over short branch names":
    check wildmatch("agents", "agents")
    check not wildmatch("agents", "agents-x")
    check wildmatch("agents-to-dev-*", "agents-to-dev-2026-10-09")
    check not wildmatch("feature/*", "feature/a/b")   # `*` stays in one component
    check wildmatch("feature/**", "feature/a/b")
    check wildmatch("**", "feature/a/b")
    check wildmatch("**/fix", "fix")                   # `**/` matches no directory
    check wildmatch("**/fix", "a/b/fix")
    check wildmatch("a/**/b", "a/b")                   # `/**/` matches no directory
    check wildmatch("a/**/b", "a/x/y/b")
    # `**` that is not a whole component is a plain `*` (git, WM_PATHNAME).
    check wildmatch("agents-**", "agents-x")
    check not wildmatch("agents-**", "agents-x/y")
    check wildmatch("release/v?", "release/v2")
    check not wildmatch("release/v?", "release/v22")
    check wildmatch("hotfix-[0-9]*", "hotfix-7-a")
    check not wildmatch("hotfix-[!0-9]*", "hotfix-7-a")
    check wildmatch("lit\\*", "lit*")
    check not wildmatch("lit\\*", "litx")

  test "first match wins, detached and tags":
    let first = matchPolicy(spec, branchRefFromRef("agents-to-dev-1"))
    check first.matched and first.ruleIndex == 0
    check matchPolicy(spec, branchRefFromRef("feature/a/b")).ruleIndex == 3
    check matchPolicy(spec, BranchRef(kind: brkDetached)).ruleIndex == 2
    check not matchPolicy(spec, branchRefFromRef("refs/tags/agents")).matched
    check commitTimeBranch("refs/heads/wip", "refs/heads/agents").name ==
      "agents"
    check commitTimeBranch("refs/heads/wip", "").name == "wip"
    check commitTimeBranch("", "").kind == brkDetached
    check not matchPolicy(withDefaults, BranchRef(kind: brkDetached)).matched

suite "the enacted policy's declaring file":

  test "is recorded relative to the enacting recipe":
    var p = spec
    p.declaredIn = "/ws/certpolicy/policy/team_policy.nim"
    check withDeclaredInRelativeTo(p, "/ws/consumer").declaredIn ==
      "../certpolicy/policy/team_policy.nim"
    check withDeclaredInRelativeTo(p, "").declaredIn == p.declaredIn
    var already = p
    already.declaredIn = "../x.nim"
    check withDeclaredInRelativeTo(already, "/ws/consumer").declaredIn ==
      "../x.nim"
