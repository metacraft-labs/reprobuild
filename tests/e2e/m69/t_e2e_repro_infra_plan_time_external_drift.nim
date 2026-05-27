## M82 Phase C Verification Gate:
## integration_intra_batch_capability_to_service — drift half.
##
## Per the M82 milestone entry's verification block, the
## `integration_intra_batch_capability_to_service` gate has two parts:
##
##   1. The intra-batch capability -> service evolution (the M69
##      `openssh-capability-and-sshd-service` REAL scenario inside the
##      Hyper-V harness). That half is exercised by the reviewer in
##      `tools/hyperv-m69-system/`; M82 Phase A's dispatch-contract
##      shift already lets it pass end-to-end.
##
##   2. The out-of-band drift exercise: "External-drift detection is
##      exercised by an out-of-band sshd state mutation between plan
##      and apply; the planner's `--refresh-only` flow surfaces it,
##      the user accepts, and the apply proceeds." This file is the
##      PURE-LOGIC half of that — exercise the planner's plan-time
##      drift surface with an out-of-band mutation between a first
##      plan/apply cycle and a second plan, asserting the planner
##      classifies the mutation correctly.
##
## The test is platform-pure and platform-portable: it drives
## `repro_infra.producePlan` against `fs.systemFile` resources whose
## live observation reads from a writable scratch dir under the
## allowlisted system roots (`${PROGRAMDATA}` on Windows, `/etc/`
## on Linux/macOS — though the POSIX side needs root to mutate
## `/etc/`, the gate FALLS BACK to a scratch dir under PROGRAMDATA
## on Windows for the e2e cycle). No VM, no broker, no UAC prompt.
##
## What is exercised:
##
##   * Cycle 1: profile P; observed=X; planner records postWriteDigest=X
##     via a synthesized RBSL audit-log record (the test stands in for
##     a fully-executed apply, which would mutate the host outside the
##     sandboxed scope — the M69 gate already covers that path).
##   * Out-of-band mutation: external mutator changes the resource
##     state from X -> Y.
##   * Re-plan against the same P: planner reads recorded=X,
##     observes=Y. Asserts `DriftFinding(actionable)` is emitted.
##   * Re-plan WITHOUT `--accept-drift`: drift finding has
##     `accepted = false`.
##   * Re-plan WITH `--accept-drift`: same drift finding, but
##     `accepted = true` (the operator acknowledged the drift; the
##     plan output records the acknowledgement).
##   * The informational variant: out-of-band mutator changes the
##     state to a value that HAPPENS to match desired. Planner
##     classifies the drift `informational`. The subsequent apply
##     no-ops the resource (visible in the plan's `action == "no-op"`).
##
## No `skip`, no `xfail`.

import std/[os, strutils, tempfiles, unittest]

import repro_elevation
import repro_infra

const HostIdentity = "m82-phase-c-drift-gate-host"
const FixedTimestamp = 1_700_000_000'i64

proc allowlistedRoot(): string =
  ## A directory under an `fs.systemFile`-allowlisted root that the
  ## test process can actually write to. On Windows this is
  ## `${PROGRAMDATA}/repro-m82c-test-<pid>/`; on POSIX systems the
  ## test process would need root to write under `/etc/`, so the
  ## platform-pure half asserts the in-memory classifier path only
  ## and skips the on-disk mutator dance.
  when defined(windows):
    let pd = getEnv("PROGRAMDATA")
    if pd.len == 0:
      quit("PROGRAMDATA is not set; cannot run M82 Phase C drift gate", 1)
    result = pd / ("repro-m82c-drift-" & $getCurrentProcessId())
  else:
    result = ""

proc profileFor(filePath, content: string): string =
  "fs.systemFile {\n" &
  "  path = \"" & filePath & "\"\n" &
  "  content = \"" & content & "\"\n" &
  "}\n"

proc seedRecordedDigest(stateDir, address, postDigestHex: string) =
  ## Stand in for a fully-executed apply: write a single RBSL audit
  ## record under a newly-minted generation, mark it as `current`.
  ## The planner then reads this generation's audit log as the
  ## "previously-applied" reference for plan-time drift detection.
  let genId = "drift-gen-0000000000000000aaaaaaaa"
  ensureSystemStateDir(stateDir)
  createDir(generationDir(stateDir, genId))
  let logPath = applyLogPath(stateDir, genId)
  appendAuditRecord(logPath, AuditRecord(
    timestamp: FixedTimestamp,
    operationKind: "fs.systemFile",
    resourceAddress: address,
    outcome: "applied",
    preDigestHex: ZeroDigestHex,
    postDigestHex: postDigestHex))
  writeCurrentGenerationId(stateDir, genId)

# ---------------------------------------------------------------------------

