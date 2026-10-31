## The profile compile is a normal monitored edge: a payload a profile reads
## with `staticRead` invalidates the compiled intent.
##
## Primary assertion — `e2e_profile_compile_staticread_payload_change`: a
## profile whose `resources:` helper reads `payload.txt` through `staticRead`
## plans `alpha`, `bravo`, `charlie` across three payload edits with no other
## change, through the public `repro home plan`.
##
## This is the defect the edge's old structural fast path could not catch.
## That fast path named the published `.rbpi` after a digest of an `import
## ./…` text walk and returned it before the build engine was consulted;
## `payload.txt` is not imported, so the digest never moved and the second run
## planned `alpha` again. Measured before the fix (reprobuild `0fee0fe6`,
## x86_64-linux): alpha, alpha, alpha. Reinstating the fast path in
## `compileProfileToRbpi` turns this gate red at the bravo run.
##
## Vacuity guard: every run asserts the published intent holds EXACTLY ONE
## resource — an `fs.userFile` whose `content` is the payload — and that the
## content equals the payload as it stands, so the gate cannot pass on an
## intent that lost the resource or never read the file.
##
## Negative control: an unchanged payload on a second run spawns no `nim`
## (observed through the `nim` spy, see `profile_compile_edge_harness.nim`)
## and re-publishes nothing; the library-level case below additionally reads
## the ENGINE's own decision and requires `cdHit` with the edge not launched.
## Without this the primary assertion would also pass for an edge that simply
## recompiled every time.
##
## No mocks. The real `build/bin/repro`, the real Nim compiler, the real
## io-mon shim and the real filesystem; the `nim` on `PATH` is a pass-through
## counter, justified in the harness header.

## Platforms. The gate runs on every host. On Linux and Windows the unchanged
## runs must be answered from the action cache. On macOS (milestone GM0m) the
## edge may instead FAIL CLOSED where macOS monitoring cannot vouch for its
## reads: the library case then requires that the engine refused to publish
## (`cachePublishSkipReason`) and re-ran the edge, and the CLI case accepts a
## complete re-run (`cacheAnswered` in the harness). A published record on
## macOS is held to the Linux standard: the payload is in its observed reads
## and the unchanged run is a `cdHit`. Every run, on every host, must plan the
## payload as it stands.

import std/[os, strutils, tables, unittest]

import repro_build_engine
import repro_profile
import repro_profile_intent
import repro_profile_compile

import ./profile_compile_edge_harness

const PayloadProfile = """
import repro_profile

proc payloadText(): string =
  ## The helper reads its data with `staticRead`: a compile-time read that no
  ## `import` statement mentions.
  const text = staticRead("payload.txt")
  text

template payloadFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/payload-" & payloadText() & ".txt",
    content = payloadText())

profile "gm0StaticReadPayload":
  resources:
    payloadFile()
"""

proc checkSinglePayloadResource(intent: ProfileIntent; payload: string) =
  ## The vacuity guard: exactly one resource, an `fs.userFile`, whose
  ## content is the payload as it stands now.
  check intent.resources.len == 1
  if intent.resources.len == 1:
    let r = intent.resources[0]
    check r.kind == "fs.userFile"
    check r.fields.hasKey("content")
    if r.fields.hasKey("content"):
      check r.fields["content"].s == payload
    check r.fields["hostFile"].s == "~/payload-" & payload & ".txt"

proc checkPlans(run: PlanRun; payload: string) =
  checkpoint("repro home plan output:\n" & run.output)
  check run.exitCode == 0
  check run.createLines.len == 1
  check run.output.contains("1 resource(s) planned")
  if run.createLines.len == 1:
    check run.createLines[0].contains(
      "fs.userFile:~/payload-" & payload & ".txt")
  checkSinglePayloadResource(run.intent, payload)

