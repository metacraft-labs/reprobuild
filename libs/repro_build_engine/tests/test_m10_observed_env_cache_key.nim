## Windows-Build-Correctness M10 — an environment variable a build READ must
## become part of its cache key.
##
## io-mon records `mrEnvRead` with the variable's NAME: the monitor saw that
## the build asked for it, and folding the VALUE into the cache key is the
## CONSUMER's half of the contract (`io_mon/types.nim` states it in as many
## words: "the CONSUMER folds the queried env vars' VALUES into its cache
## key"). Until this milestone reprobuild had no such half. Every `mrEnvRead`
## landed on `foldMonitorDepFileEvidence`'s `else: discard` arm, on ALL THREE
## platforms -- so macOS and Linux had recorded environment reads faithfully
## for two rounds, Windows M10 added them, and the action cache ignored the lot.
##
## That is a false cache HIT, which is the same defect class as a monitoring
## failure that reports success: a build reads `SOURCE_DATE_EPOCH`, somebody
## changes it, and the next build serves the old outputs. Closing the Windows
## capability gap without this would have been half a deliverable -- the
## evidence would have been recorded and then thrown away.
##
## BOTH DIRECTIONS ARE TESTED, and the second is not a formality:
##
##   * a variable that was READ and CHANGED must MISS;
##   * a variable that was READ and did NOT change must HIT; and a variable
##     that changed but was never read must HIT.
##
## An implementation that always answered "changed" would pass the first and
## fail the others, and it would make every action that reads a variable
## permanently uncacheable -- the cardinal sin arriving through the consumer
## rather than through a missed read. `PATH` is read by essentially every
## process, so "any env read means never cache" is not a theoretical wrong
## answer, it is the wrong answer that disables the cache entirely.
##
## The assertions are on the CACHE DECISION of a real `runBuild`, not on a
## diagnostic string: a diagnostic would pass against an implementation that
## complained and served the stale result anyway.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_local_store
import io_mon/[capabilities, types, writer]

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 707, threadId: 707, path: path, detail: "")

proc envRead(name: string; scope = "name"): MonitorRecord =
  ## The shape every io-mon arm writes: the variable NAME in `path`, never a
  ## path. `io_mon/shim/windows_interpose.emitEnvRead` adds `source=`/`scope=`
  ## to the detail; the macOS and Linux arms write `env-read` / `linux getenv`.
  ## The consumer must key on the KIND and the NAME, not on the detail text,
  ## which is why these cases vary the detail and none of them asserts on it.
  MonitorRecord(kind: mrEnvRead, observationKind: moEnvRead,
    osPid: 707, threadId: 707, path: name,
    detail: "env-read source=getenv scope=" & scope)

