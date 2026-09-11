## Enabling the `attestation` activity at a tier that needs real
## evidence, on an image layout that cannot produce any, does not reach a
## plan.
##
## ## What is being defended
##
## An attestation tier names the root of trust that signs what a machine
## says about itself, and two of the three — `cvm` and `tpm` — sign a
## measurement of the bytes the machine booted. That measurement is only
## worth quoting if those bytes stay fixed for the life of the boot. On a
## layout whose root filesystem is an ordinary writable volume they do
## not, so the machine comes up, the agent starts, it answers challenges,
## and every answer is worthless. Nothing fails. That is the shape of
## defect this gate exists to make impossible: the failure has to arrive
## while a plan is being made, in front of the person making it.
##
## ## Why it is not enough to check that the plan failed
##
## A plan can fail for a hundred reasons that have nothing to do with the
## rule — a typo in the profile, a missing import, an engine that could
## not start. So the assertion is not "non-zero exit"; it is that the
## refusal QUOTES THE RULE: the tier that was asked for, the layout that
## was given, and the layout that would have worked. A refusal that names
## none of those would satisfy a weaker gate and would be, from the
## operator's side, indistinguishable from the engine being broken.
##
## And a gate that only ever watches things be refused proves nothing
## about discrimination — a validator that rejects every configuration
## passes it. The CONTROL is in this file rather than only in its
## sibling: the same tier, on the layout that can carry it, plans
## successfully and emits its activity. Its sibling gate
## (`t_activity_mock_tier_allowed_on_plain_layout`) holds the other
## polarity, the one where the LAYOUT is the thing held constant.
##
## ## The two halves of this file
##
## The first half spawns the real CLI: three plans, one per pairing,
## because "does not reach a plan" is a claim about the pipeline and not
## about a proc. The second half drives the validator in-process, where a
## case costs microseconds instead of a `nim c`, and covers the whole
## tier x layout matrix plus the two other rules the activity carries.
##
## ## Mocking
##
## None. Real `repro` binary, real profile compile, real planner. The
## in-process half calls the shipped validator, not a copy of it.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/system/attestation
import repro_profile

import ./attestation_activity_harness

const ModuleSource = RepoRoot / "libs" / "repro_dsl_stdlib" / "src" /
  "repro_dsl_stdlib" / "packages" / "system" / "attestation.nim"

proc withoutComments(src: string): string =
  ## Nim source with `#` comments removed, so a structural claim cannot
  ## be satisfied by a sentence that merely describes the code. String
  ## literals are left alone — a `#` inside one is not a comment, and
  ## this module's refusal messages do not contain any.
  var lines: seq[string]
  for raw in src.splitLines:
    var inStr = false
    var cut = raw.len
    var i = 0
    while i < raw.len:
      let c = raw[i]
      if c == '\\' and inStr:
        i += 2
        continue
      if c == '"':
        inStr = not inStr
      elif c == '#' and not inStr:
        cut = i
        break
      inc i
    lines.add raw[0 ..< cut]
  lines.join("\n")

suite "the attestation activity refuses a tier its layout cannot serve":

  setup:
    let tmpRoot = createTempDir("attestation-activity-refusal-", "")

  teardown:
    try: removeDir(tmpRoot)
    except CatchableError: discard

  test "a tpm tier on a writable-root layout does not reach a plan":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let (run, activityJson) =
        planFor(tmpRoot, "tpmOnPlain", "uefi-ext4", "atTpm")
      # The plan does not exist.
      check run.exitCode != 0
      check "profile compilation failed" in run.output
      # And the refusal names the rule rather than merely failing. All
      # three halves: what was asked for, what was given, what would
      # have worked.
      let diagnostic = diagnosticBody(run.output)
      check diagnostic.len > 0
      check "tier tpm" in diagnostic
      check "uefi-ext4" in diagnostic
      check "uefi-attested" in diagnostic
      # The activity was never built. A validator that raised AFTER
      # constructing the spec would still fail the plan, but it would
      # mean the refusal is a cleanup rather than a gate.
      check activityJson == ""

  test "a cvm tier on the same layout is refused for the same reason":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      # The rule is about "a tier that is not mock", not about one tier
      # that happens to have been special-cased.
      let (run, activityJson) =
        planFor(tmpRoot, "cvmOnPlain", "uefi-ext4", "atCvm")
      check run.exitCode != 0
      let diagnostic = diagnosticBody(run.output)
      check "tier cvm" in diagnostic
      check "uefi-attested" in diagnostic
      check activityJson == ""

  test "the same tier on the attested layout plans, and emits its activity":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      # THE CONTROL. Without it, everything above is satisfied by a
      # validator that refuses every configuration it is handed.
      let (run, activityJson) =
        planFor(tmpRoot, "tpmOnAttested", "uefi-attested", "atTpm")
      check "profile compilation failed" notin run.output
      check run.exitCode == 0
      # And the activity really was constructed, with the contributions
      # enabling it is supposed to make.
      check activityJson.len > 0
      let spec = parseSystemActivityJson(activityJson)
      check spec.name == ActivityName
      check spec.systemPackages == @[AgentPackage]
      check spec.systemServices == @[UnitName]

