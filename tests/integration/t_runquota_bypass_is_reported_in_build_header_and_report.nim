## RA-13 — the no-lease / ``--runquota=off`` bypass is surfaced in the
## build header AND the run report, and on bypass the engine's LOCAL pool
## gate still bounds a named pool (the fallback enforcement).
##
## Build-Engine-And-Scheduler.md § "One executor, one resource authority":
## when a command runs in the explicit no-RunQuota fallback it runs actions
## with NO lease, so host limits and cross-session fairness do not apply.
## That state MUST be reported in the build header and the run report (it
## cannot make concurrent invocations safe) and MUST never be entered
## silently. But the engine must still keep the declared pool bounded —
## otherwise a ``host/linker`` pool would run unbounded on bypass.
##
## Assertions (each fails if the feature is absent/wrong):
##
##  1. BYPASS FLAG — a build run with ``bypassRunQuota`` sets
##     ``runQuotaBypassed`` on the engine result; an active-RunQuota build
##     does NOT. (Drives both the header line and the report field.)
##  2. REPORT FIELD — the real ``runQuotaReportJson`` (the exact derivation
##     the run report embeds) states ``bypassed=true`` + the
##     locally-enforced-only authority + ``concurrentInvocationsSafe=false``
##     on bypass, and the inverse when RunQuota is the authority.
##  3. HEADER LINE — the real ``runQuotaAuthorityHeaderLine`` (the exact
##     string the build header logs) states the bypass/locally-enforced-only
##     status on bypass, and does NOT claim bypass when active.
##  4. FALLBACK ENFORCEMENT — on the bypass path a named pool of capacity N
##     with >N ready actions never runs more than N concurrently (the local
##     gate is the SOLE enforcement there, since there is no RunQuota).