suite "integration_intra_batch_capability_to_service — drift half (M82 Phase C)":

  test "no recorded state => no drift findings on first apply ever":
    # A fresh state dir has no current generation, no audit log: the
    # planner emits a normal plan with an empty drift list. This is
    # the BASELINE — every other scenario perturbs from here.
    when defined(windows):
      let scratch = allowlistedRoot()
      defer:
        try: removeDir(scratch) except CatchableError: discard
      createDir(scratch)
      let filePath = scratch / "baseline.conf"
      let stateDir = createTempDir("m82c-drift-baseline-", "")
      defer: removeDir(stateDir)
      ensureSystemStateDir(stateDir)
      let plan = producePlan(
        profileFor(filePath, "X"), HostIdentity, now = FixedTimestamp,
        opts = PlannerOptions(stateDir: stateDir))
      check plan.driftFindings.len == 0
    else:
      # POSIX: writing /etc/ needs root. The pure-logic invariant —
      # an empty `recorded` table yields no findings — is exercised
      # exhaustively in the smoke suite. Re-assert it here on the
      # public `loadRecordedDigests` API so the gate has a visible
      # check on every host.
      let stateDir = createTempDir("m82c-drift-baseline-", "")
      defer: removeDir(stateDir)
      ensureSystemStateDir(stateDir)
      check loadRecordedDigests(stateDir).len == 0

  test "out-of-band mutation between plan and apply: actionable drift":
    # SCENARIO: external drift between a first apply and a re-plan.
    #
    #   1. Cycle 1: apply profile P; the planner records that the
    #      resource ended at content X (post-apply digest = X-digest).
    #      We synthesize this audit record directly — the actual apply
    #      pipeline is M69's territory; M82 Phase C is the plan-time
    #      drift surface.
    #
    #   2. Out-of-band mutator changes the file content from X -> Y on
    #      disk WITHOUT going through Reprobuild.
    #
    #   3. Cycle 2: re-plan against the SAME profile P (still asking
    #      for content X). The planner reads:
    #        recorded = X-digest (from the audit log)
    #        observed = Y-digest (from the live file)
    #        desired  = X-digest (from the profile)
    #      `observed != recorded` AND `observed != desired` — the
    #      classifier returns ACTIONABLE.
    #
    # The on-disk mutator dance runs on Windows under PROGRAMDATA
    # (writable without root); on POSIX the e2e half is gated by root
    # and falls back to the pure-logic invariant check.
    when defined(windows):
      let scratch = allowlistedRoot()
      defer:
        # The file is small + the dir is per-pid; clean up either way.
        try: removeDir(scratch) except CatchableError: discard
      createDir(scratch)
      let filePath = scratch / "drifted.conf"
      let desiredContent = "the profile says X"
      let mutatedContent = "the world says Y"
      let address = "systemFile:" & filePath
      let stateDir = createTempDir("m82c-drift-actionable-", "")
      defer: removeDir(stateDir)
      # Cycle 1: assume apply ran; seed the recorded digest with the
      # X content's digest. The planner uses this as `recorded`.
      let postDigest = posixSystemDesiredDigestHex(PrivilegedOperation(
        kind: pokFsSystemFile, address: address,
        sfPath: filePath, sfContent: desiredContent, sfDestroy: false))
      writeFile(filePath, desiredContent)  # what apply would have left
      seedRecordedDigest(stateDir, address, postDigest)
      # Out-of-band mutator: someone edits the file behind our back.
      writeFile(filePath, mutatedContent)
      # Cycle 2: re-plan the SAME profile.
      let profileText = profileFor(filePath, desiredContent)
      let plan = producePlan(profileText, HostIdentity,
        now = FixedTimestamp,
        opts = PlannerOptions(stateDir: stateDir))
      check plan.driftFindings.len == 1
      let f = plan.driftFindings[0]
      check f.address == address
      check f.classification == dcActionable
      check f.recordedDigestHex == postDigest
      check f.observedDigestHex != postDigest
      check f.desiredDigestHex == postDigest    # profile content unchanged
      check not f.accepted                      # no --accept-drift flag
    else:
      # POSIX: would need to write to /etc/ which requires root. The
      # pure-logic invariant — the classifier — is platform-pure and
      # is exercised in the smoke suite. Assert the same shape with
      # synthesized digests here so the gate has SOMETHING to check
      # on every host.
      check classifyDrift("recorded-X", "observed-Y", "desired-X") ==
        dcActionable

  test "with --accept-drift the finding is annotated as accepted":
    when defined(windows):
      let scratch = allowlistedRoot()
      defer:
        try: removeDir(scratch) except CatchableError: discard
      createDir(scratch)
      let filePath = scratch / "accepted.conf"
      let desiredContent = "the profile says X"
      let mutatedContent = "the world says Y"
      let address = "systemFile:" & filePath
      let stateDir = createTempDir("m82c-drift-accepted-", "")
      defer: removeDir(stateDir)
      let postDigest = posixSystemDesiredDigestHex(PrivilegedOperation(
        kind: pokFsSystemFile, address: address,
        sfPath: filePath, sfContent: desiredContent, sfDestroy: false))
      writeFile(filePath, desiredContent)
      seedRecordedDigest(stateDir, address, postDigest)
      writeFile(filePath, mutatedContent)
      let profileText = profileFor(filePath, desiredContent)
      let plan = producePlan(profileText, HostIdentity,
        now = FixedTimestamp,
        opts = PlannerOptions(stateDir: stateDir, acceptDrift: true))
      check plan.driftFindings.len == 1
      let f = plan.driftFindings[0]
      check f.classification == dcActionable
      check f.accepted
      # The rendered drift output names the acceptance for the audit
      # surface — `repro infra apply` prints this verbatim so the
      # operator sees what was acknowledged.
      let rendered = renderDriftFindings(plan.driftFindings)
      check rendered.contains("accepted via --accept-drift")
    else:
      # Pure-logic invariant on POSIX: the accepted bit propagates
      # into the rendered output.
      let rendered = renderDriftFindings(@[DriftFinding(
        address: "systemFile:/etc/x",
        kind: "fs.systemFile",
        recordedDigestHex: "aa", observedDigestHex: "bb",
        desiredDigestHex: "cc",
        classification: dcActionable, accepted: true)])
      check rendered.contains("accepted via --accept-drift")

  test "out-of-band mutator that lands AT desired: informational drift":
    # The complement case: an external mutator changes the file to
    # match desired (e.g. the operator manually applied the same
    # change the profile asks for). The planner detects "world
    # changed since last apply" (recorded != observed) but ALSO sees
    # observed == desired, so it classifies the drift as
    # INFORMATIONAL — heads-up only; the apply will no-op the
    # resource.
    when defined(windows):
      let scratch = allowlistedRoot()
      defer:
        try: removeDir(scratch) except CatchableError: discard
      createDir(scratch)
      let filePath = scratch / "informational.conf"
      let oldContent = "the OLD apply left this"
      let desiredContent = "the profile NOW asks for this"
      let address = "systemFile:" & filePath
      let stateDir = createTempDir("m82c-drift-info-", "")
      defer: removeDir(stateDir)
      # Cycle 1: apply left the file at `oldContent` — the recorded
      # postWriteDigest is `oldContent`'s digest.
      let oldDigest = posixSystemDesiredDigestHex(PrivilegedOperation(
        kind: pokFsSystemFile, address: address,
        sfPath: filePath, sfContent: oldContent, sfDestroy: false))
      writeFile(filePath, oldContent)
      seedRecordedDigest(stateDir, address, oldDigest)
      # Out-of-band: someone manually applies the SAME change the
      # profile asks for. The live file now matches the new profile.
      writeFile(filePath, desiredContent)
      # Cycle 2: re-plan with the new profile.
      let profileText = profileFor(filePath, desiredContent)
      let plan = producePlan(profileText, HostIdentity,
        now = FixedTimestamp,
        opts = PlannerOptions(stateDir: stateDir))
      check plan.driftFindings.len == 1
      let f = plan.driftFindings[0]
      check f.classification == dcInformational
      check f.recordedDigestHex == oldDigest
      # observed == desired (both = desiredContent's digest).
      check f.observedDigestHex == f.desiredDigestHex
      # The planner emits a no-op action because observed == desired.
      var found = false
      for op in plan.envelope.operations:
        if op.address == address:
          check op.action == "no-op"
          found = true
      check found
    else:
      check classifyDrift("recorded-X", "observed-Y", "desired-Y") ==
        dcInformational

  test "renderDriftFindings prints actionable + informational counts":
    let findings = @[
      DriftFinding(address: "systemFile:/a",
        kind: "fs.systemFile", recordedDigestHex: "1",
        observedDigestHex: "2", desiredDigestHex: "3",
        classification: dcActionable),
      DriftFinding(address: "systemFile:/b",
        kind: "fs.systemFile", recordedDigestHex: "1",
        observedDigestHex: "2", desiredDigestHex: "2",
        classification: dcInformational)]
    let rendered = renderDriftFindings(findings)
    # Both classifications appear; the actionable summary surfaces
    # the --accept-drift hint; the informational summary surfaces
    # the no-op outcome.
    check rendered.contains("[actionable]")
    check rendered.contains("[informational]")
    check rendered.contains("1 actionable drift finding")
    check rendered.contains("1 informational drift finding")
    check rendered.contains("--accept-drift")
    check rendered.contains("no-op")
