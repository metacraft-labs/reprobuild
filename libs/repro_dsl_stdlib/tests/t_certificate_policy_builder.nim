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
