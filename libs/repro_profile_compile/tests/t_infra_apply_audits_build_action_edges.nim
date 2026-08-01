## `repro infra apply` audits BOTH halves of an apply — the live-state
## resources AND the build-action edges — into one RBSL log, and keeps
## the two populations distinguishable.
##
## The defect this pins
## --------------------
## `runInfraApply` converges two independent populations and pools them
## into one printed summary (`applied: N / no-op: M`):
##
##   * live-state resources, which `writeAuditRecords` audited; and
##   * build-action edges, which `dispatchBuildActions` COUNTED but
##     never wrote to the audit log.
##
## On a real host that meant a generation's `apply.log` accounted for a
## strict SUBSET of the resources the summary counted (measured on
## windows-runner-001: 7 audited records vs 26 counted resources). Four
## consecutive generations' logs were byte-identical apart from
## timestamps and BLAKE3 trailers — the live-state half was provably
## stable — while the printed counter moved, because the edges that
## moved it were invisible. A benign build-fingerprint change was
## therefore indistinguishable from a live-state convergence
## regression.
##
## What is asserted
## ----------------
##   1. RECONCILIATION — every resource the summary counts has a record
##      in the log, per verdict (applied / no-op / skipped / error).
##   2. SEPARATION — each record names its population via
##      `recordClass`; a build-action edge is never mistakable for a
##      live-state resource, and vice versa.
##   3. NO FAKED STATE — build-action records carry EMPTY
##      pre/post observed-state digests. An edge is a cache decision,
##      not a state transition; synthesising digests for it would
##      re-create the conflation.
##   4. MISS DIAGNOSABILITY — a cache-MISSING edge is identifiable as
##      such (`operationKind == "build"`) and carries a fingerprint. A
##      converged edge reports `cache-hit` with the SAME fingerprint; a
##      re-keyed edge misses with a DIFFERENT fingerprint. That is the
##      pair of observations that separates "this edge re-keys every
##      apply" from "this edge keys stably and misses for some other
##      reason" — the distinction that was undiagnosable before.
##   5. FORMAT COMPATIBILITY — the reader still decodes v1 records
##      (written by an earlier `repro infra apply`) and classifies them
##      as live-state, so previously-committed generations under an
##      existing system state dir stay readable.
##
## Mocks: NONE.
##
## Per the workspace policy ("every use of mock objects in tests must be
## explicitly justified in the header comment") there is nothing to
## justify here — this test mocks nothing. It drives the REAL production
## dispatcher (`repro_profile_compile.mkBuildActionDispatcher`, the same
## closure the CLI injects into `ApplyOptions.buildActionDispatcher`),
## which runs REAL `/bin/sh` processes through the REAL in-process
## elevation broker, against a REAL temp-dir system state dir, and reads
## the REAL on-disk RBSL log back with the REAL `readAuditLog`. The
## live-state half is a real `windows.optionalFeature` resource observed
## by the real driver (absent on a POSIX host, hence privileged-and-
## skipped under `--no-elevate`). Counts are compared against the values
## `runInfraApply` actually returned, never against hard-coded numbers
## alone.
##
## POSIX-only: the edges spawn `/bin/sh`. On Windows the suite
## self-skips, matching the sibling Phase-G dispatcher tests.

import std/[os, strutils, tempfiles, unittest]

import blake3
import repro_core
import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------

const LiveStateProfileText = """
windows.optionalFeature { name = "Repro-Test-Nonexistent-Feature-AuditGap" }
"""
  ## One REAL live-state resource. The feature name is guaranteed
  ## absent on every host (the POSIX observer reports absent, the
  ## Windows DISM observer reports `ofsAbsent` for an unknown name), so
  ## the planner emits a `create` for it. It is a privileged operation,
  ## so under `emNoElevate` the apply reports it SKIPPED — a live-state
  ## record with a live-state verdict, produced without mutating the
  ## host.

proc shellWriteEdge(id, outputPath, payload: string): ProfileBuildAction =
  ## An action edge that writes `payload` to `outputPath` through a real
  ## `/bin/sh`. `requiresElevation = true` routes the spawn through the
  ## in-process broker fast path, which runs the argv synchronously and
  ## does not require an io-monitor CLI (a non-elevated cacheable edge
  ## would trip the engine's requires-io-monitor guard). Same shape the
  ## sibling Phase-G dispatcher integration test uses.
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", "printf %s '" & payload & "' > '" &
      outputPath & "'"],
    cwd: "",
    deps: @[],
    inputs: @[],
    outputs: @[outputPath],
    commandStatsId: "audit.edge.write",
    toolIdentityRefs: @[],
    requiresElevation: true,
    cacheable: true)