import std/[algorithm, json, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cli_support

import repro_test_support

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

proc writePoolFixture(path: string) =
  fixtureWrite(path, """#!/bin/sh
set -eu
idx="$1"
log="$2"
out="$3"
mkdir -p "$(dirname "$log.$idx.start")" "$(dirname "$out")"
date +%s.%N > "$log.$idx.start"
sleep 0.2
date +%s.%N > "$log.$idx.end"
printf 'pool %s\n' "$idx" > "$out"
""")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

when defined(macosx) or defined(linux):
  var cachedMonitorTools: MonitorTools
  var cachedMonitorToolsReady = false
  proc monitorTools(repoRoot: string): MonitorTools =
    if not cachedMonitorToolsReady:
      cachedMonitorTools = prepareMonitorTools(repoRoot,
        repoRoot / "build" / "test-monitor-ra13b", "ra13b-monitor")
      putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
      cachedMonitorToolsReady = true
    cachedMonitorTools

proc maxPoolConcurrency(tempRoot, prefix: string; count: int): int =
  var events: seq[tuple[t: float, delta: int]] = @[]
  for i in 0 ..< count:
    let startPath = tempRoot / (prefix & "." & $i & ".start")
    let endPath = tempRoot / (prefix & "." & $i & ".end")
    if not fileExists(startPath) or not fileExists(endPath):
      checkpoint("missing pool log for index " & $i)
      return count + 1
    events.add((t: parseFloat(readFile(startPath).strip()), delta: 1))
    events.add((t: parseFloat(readFile(endPath).strip()), delta: -1))
  events.sort(proc(a, b: tuple[t: float, delta: int]): int =
    result = cmp(a.t, b.t)
    if result == 0: result = cmp(a.delta, b.delta))
  var current = 0
  for event in events:
    current += event.delta
    result = max(result, current)

suite "RA-13 runquota bypass surfaced in build header + report":

  test "run report field states bypass / locally-enforced-only on bypass":
    let report = runQuotaReportJson(bypassed = true)
    check report["bypassed"].getBool == true
    check report["authority"].getStr == "local-engine-pool-gate-only"
    check report["concurrentInvocationsSafe"].getBool == false

  test "run report field states runquota authority when not bypassed":
    let report = runQuotaReportJson(bypassed = false)
    check report["bypassed"].getBool == false
    check report["authority"].getStr == "runquota"
    check report["concurrentInvocationsSafe"].getBool == true

  test "build header line states bypass / locally-enforced-only on bypass":
    let line = runQuotaAuthorityHeaderLine(bypassed = true)
    check line.toLowerAscii.contains("bypass")
    check line.toLowerAscii.contains("locally-enforced-only")
    check line.toLowerAscii.contains("not")

  test "build header line does not claim bypass when runquota is active":
    let line = runQuotaAuthorityHeaderLine(bypassed = false)
    check not line.toLowerAscii.contains("bypass")
    check line.toLowerAscii.contains("active")

  when isNixSupported:
    test "bypass build sets runQuotaBypassed and the local pool gate still bounds it":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-ra13-bypass", "")
      defer: removeDir(tempRoot)

      let app = getAppFilename()
      let fixture = tempRoot / "pool-fixture.sh"
      writePoolFixture(fixture)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / ".repro-cache"
      createDir(workRoot)

      var actions: seq[BuildAction] = @[]
      for i in 0 ..< 6:
        actions.add action("link-" & $i, [fixture, $i,
          tempRoot / "link-log", workRoot / "link" / ($i & ".txt")],
          cwd = workRoot, outputs = ["link/" & $i & ".txt"],
          pool = "link", poolUnits = 1'u32, commandStatsId = "link-" & $i)

      # Bypass run: NO RunQuota lease. The local link pool cap of 2 is the only
      # enforcement; without it the 6 actions would run up to maxParallelism=8
      # at once.
      let buildResult = runBuild(graph(actions, [pool("link", 2'u32)]),
        BuildEngineConfig(
          cacheRoot: cacheRoot,
          runQuotaCliPath: app,
          monitorCliPath: monitorTools(repoRoot).monitorCliPath,
          monitorCliArgs: monitorTools(repoRoot).monitorCliArgs,
          maxParallelism: 8'u32,
          stdoutLimit: 256 * 1024,
          stderrLimit: 256 * 1024,
          bypassRunQuota: true))

      proc byId(id: string): ActionResult =
        for item in buildResult.results:
          if item.id == id: return item
        raise newException(ValueError, "missing result " & id)

      for i in 0 ..< 6:
        let item = byId("link-" & $i)
        if item.status != asSucceeded:
          checkpoint("failed action " & item.id & " exit=" & $item.exitCode &
            " backend=" & item.runQuotaBackend & "\nstdout:\n" &
            item.stdout & "\nstderr:\n" & item.stderr)
        check item.status == asSucceeded

      # The bypass state is surfaced on the engine result (drives header+report).
      check buildResult.runQuotaBypassed
      for item in buildResult.results:
        if item.launched:
          check item.runQuotaBackend == "runquota-bypass"

      # FALLBACK ENFORCEMENT: the local gate kept the pool bounded at 2 even
      # though there is no RunQuota to enforce it.
      let observed = maxPoolConcurrency(tempRoot, "link-log", 6)
      check observed >= 2   # the pool actually overlapped (not serialized to 1)
      check observed <= 2   # and never exceeded the local cap

    test "active-RunQuota build does not claim bypass":
      # An action-free build resolves through the engine with no bypass; the
      # result must NOT be flagged as bypassed, so the header/report stay
      # truthful. (A graph with only built-in copy actions launches no process
      # under a lease but never enters the bypass path.)
      let tempRoot = createTempDir("repro-ra13-active", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      let cacheRoot = tempRoot / ".repro-cache"
      let inputPath = workRoot / "src" / "in.txt"
      fixtureWrite(inputPath, "active input\n")

      var config = defaultBuildEngineConfig(cacheRoot)
      config.suppressTrace = true
      let copyAction = builtinAction(bakCopyFile, "active-copy",
        cwd = workRoot, inputs = ["src/in.txt"], outputs = ["out/copied.txt"])
      let buildResult = runBuild(graph([copyAction]), config)
      check buildResult.results[0].status == asSucceeded
      check not buildResult.runQuotaBypassed
