## Windows-System-Resources Phase G end-to-end test: compile a
## production-profile-shaped fixture with ``nim c -r``, capture the
## emitted ProfileIntent JSON, and assert the macro recognised both
## live-state resource templates AND action-edge typed-tool /
## inlineExecCall calls inside a single ``resources:`` block.
##
## Sub-process compilation mirrors what ``compileProfileToRbpi``
## drives at apply time. The fixture is the Phase G analogue of the
## production ``machines/server/_windows-runner-001/
## system_windows_runner.nim`` profile — mixed live-state +
## action edges.
##
## Additionally, after parsing the JSON, the test:
##
##   * Plans the live-state half against ``producePlan`` to verify
##     it's apply-shaped (the planner doesn't trip over the new
##     ``buildActions`` field).
##   * Constructs an ``ApplyOptions`` carrying both halves and runs
##     ``runInfraApply`` with a MOCK build-action dispatcher so the
##     full integration runs end-to-end without spawning real
##     processes — pinning the contract the production wiring obeys.

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

import repro_elevation
import repro_infra
import repro_profile
import repro_profile_compile

const
  fixturesDir = currentSourcePath.parentDir.parentDir.parentDir /
    "fixtures" / "m83"
  buildBinDir = currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "build" / "test-bin" / "m83"
  buildCacheDir = currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "build" / "nimcache" / "m83"

proc compileAndRun(fixtureName: string): string =
  createDir(buildBinDir)
  createDir(buildCacheDir)
  let src = fixturesDir / fixtureName
  let outName = fixtureName.changeFileExt("exe")
  let outPath = buildBinDir / outName
  let cachePath = buildCacheDir / fixtureName.changeFileExt("")
  let compileCmd = "nim c --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(cachePath) & " " &
    "--out:" & quoteShell(outPath) & " " &
    quoteShell(src)
  let compileResult = execCmdEx(compileCmd)
  if compileResult.exitCode != 0:
    raise newException(IOError,
      "Phase G fixture compile failed: " & fixtureName & "\n" &
      compileResult.output)
  let runResult = execCmdEx(quoteShell(outPath))
  if runResult.exitCode != 0:
    raise newException(IOError,
      "Phase G fixture run failed: " & fixtureName & "\n" & runResult.output)
  result = runResult.output.strip()