proc failingEdge(id: string): ProfileBuildAction =
  ## An action edge whose process exits non-zero. Declares no outputs so
  ## the failure is the exit status itself, not a missing-output
  ## diagnosis.
  ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", "exit 3"],
    cwd: "",
    deps: @[],
    inputs: @[],
    outputs: @[],
    commandStatsId: "audit.edge.fail",
    toolIdentityRefs: @[],
    requiresElevation: true,
    cacheable: true)

proc applyOptionsFor(stateDir, cacheRoot: string;
                     edges: seq[ProfileBuildAction]): ApplyOptions =
  createDir(stateDir)
  createDir(cacheRoot)
  ApplyOptions(
    stateDir: stateDir,
    hostIdentity: "audit-gap-host",
    reproExe: "/usr/bin/false",     # never spawned: emNoElevate
    elevationMode: emNoElevate,
    noPreview: true,
    buildActions: edges,
    buildActionDispatcher: mkBuildActionDispatcher(
      cacheRoot, FixtureContext(filePrefix: stateDir)))

# ---------------------------------------------------------------------------
# Log helpers — all operate on records read back from the real file.
# ---------------------------------------------------------------------------

proc recordsWithOutcome(records: seq[AuditRecord]; outcome: string): int =
  for r in records:
    if r.outcome == outcome: inc result

proc buildActionRecords(records: seq[AuditRecord]): seq[AuditRecord] =
  for r in records:
    if r.isBuildActionRecord(): result.add(r)

proc liveStateRecords(records: seq[AuditRecord]): seq[AuditRecord] =
  for r in records:
    if r.isLiveStateRecord(): result.add(r)

proc recordFor(records: seq[AuditRecord]; address: string): AuditRecord =
  for r in records:
    if r.resourceAddress == address:
      return r
  raise newException(ValueError,
    "no audit record for address '" & address & "'")

proc checkReconciles(records: seq[AuditRecord]; res: ApplyResult) =
  ## THE core invariant: the audit log accounts for EVERY resource the
  ## printed apply summary counts, verdict by verdict. Before build
  ## edges were audited, `applied` and `no-op` over-counted the log.
  check recordsWithOutcome(records, "applied") == res.appliedCount
  check recordsWithOutcome(records, "no-op") == res.noOpCount
  check recordsWithOutcome(records, "skipped") == res.skippedCount
  check recordsWithOutcome(records, "error") == res.errorCount
  check records.len == res.appliedCount + res.noOpCount +
    res.skippedCount + res.errorCount

# ---------------------------------------------------------------------------
# A v1 RBSL record, encoded exactly as the pre-change writer did, so the
# backward-compatibility claim is tested against real v1 bytes rather
# than against a re-encode of the current writer.
# ---------------------------------------------------------------------------

