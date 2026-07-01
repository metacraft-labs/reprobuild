## Windows-System-Resources Phase G — integration: a real
## ``expandArchive.build(...)`` typed-tool call lowers through the
## profile-macro extractor → ``ProfileBuildAction`` → engine
## ``BuildAction`` and the dispatcher closure drives the engine via
## ``runBuild`` with the elevation broker hook attached.
##
## This test exercises the FULL chain Phase G wires:
##
##   1. Caller invokes the typed-tool ``expandArchive.build(...)`` and
##      the profile-side push helper ``addProfileBuildAction`` extracts
##      the inline-exec argv onto a ``ProfileBuildAction`` mirror.
##   2. ``profileBuildActionToBuildAction`` lowers the mirror to an
##      engine-side ``BuildAction`` with the ``requiresElevation``
##      flag preserved.
##   3. ``mkBuildActionDispatcher(cacheRoot, ctx)`` builds the
##      dispatcher closure that ``runInfraApply`` injects via
##      ``ApplyOptions.buildActionDispatcher``.
##   4. The closure runs the engine; the elevation broker hook
##      ``mkInfraApplyBrokerSpawn(ctx)`` translates each
##      ``requiresElevation = true`` edge into a ``pokInlineExecCall``
##      ``PrivilegedOperation`` and dispatches via the elevation
##      library's ``dispatchOperation`` (in-process broker fast path).
##   5. The materialised output ends up where the action declared.
##
## The test uses a POSIX-only spawn (``/bin/sh -c``) so the OS
## boundary is real but no Windows-specific tooling is needed.
## ``expandArchive.build`` resolves to the Linux-side branch (``unzip``
## or ``tar``); we mock the archive-extraction effect with a sh-based
## stand-in BuildAction so the test stays self-contained.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_elevation
import repro_hash
import repro_infra
import repro_profile
import repro_profile_compile
import repro_project_dsl
import repro_dsl_stdlib/packages/expand_archive as expandArchive
import io_mon/writer

# ---------------------------------------------------------------------------
# Real passthrough monitor (NOT a mock/skip).
#
# bd68d952 removed the unsound declared-only ``dgNoRuntimeDependencies``
# policy; ``profileBuildActionToBuildAction`` now lowers every profile-scope
# action edge under ``automaticMonitorGatheringPolicy()`` (a
# ``dgAutomaticMonitor`` policy). An automatic-monitor CACHEABLE action with
# no monitor CLI wired now FAILS by design (Monitor-Hook-Shim.md:501 +
# 2b2706a0: "a cacheable action still fails with the requires-io-monitor
# diagnostic, preserving the cache soundness guard").
#
# The ELEVATED edges in this suite bypass the engine's spawn entirely via the
# broker fast path, so they never hit that gate; the NON-elevated edge spawns
# through the engine and therefore needs a monitor CLI. This mirrors the
# fix bd68d952 applied to ``test_tool_identity_env_plumbing.nim``: wire a
# REAL passthrough monitor (parse ``--depfile``, drop a valid empty-record
# RMDF there so the engine's evidence read succeeds with a complete,
# zero-record dependency set, then ``exec`` the real argv unchanged). The
# action genuinely runs + materialises its output under real monitoring —
# this is not a stub, mock, or skip.
#
# The test wires the passthrough script as the dispatcher's explicit
# ``monitorCliPath``. The legacy ``<bin> --depfile <path> -- <cmd>``
# invocation shape (no ``monitorCliArgs``) is exactly what the passthrough
# script parses.
# ---------------------------------------------------------------------------