suite "the rule, driven directly over the whole matrix":

  test "every non-mock tier is refused on a layout without a measured root":
    for tier in [atCvm, atTpm]:
      for layout in ["uefi-ext4", "", "uefi-attested-typo", "UEFI-ATTESTED"]:
        expect EConfigViolation:
          discard attestationActivity(attestationConfig(layout, tier = tier))

  test "every tier is accepted on the attested layout":
    for tier in [atCvm, atTpm, atMock]:
      let spec = attestationActivity(
        attestationConfig("uefi-attested", tier = tier))
      check spec.name == ActivityName

  test "the mock tier is accepted on every layout, including nonsense":
    # `mock` has no root of trust, produces evidence a production policy
    # is required to refuse, and exists so the layers above it can be
    # developed on a machine with no attestation hardware. Pinning it to
    # an attestable layout would defeat the only purpose it has.
    for layout in ["uefi-ext4", "", "whatever-the-recipe-called-it"]:
      let spec = attestationActivity(attestationConfig(layout))
      check spec.systemServices == @[UnitName]

  test "the refusal message names the tier, the layout and the remedy":
    var msg = ""
    try:
      discard attestationActivity(
        attestationConfig("uefi-ext4", tier = atTpm))
    except EConfigViolation as err:
      msg = err.msg
    check "tier tpm" in msg
    check "uefi-ext4" in msg
    check "uefi-attested" in msg
    check "mock" in msg

  test "a configuration the shipped service unit cannot carry is refused":
    # Delegated to the renderer rather than restated here, so there is
    # one place that decides what a legal secrets directory is. The
    # refusal must still arrive as a config violation, because that is
    # what a profile-level handler can be written against.
    expect EConfigViolation:
      discard attestationActivity(attestationConfig("uefi-attested",
        tier = atMock, provisionedSecretsDir = "/var/lib/secrets"))
    expect EConfigViolation:
      discard attestationActivity(attestationConfig("uefi-attested",
        tier = atMock, listen = ""))

  test "declaring the API remote while binding loopback is a contradiction":
    for loopback in ["127.0.0.1:7331", "127.0.0.53:7331", "[::1]:7331",
                     "localhost:7331"]:
      expect EConfigViolation:
        discard attestationActivity(attestationConfig("uefi-attested",
          tier = atMock, listen = loopback, exposeRemotely = true))
    # ... and binding a routable address with the flag set is fine, so
    # the rule is about the disagreement rather than about the flag.
    let spec = attestationActivity(attestationConfig("uefi-attested",
      tier = atMock, listen = "0.0.0.0:7331", exposeRemotely = true))
    check spec.name == ActivityName
    # A loopback listener WITHOUT the flag is the shipped default and
    # must stay legal.
    check attestationActivity(attestationConfig("uefi-ext4")).name ==
      ActivityName

  test "there is no way to build the activity that skips the validator":
    # The claim the module makes is that `attestationActivity` is the
    # only constructor. A second `buildActivitySpec` call anywhere in
    # the module — or a validator call that moved below it — would be a
    # path to a spec nobody checked, and neither shows up as a failing
    # case anywhere else.
    let src = withoutComments(readFile(ModuleSource))
    check src.count("buildActivitySpec(") == 1
    let ctor = src.find("proc attestationActivity*")
    check ctor >= 0
    let validateAt = src.find("validateAttestationConfig(cfg)", ctor)
    let buildAt = src.find("buildActivitySpec(", ctor)
    check validateAt >= 0
    check buildAt >= 0
    check validateAt < buildAt

  test "the activity's contributions are the constants, not their names":
    # `collectStrLitList` takes an identifier's OWN NAME, so writing
    # `systemPackages: [AgentPackage]` in the activity body yields a
    # package literally called "AgentPackage" with no error anywhere.
    # This is the run-time half of the compile-time guard in the module.
    let spec = attestationActivity(attestationConfig("uefi-attested"))
    check spec.systemPackages == @["attestation-agent"]
    check spec.systemServices == @["attestation-agent.service"]
    check AgentPackage == "attestation-agent"
    check UnitName == "attestation-agent.service"