proc writeRmdf(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Scenario = object
  root: string
  cacheRoot: string
  workRoot: string
  sourcePath: string
  outputPath: string
  rmdfPath: string

proc setupScenario(name: string): Scenario =
  result.root = createTempDir("repro-m10-" & name, "")
  result.cacheRoot = result.root / "cache"
  result.workRoot = result.root / "work"
  result.sourcePath = result.workRoot / "src" / "input.txt"
  result.outputPath = result.workRoot / "out" / "product.txt"
  result.rmdfPath = result.root / "action.rdep"
  createDir(result.workRoot / "src")
  createDir(result.workRoot / "out")
  writeFile(result.sourcePath, "payload\n")

proc scenarioAction(scenario: Scenario; env: openArray[string]): BuildAction =
  ## The action's IDENTITY is fixed: `builtinAction` derives the weak
  ## fingerprint from the id alone, so changing `env` here does NOT change it.
  ## That is deliberate and it is what makes these cases mean something -- the
  ## only thing that can turn a hit into a miss is the observed-environment
  ## machinery under test, not an incidental re-identification of the action.
  result = builtinAction(bakCopyFile, "produce",
    cwd = scenario.workRoot,
    inputs = ["src/input.txt"],
    outputs = ["out/product.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = scenario.rmdfPath
  result.env = @env

proc runOnce(scenario: Scenario; env: openArray[string]): BuildRunResult =
  runBuild(graph([scenarioAction(scenario, env)]),
    defaultBuildEngineConfig(scenario.cacheRoot))

suite "M10 an observed environment variable is part of the cache key":

  test "an UNCHANGED observed variable still hits":
    ## The direction that fails against "any env read means never cache".
    ## Without it, the invalidation case below would pass against an
    ## implementation that simply never serves a hit again.
    let scenario = setupScenario("hit")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath,
      profileRecords(defaultHooksMonitorProfile()) &
      @[fileRead(scenario.sourcePath), envRead("SOURCE_DATE_EPOCH")])

    let first = runOnce(scenario, ["SOURCE_DATE_EPOCH=1700000000"])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario, ["SOURCE_DATE_EPOCH=1700000000"])
    check second.results[0].status in {asCacheHit, asUpToDate}
    check second.results[0].cacheDecision == cdHit

  test "CHANGING an observed variable re-runs the action":
    ## The defect this milestone exists to close, stated as the consequence a
    ## user would meet: `SOURCE_DATE_EPOCH` moves and the build serves the
    ## outputs it made under the old one.
    let scenario = setupScenario("miss")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath,
      profileRecords(defaultHooksMonitorProfile()) &
      @[fileRead(scenario.sourcePath), envRead("SOURCE_DATE_EPOCH")])

    let first = runOnce(scenario, ["SOURCE_DATE_EPOCH=1700000000"])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario, ["SOURCE_DATE_EPOCH=1800000000"])
    check second.results[0].cacheDecision != cdHit
    check second.results[0].status notin {asCacheHit, asUpToDate}

  test "UNSETTING an observed variable re-runs the action":
    ## Unset and set-to-empty are different states and both differ from
    ## "set to a value": a program branching on whether a variable is DEFINED
    ## sees a change that a value comparison alone would miss. The record
    ## carries `present` separately for exactly this case.
    let scenario = setupScenario("unset")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath,
      profileRecords(defaultHooksMonitorProfile()) &
      @[fileRead(scenario.sourcePath), envRead("CFLAGS")])

    let first = runOnce(scenario, ["CFLAGS=-O2"])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario, [])
    check second.results[0].cacheDecision != cdHit

  test "an observed variable going from UNSET to EMPTY re-runs the action":
    ## The case a naive `value == value` comparison gets wrong: both render as
    ## "" and the action would hit, even though the program's `if
    ## "X" in os.environ` test just flipped.
    let scenario = setupScenario("empty")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath,
      profileRecords(defaultHooksMonitorProfile()) &
      @[fileRead(scenario.sourcePath), envRead("CFLAGS")])

    let first = runOnce(scenario, [])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario, ["CFLAGS="])
    check second.results[0].cacheDecision != cdHit

  test "changing a variable the build NEVER READ still hits":
    ## The false-re-run direction. Actions run with large environments and
    ## almost none of it is an input; folding the whole environment in would
    ## make an unrelated change to `TMP` or `PROMPT` re-run the world. Only
    ## what the monitor OBSERVED being read may enter the key.
    let scenario = setupScenario("unread")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath,
      profileRecords(defaultHooksMonitorProfile()) &
      @[fileRead(scenario.sourcePath), envRead("SOURCE_DATE_EPOCH")])

    let first = runOnce(scenario,
      ["SOURCE_DATE_EPOCH=1700000000", "UNRELATED=before"])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario,
      ["SOURCE_DATE_EPOCH=1700000000", "UNRELATED=after"])
    check second.results[0].status in {asCacheHit, asUpToDate}
    check second.results[0].cacheDecision == cdHit

  test "an action that observed NO variable is unaffected":
    ## The compatibility half. A record with no observed environment must be
    ## byte-identical to what was written before this feature existed, so no
    ## warm cache anywhere is invalidated by adding it. `strongIdentityPayload`
    ## appends its env section only when there is one, and `encodeRecord`
    ## keeps the older on-disk version for such a record; this is the
    ## behavioural end of that.
    let scenario = setupScenario("none")
    defer: removeDir(scenario.root)
    writeRmdf(scenario.rmdfPath,
      profileRecords(defaultHooksMonitorProfile()) &
      @[fileRead(scenario.sourcePath)])

    let first = runOnce(scenario, ["SOURCE_DATE_EPOCH=1700000000"])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario, ["SOURCE_DATE_EPOCH=9999999999"])
    check second.results[0].status in {asCacheHit, asUpToDate}
    check second.results[0].cacheDecision == cdHit

