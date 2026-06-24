## Windows-System-Resources Phase E — the engine-side broker-dispatch
## hook for ``requiresElevation = true`` build edges.
##
## Spec §2.1 + §3 + §7 say: the build engine MUST consult
## ``BuildAction.requiresElevation``, and when set, MUST delegate the
## fork to the privileged-operation broker (via a
## ``pokInlineExecCall``) instead of forking the child directly. This
## suite pins the engine-side wiring of that contract:
##
##   1. A mock ``brokerSpawn`` is invoked when an elevated edge runs.
##   2. The action materialises an output and is recorded in the
##      action cache.
##   3. Re-running the same edge hits the cache; the broker hook is
##      NOT invoked the second time.
##   4. ``brokerSpawn = nil`` + ``requiresElevation = true`` raises
##      ``BuildEngineError`` (no silent fallback to a direct fork).
##   5. The hook receives the verbatim argv (including the literal
##      ``@FILE:<path>`` tokens) + cwd + env from the edge.
##
## The test uses ``bakProcess`` actions with synthetic argv — the
## broker-side closure is purely a recording mock; no real privileged
## operation runs, no actual elevation prompt fires.
##
## See ``libs/repro_build_engine/src/repro_build_engine.nim``
## §``ElevatedExecSpawner`` + the pre-launch decision branch in
## ``runBuild``.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

const TmpDir = "build/test-tmp/test_elevated_inline_exec_hook"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

# ---------------------------------------------------------------------------
# Mock broker. ``invocations`` records every ``ElevatedExecRequest`` the
# engine handed off, so the cache-hit test can assert the second run
# did NOT touch the broker. ``materialiseOutput`` lets the mock write
# a file to disk so the engine's output-stat + cache-record path
# closes successfully (an elevated edge that produces no output would
# fail the `outputs-present` evidence step).
# ---------------------------------------------------------------------------

type
  BrokerRecorder = ref object
    invocations: seq[ElevatedExecRequest]
    materialiseOutput: string
    outputPayload: string
    returnOk: bool
    returnExitCode: int
    stdoutText: string
    stderrText: string
    diagnosticText: string

proc newRecorder(materialiseOutput = ""; outputPayload = "elevated-out\n";
                 returnOk = true; returnExitCode = 0;
                 stdoutText = "spawned ok\n"; stderrText = "";
                 diagnosticText = ""): BrokerRecorder =
  result = BrokerRecorder(
    invocations: @[],
    materialiseOutput: materialiseOutput,
    outputPayload: outputPayload,
    returnOk: returnOk,
    returnExitCode: returnExitCode,
    stdoutText: stdoutText,
    stderrText: stderrText,
    diagnosticText: diagnosticText)

proc makeBrokerSpawn(rec: BrokerRecorder): ElevatedExecSpawner =
  result = proc(req: ElevatedExecRequest):
      ElevatedExecResult {.gcsafe, closure.} =
    rec.invocations.add(req)
    if rec.materialiseOutput.len > 0:
      createDir(splitPath(rec.materialiseOutput).head)
      writeFile(rec.materialiseOutput, rec.outputPayload)
    ElevatedExecResult(
      ok: rec.returnOk,
      exitCode: rec.returnExitCode,
      stdout: rec.stdoutText,
      stderr: rec.stderrText,
      diagnostic: rec.diagnosticText)

# ---------------------------------------------------------------------------
# Build-graph helpers.
# ---------------------------------------------------------------------------

proc fingerprintFor(text: string): ContentDigest =
  casDigest(text.toOpenArrayByte(0, text.high),
            domain = hdActionFingerprint)

proc elevatedAction(id, outputPath: string;
                    argv: seq[string];
                    cacheable = true;
                    fingerprintToken = "default"): BuildAction =
  result = BuildAction(
    kind: bakProcess,
    id: id,
    outputs: @[outputPath],
    argv: argv,
    cwd: "",
    cacheable: cacheable,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintFor(id & "|" & fingerprintToken),
    requiresElevation: true)

proc oneElevatedGraph(outputPath: string;
                      argv: seq[string];
                      cacheable = true;
                      fingerprintToken = "default"): BuildGraph =
  let action = elevatedAction("t-elevated", outputPath, argv,
    cacheable = cacheable, fingerprintToken = fingerprintToken)
  graph(@[action], newSeq[BuildPool]())

proc nonElevatedAction(id, outputPath: string;
                       argv: seq[string];
                       fingerprintToken = "default"): BuildAction =
  result = BuildAction(
    kind: bakProcess,
    id: id,
    outputs: @[outputPath],
    argv: argv,
    cwd: "",
    cacheable: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintFor(id & "|" & fingerprintToken),
    requiresElevation: false)