suite "Windows-System-Resources Phase G e2e: production-profile-shaped fixture":

  test "fixture compiles + emits ProfileIntent with mixed resources":
    let js = compileAndRun("system_action_edges_phase_g.nim")
    let p = parseProfileIntentJson(js)
    check p.name == "systemActionEdgesPhaseG"
    # Live-state: 2 items (runner dir + service).
    check p.resources.len == 2
    var resByAddress = initTable[string, ResourceIntent]()
    for r in p.resources:
      resByAddress[r.address] = r
    check "runnerDir" in resByAddress
    check resByAddress["runnerDir"].kind == "fs.systemDirectory"
    check "runnerService" in resByAddress
    check resByAddress["runnerService"].kind == "windows.service"
    # Action edges: 2 items (extract + configure).
    check p.buildActions.len == 2
    var actsById = initTable[string, ProfileBuildAction]()
    for a in p.buildActions:
      actsById[a.id] = a
    check "extractRunner" in actsById
    check "configureRunner" in actsById
    # Both action edges require elevation.
    check actsById["extractRunner"].requiresElevation
    check actsById["configureRunner"].requiresElevation
    # The extract edge's outputs anchor on the runner's config.cmd.
    check "C:\\actions-runner\\config.cmd" in
      actsById["extractRunner"].outputs
    # The configure edge's argv carries the @FILE: token literal —
    # spec § 2.1 pins expansion at fork time, NOT at macro / codec time.
    var sawAtFile = false
    for a in actsById["configureRunner"].argv:
      if a.startsWith("@FILE:"):
        sawAtFile = true
    check sawAtFile
    # configureRunner declares an inter-action-edge dep on
    # extractRunner; the macro carries the seq through verbatim.
    check "extractRunner" in actsById["configureRunner"].deps

  test "the emitted JSON round-trips back to the same ProfileIntent":
    let js = compileAndRun("system_action_edges_phase_g.nim")
    let p1 = parseProfileIntentJson(js)
    let js2 = emitProfileIntentJson(p1)
    let p2 = parseProfileIntentJson(js2)
    check p1.resources.len == p2.resources.len
    check p1.buildActions.len == p2.buildActions.len
    for i in 0 ..< p1.buildActions.len:
      check p1.buildActions[i].id == p2.buildActions[i].id
      check p1.buildActions[i].argv == p2.buildActions[i].argv
      check p1.buildActions[i].outputs == p2.buildActions[i].outputs
      check p1.buildActions[i].requiresElevation ==
        p2.buildActions[i].requiresElevation

  test "the live-state half plans without tripping on buildActions":
    # Phase G must keep the existing planner path unchanged. The
    # planner reads from SystemProfile text — same path as today.
    # We render the live-state resources through the adapter and
    # feed the rendered text to producePlan; the action edges live
    # in a parallel seq the planner does NOT consume.
    let js = compileAndRun("system_action_edges_phase_g.nim")
    let p = parseProfileIntentJson(js)
    let sp = profileIntentToSystemProfile(p)
    check sp.resources.len == 2     # only live-state, action edges
                                     # don't lower to SystemResource.
    let txt = renderSystemProfileToText(sp)
    let plan = producePlan(txt, "phaseG-e2e-host")
    check plan.envelope.operations.len == 2

  test "runInfraApply end-to-end with mocked dispatcher (production-shape)":
    # The PRIMARY gate (per the task brief): a profile that looks
    # like the production ``system_windows_runner.nim`` (with
    # ``expandArchive.build(...)`` and ``inlineExecCall(...)``) compiles
    # + plans + applies without errors, and the action edges actually
    # flow through the broker.
    #
    # We use a MOCK dispatcher (rather than the real
    # ``mkBuildActionDispatcher``) because the action argv references
    # ``C:\actions-runner\...`` paths that don't exist on the CI host.
    # The mock returns "applied" outcomes for both edges so the
    # apply-driver tallies pin the integration's success.
    let tmpRoot = createTempDir("phaseG-e2e-apply-", "")
    defer:
      try: removeDir(tmpRoot)
      except CatchableError: discard
    let stateDir = tmpRoot / "state"
    createDir(stateDir)

    let js = compileAndRun("system_action_edges_phase_g.nim")
    let p = parseProfileIntentJson(js)
    let sp = profileIntentToSystemProfile(p)
    let txt = renderSystemProfileToText(sp)

    # Mock dispatcher: record every received action and return a
    # success outcome per edge.
    var receivedArgvs: seq[seq[string]]
    var receivedElevations: seq[bool]
    let mockDispatcher: BuildActionDispatcher = proc(
        actions: seq[ProfileBuildAction]):
        seq[BuildActionApplyOutcome] {.gcsafe.} =
      {.cast(gcsafe).}:
        for a in actions:
          receivedArgvs.add(a.argv)
          receivedElevations.add(a.requiresElevation)
          result.add(BuildActionApplyOutcome(
            id: a.id,
            address: a.id,
            ok: true,
            requiresElevation: a.requiresElevation,
            cacheHit: false,
            diagnostic: ""))

    var opts = ApplyOptions(
      stateDir: stateDir,
      hostIdentity: "phaseG-e2e-host",
      reproExe: "/usr/bin/false",
      elevationMode: emNoElevate,    # live-state half is skipped
                                     # since we have no real broker
      noPreview: true,
      buildActions: p.buildActions,
      buildActionDispatcher: mockDispatcher)
    let res = runInfraApply(txt, opts)

    # Action-edge half: both edges dispatched + applied.
    check res.buildActionResults.len == 2
    check res.buildActionResults[0].ok
    check res.buildActionResults[1].ok
    check receivedArgvs.len == 2
    # Both action edges crossed the broker hook (requiresElevation
    # propagated through the codec into the dispatcher).
    for e in receivedElevations:
      check e
    # The first action's argv references the resolved native tool
    # (the macro evaluated ``expandArchive.build`` at compile time;
    # on POSIX it resolves to ``unzip`` for a ``.zip`` archive).
    # We just pin that the argv is non-empty + the broker received
    # the typed-tool-resolved argv, not the bare typed-tool name.
    check receivedArgvs[0].len >= 2
    # The second action's argv carries the @FILE: literal — the
    # broker hook is the layer that expands it at fork time.
    var sawAtFile = false
    for a in receivedArgvs[1]:
      if a.startsWith("@FILE:"):
        sawAtFile = true
    check sawAtFile
    # Apply tallies: action-edge half contributes 2 applied; the
    # live-state half (windows.service + fs.systemDirectory) is
    # skipped because elevationMode == emNoElevate AND those drivers
    # require elevation; they count as "skipped".
    check res.appliedCount == 2
    check res.errorCount == 0
    # The generation pointer commit ran (the apply completed cleanly).
    check res.generationId.len > 0