suite "M10 the observed-environment record round-trips":

  test "the env inputs survive encode/decode and change the strong key":
    ## `computeStrongFingerprint` is what a cache hit is decided by, so the
    ## env section has to reach it AND has to be absent from the payload of a
    ## record that has none -- otherwise adding this field would shift every
    ## existing strong fingerprint on every machine and cost the world one
    ## full rebuild.
    let weak = weakFingerprintFromText("edge")
    let noEnv = computeStrongFingerprint(weak, [])
    check computeStrongFingerprint(weak, [], []) == noEnv

    let a = computeStrongFingerprint(weak, [],
      [EnvFingerprint(name: "X", present: true, value: "1")])
    let b = computeStrongFingerprint(weak, [],
      [EnvFingerprint(name: "X", present: true, value: "2")])
    let unset = computeStrongFingerprint(weak, [],
      [EnvFingerprint(name: "X", present: false, value: "")])
    let empty = computeStrongFingerprint(weak, [],
      [EnvFingerprint(name: "X", present: true, value: "")])
    check a != noEnv
    check a != b
    # Unset and set-to-empty must not collide, or the `present` flag is
    # decorative.
    check unset != empty

  test "a record with env inputs decodes what it encoded":
    var record = ActionResultRecord(
      weakFingerprint: weakFingerprintFromText("edge"),
      policy: ffpChecksum,
      outputPayloadKind: opkMetadataOnly,
      envInputs: @[
        EnvFingerprint(name: "SOURCE_DATE_EPOCH", present: true,
          value: "1700000000"),
        EnvFingerprint(name: "CFLAGS", present: false, value: "")])
    record.strongFingerprint = computeStrongFingerprint(record.weakFingerprint,
      record.inputs, record.envInputs)
    let decoded = decodeActionResultRecord(encodeActionResultRecord(record))
    check decoded.envInputs.len == 2
    check decoded.envInputs[0].name == "SOURCE_DATE_EPOCH"
    check decoded.envInputs[0].present
    check decoded.envInputs[0].value == "1700000000"
    check decoded.envInputs[1].name == "CFLAGS"
    check not decoded.envInputs[1].present
    check decoded.strongFingerprint == record.strongFingerprint

  test "a record with NO env inputs did not have its CACHE KEY moved":
    ## REWRITTEN TWICE, and the two rewrites pull in opposite directions, so
    ## both reasons are recorded here.
    ##
    ## Originally this read `check version == 3'u16`, on the reasoning that
    ## "an older reader must still accept the record, which it only does if
    ## the version field did not move" — the guarantee M10 needed, because M10
    ## was adding a field and had no business costing the world a rebuild for
    ## it.
    ##
    ## The §5.5 C4 record-format bump (Action-Cache-Per-Edge-Store.md) spent
    ## that version field deliberately, so the assertion was dropped: it had
    ## become a claim that could only be satisfied by reverting C4.
    ##
    ## The version field is now pinned AGAIN, but it is no longer a
    ## compatibility claim — it is a TRUST one. `ActionRecordVersionEvidence`
    ## `Epoch` (6) is the first version written by a binary whose no-evidence
    ## publish guard actually fires; every earlier version, 5 included, was
    ## written while that guard was dead. So the number this case pins is the
    ## epoch, and pinning it is the point: an accidental change to it is
    ## either a silent cache wipe or a silent un-drain, and both should fail
    ## here rather than in the field.
    ##
    ## What the case was always FOR is untouched: that M10's env section still
    ## costs nothing to a record that has none. That was two claims wearing
    ## one assertion —
    ##
    ##   1. the STRONG FINGERPRINT of an env-free record is unchanged, which
    ##      is the half that would invalidate every cache on every machine;
    ##      and
    ##   2. the encoded bytes carry no env section.
    ##
    ## Claim 1 is the one worth having, and it is checked directly rather than
    ## through a proxy — the version field never actually established it,
    ## since the key is computed by `computeStrongFingerprint` and not by the
    ## record encoder at all.
    ##
    ## The record carries real INPUT PATHS, deliberately. An input-free record
    ## would pin a key that no path ever reached, and the change most likely
    ## to move this key by accident is one to how paths are written.
    var record = ActionResultRecord(
      weakFingerprint: weakFingerprintFromText("legacy-fixture-edge"),
      policy: ffpTimestamp,
      outputPayloadKind: opkMetadataOnly)
    record.inputs = @[
      FileFingerprint(path: "/work/checkout/src/alpha.c",
        policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 11, mtimeNs: 22)),
      FileFingerprint(path: "/work/checkout/src/beta.c",
        policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 33, mtimeNs: 44)),
      FileFingerprint(path: "relative.h", policy: ffpTimestamp,
        metadata: FileMetadata(kind: ffkRegular, sizeBytes: 55, mtimeNs: 66))]
    record.strongFingerprint = computeStrongFingerprint(record.weakFingerprint,
      record.inputs)
    # 1. The env-free key is byte-identical to the key computed with an
    #    explicitly empty env list, i.e. the section contributes nothing.
    check computeStrongFingerprint(record.weakFingerprint, record.inputs) ==
      computeStrongFingerprint(record.weakFingerprint, record.inputs, [])
    # And it is this exact value, pinned to what the binary that predates
    # BOTH M10 and C4 computed for it. A change to the key payload fails
    # here rather than silently costing every machine one full rebuild.
    #
    # THIS VALUE MUST NOT MOVE WITH THE EPOCH. The epoch changes which
    # records are READ; it does not change how a key is COMPUTED. If this
    # digest ever moves in the same commit as a version bump, the bump
    # reached into `strongIdentityPayload` and is doing more than it says.
    check digestHex(record.strongFingerprint) ==
      "28c642b92be7b7deafe4cc2394d8a4f0c99d9e0e1c3a8e6de09ee44d7ddb3a51"
    # 2. Nothing decodes back as an env input.
    let encoded = encodeActionResultRecord(record)
    check encoded.len > 6
    # Literals rather than the constants, deliberately: asserting
    # `version == ActionRecordVersionEvidenceEpoch` would hold at every
    # version and pin nothing. A number a contributor has to change on
    # purpose is the whole mechanism.
    let version = uint16(encoded[4]) or (uint16(encoded[5]) shl 8)
    check version == 6'u16
    check decodeActionResultRecord(encoded).envInputs.len == 0

    # ... and the env-carrying record is at the SAME version, not the next
    # one. This used to assert a PAIRING (env-free at N, env-carrying at N+1)
    # because v4 appended the env section only when it was non-empty. Since
    # v5 the count is always written, zero included, so the optional-section
    # pairing no longer exists and asserting it would re-introduce a
    # conditional the format deliberately dropped.
    var withEnv = record
    withEnv.envInputs = @[EnvFingerprint(name: "X", present: true, value: "1")]
    withEnv.strongFingerprint = computeStrongFingerprint(
      withEnv.weakFingerprint, withEnv.inputs, withEnv.envInputs)
    let encodedEnv = encodeActionResultRecord(withEnv)
    let envVersion = uint16(encodedEnv[4]) or (uint16(encodedEnv[5]) shl 8)
    check envVersion == 6'u16
    check decodeActionResultRecord(encodedEnv).envInputs.len == 1

    # 3. THE REFUSAL, which is what makes the epoch a drain rather than a
    #    relabelling. A frame that is byte-identical to one this encoder
    #    produces, differing ONLY in its version word, is refused for every
    #    pre-epoch version — including 5, which is the one a binary built
    #    from mainline today still writes.
    for stale in [2'u16, 3'u16, 4'u16, 5'u16]:
      var patched = encoded
      patched[4] = byte(stale and 0xff'u16)
      patched[5] = byte((stale shr 8) and 0xff'u16)
      expect EnvelopeError:
        discard decodeActionResultRecord(patched)