proc encodeV1AuditRecord(rec: AuditRecord): seq[byte] =
  var body: seq[byte]
  body.writeU64Le(uint64(rec.timestamp))
  body.writeString(rec.operationKind)
  body.writeString(rec.resourceAddress)
  body.writeString(rec.outcome)
  body.writeString(rec.diagnostic)
  body.writeString(rec.preDigestHex)
  body.writeString(rec.postDigestHex)
  body.add(if rec.restartNeeded: 1'u8 else: 0'u8)
  # v1 body ends here — no recordClass, no fingerprintHex.
  for ch in AuditMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(1'u16)
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "repro infra apply: the audit log accounts for build-action edges":

  test "every counted resource is audited; the two populations stay apart":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let tmpRoot = createTempDir("audit-edges-cover-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard
      let outDir = tmpRoot / "outputs"
      createDir(outDir)

      let edges = @[
        shellWriteEdge("edgeAlpha", outDir / "alpha.out", "alpha-payload"),
        shellWriteEdge("edgeBeta", outDir / "beta.out", "beta-payload")]
      let opts = applyOptionsFor(tmpRoot / "state1",
        tmpRoot / "build-cache", edges)
      let res = runInfraApply(LiveStateProfileText, opts)

      # The apply really ran both edges.
      check res.errorCount == 0
      check res.appliedCount == 2
      check res.skippedCount == 1          # the privileged live-state op
      check fileExists(outDir / "alpha.out")
      check fileExists(outDir / "beta.out")

      let log = readAuditLog(res.auditLogPath)
      check not log.truncatedTail

      # (1) RECONCILIATION — nothing the summary counted is missing.
      checkReconciles(log.records, res)

      # (2) SEPARATION — both populations present and self-describing.
      let edgeRecords = buildActionRecords(log.records)
      let liveRecords = liveStateRecords(log.records)
      check edgeRecords.len == 2
      check liveRecords.len == 1
      for r in edgeRecords:
        check r.recordClass == AuditClassBuildAction
      for r in liveRecords:
        check r.recordClass == AuditClassLiveState

      # Each edge is addressable by its build-graph id.
      let alpha = recordFor(edgeRecords, "edgeAlpha")
      let beta = recordFor(edgeRecords, "edgeBeta")
      check alpha.outcome == "applied"
      check beta.outcome == "applied"

      # (3) NO FAKED STATE — an edge has no observed pre/post state and
      #     the record does not pretend otherwise.
      for r in edgeRecords:
        check r.preDigestHex == ""
        check r.postDigestHex == ""
        check not r.restartNeeded
      # The live-state record, by contrast, carries NO build
      # fingerprint, is addressed by its PROFILE resource address (not
      # a build-graph action id), and uses the live-state operation
      # vocabulary. The two shapes are disjoint on every axis a reader
      # would key off.
      check liveRecords[0].fingerprintHex == ""
      check liveRecords[0].resourceAddress ==
        "feature:Repro-Test-Nonexistent-Feature-AuditGap"
      check liveRecords[0].outcome == "skipped"
      check liveRecords[0].operationKind notin
        ["build", "cache-hit", "cache-substitute"]

      # (4) Every edge carries a fingerprint, and distinct edges key
      #     distinctly.
      check alpha.fingerprintHex.len == 64
      check beta.fingerprintHex.len == 64
      check alpha.fingerprintHex != beta.fingerprintHex

  test "a cache-missing edge is identifiable, and so is why it missed":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let tmpRoot = createTempDir("audit-edges-miss-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard
      let outDir = tmpRoot / "outputs"
      createDir(outDir)
      let sharedCache = tmpRoot / "build-cache"
      let outPath = outDir / "converging.out"

      # --- Apply 1: cold cache. The edge MISSES and builds. ---
      let res1 = runInfraApply(LiveStateProfileText,
        applyOptionsFor(tmpRoot / "state1", sharedCache,
          @[shellWriteEdge("edgeConverging", outPath, "v1-payload")]))
      check res1.errorCount == 0
      let log1 = readAuditLog(res1.auditLogPath)
      checkReconciles(log1.records, res1)
      let miss = recordFor(buildActionRecords(log1.records),
        "edgeConverging")
      # A MISS is stated as such: the edge ran a local build, and its
      # verdict is the one the summary counted under `applied`.
      check miss.operationKind == "build"
      check miss.outcome == "applied"
      check miss.fingerprintHex.len == 64
      check res1.appliedCount == 1
      check res1.locallyBuiltActionCount == 1

      # --- Apply 2: same edge, same cache root, fresh state dir. The
      #     engine short-circuits: a HIT, and the log says so. ---
      let res2 = runInfraApply(LiveStateProfileText,
        applyOptionsFor(tmpRoot / "state2", sharedCache,
          @[shellWriteEdge("edgeConverging", outPath, "v1-payload")]))
      check res2.errorCount == 0
      let log2 = readAuditLog(res2.auditLogPath)
      checkReconciles(log2.records, res2)
      let hit = recordFor(buildActionRecords(log2.records),
        "edgeConverging")
      check hit.operationKind == "cache-hit"
      check hit.outcome == "no-op"
      check res2.noOpCount == 1
      # The converged edge keyed IDENTICALLY across the two
      # generations. This is the "the edge is stable" reading.
      check hit.fingerprintHex == miss.fingerprintHex

      # --- Apply 3: the edge's definition changed (new payload ⇒ new
      #     argv). It misses again, and the log shows the fingerprint
      #     MOVED — the "this edge re-keys" reading, which is the only
      #     way a permanently-missing edge is diagnosable from the log
      #     alone. ---
      let res3 = runInfraApply(LiveStateProfileText,
        applyOptionsFor(tmpRoot / "state3", sharedCache,
          @[shellWriteEdge("edgeConverging", outPath, "v2-payload")]))
      check res3.errorCount == 0
      let log3 = readAuditLog(res3.auditLogPath)
      checkReconciles(log3.records, res3)
      let rekeyed = recordFor(buildActionRecords(log3.records),
        "edgeConverging")
      check rekeyed.operationKind == "build"
      check rekeyed.outcome == "applied"
      check rekeyed.fingerprintHex != hit.fingerprintHex
      check rekeyed.resourceAddress == hit.resourceAddress

  test "a failed edge is audited as an error with its diagnostic":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let tmpRoot = createTempDir("audit-edges-fail-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard
      let outDir = tmpRoot / "outputs"
      createDir(outDir)

      let res = runInfraApply(LiveStateProfileText,
        applyOptionsFor(tmpRoot / "state", tmpRoot / "build-cache", @[
          shellWriteEdge("edgeOk", outDir / "ok.out", "ok-payload"),
          failingEdge("edgeBroken")]))
      check res.errorCount == 1
      check res.appliedCount == 1

      let log = readAuditLog(res.auditLogPath)
      checkReconciles(log.records, res)
      let edgeRecords = buildActionRecords(log.records)
      check edgeRecords.len == 2
      let broken = recordFor(edgeRecords, "edgeBroken")
      check broken.outcome == "error"
      check broken.recordClass == AuditClassBuildAction
      # The engine-side diagnostic reaches the log, so the audit trail
      # says WHICH edge failed and what it reported — not just that the
      # summary counted an error somewhere.
      check broken.diagnostic.len > 0
      check recordFor(edgeRecords, "edgeOk").outcome == "applied"

  test "the planner's drift baseline ignores build-action records":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      # A build edge carries no observed state. If it leaked into the
      # "what we LAST left it at" table it would register an empty
      # digest under its build-graph id — re-creating exactly the
      # live-state/build-edge conflation this change removes.
      let tmpRoot = createTempDir("audit-edges-baseline-", "")
      defer:
        try: removeDir(tmpRoot) except CatchableError: discard
      let outDir = tmpRoot / "outputs"
      createDir(outDir)
      let stateDir = tmpRoot / "state"

      let res = runInfraApply(LiveStateProfileText,
        applyOptionsFor(stateDir, tmpRoot / "build-cache",
          @[shellWriteEdge("edgeBaseline", outDir / "b.out", "payload")]))
      check res.errorCount == 0
      # The edge IS in the log...
      let edgeRecords = buildActionRecords(
        readAuditLog(res.auditLogPath).records)
      check edgeRecords.len == 1
      # ...and is NOT in the drift baseline.
      let recorded = loadRecordedDigests(stateDir)
      check "edgeBaseline" notin recorded

  test "a v1 record still decodes, and reads as live-state":
    # Generations committed before build-action auditing existed must
    # stay readable: `repro system audit` on an older generation, and
    # the planner's drift baseline, both walk these bytes.
    let tmpRoot = createTempDir("audit-edges-v1-", "")
    defer:
      try: removeDir(tmpRoot) except CatchableError: discard
    let logPath = tmpRoot / "apply.log"

    let v1 = encodeV1AuditRecord(AuditRecord(
      timestamp: 1_700_000_000,
      operationKind: "fs.systemFile",
      resourceAddress: "systemFile:/etc/legacy.conf",
      outcome: "applied",
      diagnostic: "",
      preDigestHex: "00ff",
      postDigestHex: "ff00",
      restartNeeded: false))
    var raw = newString(v1.len)
    for i, b in v1:
      raw[i] = char(b)
    writeFile(logPath, raw)

    let log = readAuditLog(logPath)
    check not log.truncatedTail
    check log.records.len == 1
    let rec = log.records[0]
    check rec.resourceAddress == "systemFile:/etc/legacy.conf"
    check rec.preDigestHex == "00ff"
    check rec.postDigestHex == "ff00"
    # A v1 record predates build-action edges, so it is live-state by
    # construction — never an unclassified record a reader must guess
    # about.
    check rec.recordClass == AuditClassLiveState
    check rec.isLiveStateRecord()
    check not rec.isBuildActionRecord()
    check rec.fingerprintHex == ""

    # A v2 record appended to the SAME log after the v1 one still reads
    # — the reader walks a mixed-version log without losing either.
    appendAuditRecord(logPath, AuditRecord(
      timestamp: 1_700_000_001,
      operationKind: "build",
      resourceAddress: "edgeMixed",
      outcome: "applied",
      recordClass: AuditClassBuildAction,
      fingerprintHex: "abc123"))
    let mixed = readAuditLog(logPath)
    check mixed.records.len == 2
    check mixed.records[0].isLiveStateRecord()
    check mixed.records[1].isBuildActionRecord()
    check mixed.records[1].fingerprintHex == "abc123"