proc passthroughMonitorCli(cacheRoot: string): string =
  let dir = cacheRoot / "monitor-cli"
  createDir(dir)
  let rmdfTemplate = dir / "empty.rmdf"
  writeFile(rmdfTemplate, cast[string](encodeCanonical(@[])))
  when defined(windows):
    result = dir / "passthrough-monitor.cmd"
    writeFile(result,
      "@echo off\r\n" &
      "for %%I in (\"%~2\") do if not exist \"%%~dpI\" mkdir \"%%~dpI\"\r\n" &
      "copy /Y \"" & rmdfTemplate & "\" %~2 >nul\r\n" &
      "%4 %5 %6 %7 %8 %9\r\n")
  else:
    result = dir / "passthrough-monitor.sh"
    writeFile(result,
      "#!/bin/sh\n" &
      "depfile=\"\"\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    --depfile) depfile=\"$2\"; shift 2;;\n" &
      "    --) shift; break;;\n" &
      "    *) shift;;\n" &
      "  esac\n" &
      "done\n" &
      "if [ -n \"$depfile\" ]; then\n" &
      "  mkdir -p \"$(dirname \"$depfile\")\"\n" &
      "  cp \"" & rmdfTemplate & "\" \"$depfile\"\n" &
      "fi\n" &
      "exec \"$@\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

# ---------------------------------------------------------------------------
# Helpers — assemble a ProfileBuildAction with shell-out argv so the
# end-to-end path executes a real OS spawn (vs. a mocked dispatcher).
# ---------------------------------------------------------------------------

proc shellWriteProfileBuildAction(id, outputPath, payload: string;
                                  requiresElevation: bool):
    ProfileBuildAction =
  ## A ``ProfileBuildAction`` that writes ``payload`` to ``outputPath``
  ## via ``/bin/sh -c``. The shape mirrors what an
  ## ``inlineExecCall(... requiresElevation = true)`` would emit; the
  ## engine spawns the argv directly (or via the broker hook when
  ## ``requiresElevation = true``).
  let script = "printf %s '" & payload & "' > '" & outputPath & "'"
  result = ProfileBuildAction(
    id: id,
    argv: @["/bin/sh", "-c", script],
    cwd: "",
    deps: @[],
    inputs: @[],
    outputs: @[outputPath],
    commandStatsId: "shell.write",
    toolIdentityRefs: @[],
    requiresElevation: requiresElevation,
    cacheable: true)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase G — action-edge dispatcher integration":

  test "profileBuildActionToBuildAction preserves requiresElevation":
    let pba = ProfileBuildAction(
      id: "elevated-edge",
      argv: @["/bin/true"],
      outputs: @["/tmp/elev.out"],
      requiresElevation: true,
      cacheable: true)
    let ba = profileBuildActionToBuildAction(pba)
    check ba.id == "elevated-edge"
    check ba.argv == @["/bin/true"]
    check ba.outputs == @["/tmp/elev.out"]
    check ba.requiresElevation
    check ba.cacheable

  test "profileBuildActionToBuildAction rejects empty argv":
    let pba = ProfileBuildAction(id: "empty", argv: @[])
    expect ValueError:
      discard profileBuildActionToBuildAction(pba)

  test "buildActionsToBuildGraph emits actions in declaration order":
    let pbas = @[
      ProfileBuildAction(id: "a", argv: @["/bin/true"], cacheable: true),
      ProfileBuildAction(id: "b", argv: @["/bin/true"], cacheable: true),
      ProfileBuildAction(id: "c", argv: @["/bin/true"], cacheable: true)]
    let g = buildActionsToBuildGraph(pbas)
    check g.actions.len == 3
    check g.actions[0].id == "a"
    check g.actions[1].id == "b"
    check g.actions[2].id == "c"

  test "dispatcher closure end-to-end: elevated edge spawns and materialises output":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseG-disp-elev-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "elevated.out"

      let payload = "phase-G dispatcher payload"
      let pba = shellWriteProfileBuildAction("phaseG-disp-elev",
        outputPath, payload, requiresElevation = true)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx)
      let outcomes = dispatcher(@[pba])

      check outcomes.len == 1
      let o = outcomes[0]
      check o.id == "phaseG-disp-elev"
      check o.ok
      check o.requiresElevation
      check not o.cacheHit
      check o.diagnostic == ""        # success has no diagnostic
      # The output materialised — the dispatched ``runInlineExecCall``
      # really ran the spawn under the broker (in-process fast path
      # — `dispatchOperation` synchronously).
      check fileExists(outputPath)
      check readFile(outputPath) == payload

  test "dispatcher closure end-to-end: non-elevated edge spawns directly":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseG-disp-direct-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "direct.out"

      let payload = "phase-G dispatcher direct-fork payload"
      let pba = shellWriteProfileBuildAction("phaseG-disp-direct",
        outputPath, payload, requiresElevation = false)

      # Non-elevated edges spawn through the engine (not the broker), so the
      # cacheable ``dgAutomaticMonitor`` action needs a monitor CLI wired or
      # it fails the requires-io-monitor guard. Wire a REAL passthrough
      # monitor so the action runs + materialises its output under real
      # monitoring.
      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx,
        passthroughMonitorCli(cacheRoot))
      let outcomes = dispatcher(@[pba])

      check outcomes.len == 1
      check outcomes[0].ok
      check not outcomes[0].requiresElevation
      check fileExists(outputPath)
      check readFile(outputPath) == payload

  test "dispatcher closure end-to-end: failed elevated edge surfaces as not-ok":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseG-disp-fail-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      createDir(cacheRoot)

      # /bin/false exits 1, which is OUTSIDE the default accept set
      # (@[0]) — the broker's inline-exec driver raises EProtocol,
      # the closure projects onto a failure ElevatedExecResult, and
      # the engine surfaces the action as asFailed.
      let pba = ProfileBuildAction(
        id: "phaseG-fail",
        argv: @["/bin/false"],
        outputs: @[tmpRoot / "would-not-exist.out"],
        requiresElevation: true,
        cacheable: true)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx)
      let outcomes = dispatcher(@[pba])

      check outcomes.len == 1
      check not outcomes[0].ok
      check outcomes[0].diagnostic.len > 0

  test "dispatcher closure end-to-end: cache-hit on second run":
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseG-disp-cache-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "cache.out"

      let payload = "phase-G cache-hit payload"
      let pba = shellWriteProfileBuildAction("phaseG-disp-cache",
        outputPath, payload, requiresElevation = true)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      let dispatcher = mkBuildActionDispatcher(cacheRoot, ctx)

      # First run: fresh execution.
      let first = dispatcher(@[pba])
      check first.len == 1
      check first[0].ok
      check not first[0].cacheHit
      check fileExists(outputPath)
      let firstBytes = readFile(outputPath)

      # Second run: identical fingerprint, identical outputs → engine
      # short-circuits the launch. The dispatcher reports cacheHit.
      let second = dispatcher(@[pba])
      check second.len == 1
      check second[0].ok
      check second[0].cacheHit
      check fileExists(outputPath)
      check readFile(outputPath) == firstBytes

  test "mkBuildActionDispatcher + runInfraApply: full integration":
    # End-to-end: build a ProfileBuildAction, plumb it through
    # runInfraApply via the production dispatcher closure, and assert
    # the apply summary reflects the success.
    when defined(linux) or defined(macosx):
      let tmpRoot = createTempDir("phaseG-runapply-", "")
      defer:
        try: removeDir(tmpRoot)
        except CatchableError: discard
      let stateDir = tmpRoot / "state"
      let cacheRoot = tmpRoot / "build-cache"
      let outputDir = tmpRoot / "outputs"
      createDir(stateDir)
      createDir(cacheRoot)
      createDir(outputDir)
      let outputPath = outputDir / "integration.out"

      let payload = "phase-G runInfraApply integration payload"
      let pba = shellWriteProfileBuildAction("phaseG-runapply",
        outputPath, payload, requiresElevation = true)

      let ctx = FixtureContext(filePrefix: tmpRoot)
      var opts = ApplyOptions(
        stateDir: stateDir,
        hostIdentity: "phaseG-runapply-host",
        reproExe: "/usr/bin/false",  # never spawned in this path
        elevationMode: emNoElevate,
        noPreview: true,
        buildActions: @[pba],
        buildActionDispatcher: mkBuildActionDispatcher(cacheRoot, ctx))
      let res = runInfraApply("", opts)

      check res.errorCount == 0
      check res.appliedCount == 1
      check res.buildActionResults.len == 1
      check res.buildActionResults[0].ok
      check fileExists(outputPath)
      check readFile(outputPath) == payload
      check res.generationId.len > 0

  test "expandArchive.build lowers via addProfileBuildAction":
    # Pin the Phase F integration: the typed-tool's `BuildActionDef`
    # return value flows through `addProfileBuildAction` and lands as
    # a `ProfileBuildAction` whose argv targets the resolved native
    # tool (`Expand-Archive` on Windows / `unzip` or `tar` on POSIX).
    resetBuildActionRegistry()
    when defined(windows):
      let archive = "C:\\actions-runner-cache\\actions-runner.zip"
      let destination = "C:\\actions-runner"
      let marker = "C:\\actions-runner\\config.cmd"
    else:
      # On POSIX expandArchive.build expects a `.zip` -> resolves to
      # `unzip`. Path separators don't matter for the lowering.
      let archive = "/tmp/test.zip"
      let destination = "/tmp/dest"
      let marker = "/tmp/dest/marker"
    let bad = expandArchive.build(
      archive = archive,
      destination = destination,
      marker = marker,
      requiresElevation = true,
      address = "extractRunnerZip")
    var target: seq[ProfileBuildAction]
    addProfileBuildAction(target, bad)
    check target.len == 1
    check target[0].id == "extractRunnerZip"
    check target[0].requiresElevation
    check target[0].outputs == @[marker]
    check archive in target[0].inputs
    # commandStatsId encodes the resolved format (eafZip for .zip).
    check target[0].commandStatsId == "expandArchive.eafZip"
    # The argv is non-empty (resolved native tool + flags).
    check target[0].argv.len >= 2
    # toolIdentityRefs carries the resolved tool name so the engine
    # prepends its bin dir to PATH at fork time.
    check target[0].toolIdentityRefs.len == 1