suite "profile compile edge: staticRead payload change":

  test "e2e_profile_compile_staticread_payload_change":
    let sb = newProfileSandbox("staticread", PayloadProfile)
    defer: sb.dispose()

    sb.writeProfileFile("payload.txt", "alpha")
    let run1 = sb.runHomePlan()
    checkPlans(run1, "alpha")
    # A cold compile spawns nim — this is what makes the spy count below
    # meaningful rather than vacuously zero.
    check run1.nimSpawns >= 1
    let rbpiMtime = getLastModificationTime(sb.publishedRbpiPath())

    # Negative control: nothing changed, so the action cache answers. No nim
    # process is spawned and the published envelope is not rewritten. (On
    # macOS a complete re-run is the fail-closed alternative, see the header;
    # the envelope is then rewritten with the same content.)
    sleep(1100)  # ext4 / APFS / NTFS timestamp granularity.
    let run2 = sb.runHomePlan()
    checkPlans(run2, "alpha")
    check cacheAnswered(run2.nimSpawns, run1.nimSpawns,
      "unchanged payload, repro home plan")
    if run2.nimSpawns == 0:
      check getLastModificationTime(sb.publishedRbpiPath()) == rbpiMtime

    # The payload is the ONLY thing that changes from here on.
    sb.writeProfileFile("payload.txt", "bravo")
    let run3 = sb.runHomePlan()
    checkPlans(run3, "bravo")
    check run3.nimSpawns >= 1

    sb.writeProfileFile("payload.txt", "charlie")
    let run4 = sb.runHomePlan()
    checkPlans(run4, "charlie")
    check run4.nimSpawns >= 1

  test "library edge answers an unchanged payload from the action cache":
    # The same sequence through `compileProfileToRbpi`, so the negative
    # control can read the ENGINE's decision rather than infer it: the
    # unchanged run must be `cdHit` with the edge not launched.
    let sb = newProfileSandbox("staticread-lib", PayloadProfile)
    defer: sb.dispose()
    let savedPath = getEnv("PATH")
    putEnv("PATH", sb.spyDir & $PathSep & savedPath)
    defer: putEnv("PATH", savedPath)
    # The edge takes `$REPRO_NIM_COMPILER` over `PATH`, so with it set the
    # spy is bypassed and every spawn count below reads 0. `repro build`
    # publishes it to every test it runs (`ensureBootstrapToolchainEnv`), so
    # under the suite route this case used to fail at the cold compile's
    # spawn check (measured on m1, 2026-10-14). Removed here exactly as
    # `sandboxEnv` removes it for the CLI case; the spy forwards to that
    # compiler (`realNimCompiler`), so the compile itself is unchanged.
    let hadNimCompiler = existsEnv(ProfileNimCompilerEnvVar)
    let savedNimCompiler = getEnv(ProfileNimCompilerEnvVar)
    delEnv(ProfileNimCompilerEnvVar)
    defer:
      if hadNimCompiler: putEnv(ProfileNimCompilerEnvVar, savedNimCompiler)
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)

    sb.writeProfileFile("payload.txt", "alpha")
    let first = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("first: decision=" & $first.cacheDecision &
      " publishSkip=" & first.cachePublishSkipReason)
    check first.edgeLaunched
    checkSinglePayloadResource(decodeRbpi(first.rbpiBytes), "alpha")
    # The payload is in the monitored dependency record — the reason the
    # edge can be invalidated by it at all. Required (below) whenever the
    # record was published.
    var sawPayload = false
    for path in first.observedInputs:
      if path.endsWith("payload.txt"):
        sawPayload = true
    # A `staticRead` is a COMPILE-time read: it belongs to the compile edge's
    # record, which is the one its edit must re-run.
    var compileSawPayload = false
    for path in first.compileEdge.observedInputs:
      if path.endsWith("payload.txt"):
        compileSawPayload = true

    let spawnsBefore = sb.nimSpawnCount()
    let second = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("second: decision=" & $second.cacheDecision &
      " miss=" & second.cacheMissReason)
    if EdgeMayFailClosed and first.cachePublishSkipReason.len > 0:
      # macOS, fail-closed arm (GM0m): the engine refused to publish a record
      # it could not vouch for, so the unchanged run must execute again.
      echo "    [fail-closed, GM0m] library edge: publish skipped (",
        first.cachePublishSkipReason, "); the unchanged run re-ran"
      check second.edgeLaunched
      check second.cacheDecision != cdHit
      check second.cachePublishSkipReason.len > 0
      check sb.nimSpawnCount() > spawnsBefore
    else:
      check first.cachePublishSkipReason.len == 0
      check sawPayload
      check compileSawPayload
      check not second.edgeLaunched
      check second.cacheDecision == cdHit
      # Answered from the cache on BOTH edges: the compile edge (nim not
      # spawned) and the run edge (the profile binary not spawned).
      check second.compileEdge.cacheDecision == cdHit
      check not second.compileEdge.launched
      check second.runEdge.cacheDecision == cdHit
      check not second.runEdge.launched
      check sb.nimSpawnCount() == spawnsBefore
    checkSinglePayloadResource(decodeRbpi(second.rbpiBytes), "alpha")

    sb.writeProfileFile("payload.txt", "bravo")
    let third = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("third: decision=" & $third.cacheDecision &
      " miss=" & third.cacheMissReason)
    check third.edgeLaunched
    # The payload edit re-runs the compile, and the new binary (it embeds the
    # payload) re-runs the run edge through its declared input.
    check third.compileEdge.launched
    check third.runEdge.launched
    check sb.nimSpawnCount() > spawnsBefore
    checkSinglePayloadResource(decodeRbpi(third.rbpiBytes), "bravo")

  test "a new shell's temp directory does not invalidate the compile":
    # `nix develop` gives every shell its own `TMPDIR` / `TMP` / `TEMP` /
    # `TEMPDIR` (`/tmp/nix-shell.XXXXXX`). Nim and the C toolchain read
    # them, io-mon records the reads, and keyed by VALUE they made the first
    # compile in every new shell a full recompile of an unchanged profile
    # (measured: "input metadata changed: TEMP", ~7 s). The edge names them
    # as passthrough (`ProfileCompileScratchEnvNames`), like the provider
    # compile does.
    #
    # Positive control: a variable the edge does NOT name still invalidates
    # when it changes -- so the hit below is the passthrough rule, not
    # observed-environment keying having been switched off. The variable is
    # one Nim itself reads to find its user configuration
    # (`getConfigDir()`): `HOME` on Linux and macOS, `APPDATA` on Windows
    # (https://nim-lang.org/docs/nimc.html#compiler-usage-configuration-files).
    #
    # On macOS the edge may fail closed (header, GM0m): when the first
    # compile's record was not published, both later compiles must execute.
    #
    # Falsifying mutation (performed when this case was written): drop the
    # temp-directory names from the edge's passthrough. The second compile
    # misses with "input metadata changed: TEMP".
    let sb = newProfileSandbox("staticread-tmpdir", PayloadProfile)
    defer: sb.dispose()
    sb.writeProfileFile("payload.txt", "alpha")
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)

    const ControlVar = when defined(windows): "APPDATA" else: "HOME"
    const Names = ["TMPDIR", "TMP", "TEMP", "TEMPDIR", ControlVar]
    var saved: seq[(string, bool, string)]
    for name in Names:
      saved.add((name, existsEnv(name), getEnv(name)))
    defer:
      for (name, present, value) in saved:
        if present: putEnv(name, value) else: delEnv(name)

    proc enterShell(label: string) =
      let tmp = sb.root / ("shell-tmp-" & label)
      createDir(tmp)
      for name in ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]:
        putEnv(name, tmp)

    let controlOne = sb.root / "control-one"
    createDir(controlOne)
    putEnv(ControlVar, controlOne)
    enterShell("one")
    let first = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("first: decision=" & $first.cacheDecision &
      " publishSkip=" & first.cachePublishSkipReason)
    check first.edgeLaunched
    checkSinglePayloadResource(decodeRbpi(first.rbpiBytes), "alpha")
    let failedClosed = EdgeMayFailClosed and
      first.cachePublishSkipReason.len > 0
    if not failedClosed:
      check first.cachePublishSkipReason.len == 0

    enterShell("two")
    let second = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("second: decision=" & $second.cacheDecision &
      " miss=" & second.cacheMissReason)
    if failedClosed:
      echo "    [fail-closed, GM0m] temp-directory case: publish skipped (",
        first.cachePublishSkipReason, "); every compile re-runs"
      check second.edgeLaunched
    else:
      check second.cacheDecision == cdHit
      check not second.edgeLaunched
      # Both edges name the temp-directory variables as passthrough.
      check not second.compileEdge.launched
      check not second.runEdge.launched
    checkSinglePayloadResource(decodeRbpi(second.rbpiBytes), "alpha")

    # Positive control: an observed variable outside the passthrough set.
    let controlTwo = sb.root / "control-two"
    createDir(controlTwo)
    putEnv(ControlVar, controlTwo)
    let third = compileProfileToRbpi(sb.profilePath, opts)
    checkpoint("third: decision=" & $third.cacheDecision &
      " miss=" & third.cacheMissReason)
    check third.edgeLaunched
    if not failedClosed:
      check third.cacheMissReason.contains(ControlVar)
      # Nim reads it to find its configuration: the compile edge's input.
      check third.compileEdge.launched
      check third.compileEdge.cacheMissReason.contains(ControlVar)
    checkSinglePayloadResource(decodeRbpi(third.rbpiBytes), "alpha")