proc elevatedConfig(cacheRoot: string;
                    recorder: BrokerRecorder): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = false
  result.bypassRunQuota = true
  result.brokerSpawn = makeBrokerSpawn(recorder)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "Windows-System-Resources Phase E — engine broker-dispatch hook":

  test "elevated edge runs under the broker; output materialises":
    resetTmp()
    let cacheRoot = TmpDir / "cache-e2e"
    let outputPath = absolutePath(TmpDir / "outputs-e2e" / "elevated.out")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)

    let recorder = newRecorder(
      materialiseOutput = outputPath,
      outputPayload = "phase-e elevated payload\n")
    let argv = @["C:\\actions-runner\\config.cmd",
                 "--unattended", "--token",
                 "@FILE:C:\\actions-runner-tokens\\mcl.token"]
    let g = oneElevatedGraph(outputPath, argv,
      fingerprintToken = "e2e-first")
    let res = runBuild(g, elevatedConfig(cacheRoot, recorder))
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    check res.results[0].launched == true
    check res.results[0].runQuotaBackend == "broker"
    check fileExists(outputPath)
    check recorder.invocations.len == 1
    # The broker received the verbatim argv (literal @FILE: token
    # preserved — the broker side re-expands it under elevation per
    # spec §2.1). The audit-redaction lives on the broker side, not
    # in the engine's request payload.
    check recorder.invocations[0].actionId == "t-elevated"
    check recorder.invocations[0].argv == argv
    check recorder.invocations[0].cwd == ""

  test "second run hits the cache; broker hook is NOT invoked":
    resetTmp()
    let cacheRoot = TmpDir / "cache-cachehit"
    let outputPath = absolutePath(TmpDir / "outputs-cachehit" / "elevated.out")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)

    let argv = @["/usr/bin/echo", "phase-e-cache"]
    let recorder = newRecorder(
      materialiseOutput = outputPath,
      outputPayload = "cached payload\n")

    # First run materialises + records.
    let firstGraph = oneElevatedGraph(outputPath, argv,
      fingerprintToken = "cachehit")
    let firstRes = runBuild(firstGraph, elevatedConfig(cacheRoot, recorder))
    check firstRes.results.len == 1
    check firstRes.results[0].status == asSucceeded
    check recorder.invocations.len == 1

    # Second run — same fingerprint, same outputs — must hit the
    # cache and NOT re-invoke the broker. The engine's pre-launch
    # broker-dispatch decision point sits AFTER the cache lookup, so
    # an action cache hit short-circuits before reaching the hook.
    let secondGraph = oneElevatedGraph(outputPath, argv,
      fingerprintToken = "cachehit")
    let secondRes = runBuild(secondGraph, elevatedConfig(cacheRoot, recorder))
    check secondRes.results.len == 1
    check secondRes.results[0].status in {asCacheHit, asUpToDate}
    check secondRes.results[0].launched == false
    check recorder.invocations.len == 1

  test "requiresElevation = true + brokerSpawn = nil fails closed":
    ## The reviewer's load-bearing assertion: a silent fallback to a
    ## direct fork is a bigger bug than the missing feature. With
    ## ``brokerSpawn`` left nil and an elevated edge in the graph,
    ## the engine MUST raise ``BuildEngineError`` with a clear
    ## diagnostic naming the action id and pointing the operator at
    ## ``repro infra apply``.
    resetTmp()
    let cacheRoot = TmpDir / "cache-failclosed"
    let outputPath = absolutePath(TmpDir / "outputs-failclosed" / "elev.out")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)

    let argv = @["/bin/true"]
    let g = oneElevatedGraph(outputPath, argv,
      fingerprintToken = "failclosed")
    var cfg = defaultBuildEngineConfig(cacheRoot)
    cfg.maxParallelism = 1
    cfg.deferLocalOutputBlobs = false
    cfg.bypassRunQuota = true
    # brokerSpawn intentionally left nil — runBuild MUST refuse to
    # proceed rather than silently spawn under the legacy path.
    var diagnostic = ""
    var raised = false
    try:
      discard runBuild(g, cfg)
    except BuildEngineError as err:
      raised = true
      diagnostic = err.msg
    check raised
    check diagnostic.contains("requiresElevation")
    check diagnostic.contains("brokerSpawn")
    check diagnostic.contains("t-elevated")
    # The fail-closed path MUST NOT leave the output behind — i.e.
    # the engine MUST raise BEFORE invoking any side-effecting
    # spawn. ``oneElevatedGraph`` did not pre-create the output, so
    # the file's absence here is the negative pin.
    check not fileExists(outputPath)

  test "non-elevated edges remain byte-identical (broker hook ignored)":
    ## A graph with NO ``requiresElevation = true`` edges must run
    ## end-to-end without consulting the broker hook even when one
    ## is wired. Pins the legacy direct-fork path is preserved
    ## verbatim — Phase E adds a NEW pre-launch branch, it does NOT
    ## rewrite the existing one.
    resetTmp()
    let cacheRoot = TmpDir / "cache-noflag"
    let outputPath = absolutePath(TmpDir / "outputs-noflag" / "plain.txt")
    createDir(cacheRoot)
    createDir(splitPath(outputPath).head)
    let recorder = newRecorder()
    # bakWriteText is a builtin action, so it materialises the
    # output without spawning anything — exercises the pre-launch
    # decision point without depending on a usable /usr/bin/echo or
    # cmd.exe on the test host.
    let action = BuildAction(
      kind: bakWriteText,
      id: "t-plain",
      outputs: @[outputPath],
      cacheable: true,
      actionCachePolicy: ffpTimestamp,
      weakFingerprint: fingerprintFor("plain|noflag"),
      builtinText: "plain payload\n",
      requiresElevation: false)
    var cfg = defaultBuildEngineConfig(cacheRoot)
    cfg.maxParallelism = 1
    cfg.deferLocalOutputBlobs = false
    cfg.brokerSpawn = makeBrokerSpawn(recorder)
    let g = graph(@[action], newSeq[BuildPool]())
    let res = runBuild(g, cfg)
    check res.results.len == 1
    check res.results[0].status == asSucceeded
    check fileExists(outputPath)
    check recorder.invocations.len == 0
