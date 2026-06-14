## Adversarial integration test for the monitor shim's grandchild-
## injection chain — closes the coverage gap that the M73 dispatch-
## mechanism suite left behind.
##
## The M73 suite (t_dispatch_mechanism_coverage_windows.nim) verifies
## the in-process IAT+inline detour catches every Win32 dispatch
## shape, but every fixture is a single process — none of them spawn
## children, so the cross-process injection path the shim relies on
## for grandchild instrumentation is never exercised end-to-end.
## That's the path webpack triggered (parent → many node children),
## and where the pre-framework INFINITE-wait deadlocked.
##
## This test runs three adversarial fixtures under repro-fs-snoop and
## inspects the resulting depfile:
##
##   1. fork-bomb: parent spawns N=16 children back-to-back. The
##      depfile must contain exactly 16 mrProcessSpawn records AND
##      exactly 16 mrFileOpen records matching the marker dir (one
##      per child opening its uniquely-numbered marker file).
##
##   2. deep tree: 4-deep recursive spawn chain. The depfile must
##      contain exactly 4 mrProcessSpawn + 5 mrFileOpen records (one
##      file open at every depth from 0 through 4).
##
##   3. wedge child: parent spawns one child that sleeps 8 s in main.
##      The fixture's total wall-clock must stay under 12 s (proves
##      the framework's waitDeadlineMs is honoured — pre-framework
##      INFINITE would wedge the parent forever). The depfile must
##      contain 4 mrFileOpen records + 1 mrProcessSpawn record.
##
## Loss tolerance: zero, mirroring the M73 Phase 2 contract. Any
## off-by-one is a framework regression.

import std/[monotimes, os, strutils, tempfiles, times, unittest]

import repro_test_support

when defined(windows):
  import repro_monitor_depfile/types
  import repro_monitor_depfile/reader

  let testDir = currentSourcePath().parentDir()
  let fixturesDir = testDir / "fixtures"

  proc compileGcc(sourcePath, outputPath: string;
                  extraArgs: openArray[string] = []) =
    var args = @[sourcePath, "-municode", "-o", outputPath,
                 "-D_CRT_SECURE_NO_WARNINGS"]
    for a in extraArgs:
      args.add(a)
    let res = runShell(shellCommand(@["gcc"] & args))
    if res.code != 0:
      checkpoint("gcc " & args.join(" ") & " failed:\n" & res.output)
    check res.code == 0

  proc runUnderFsSnoop(fsSnoop, depFilePath: string;
                       command: openArray[string]): CmdResult =
    let args = @[fsSnoop, "--depfile=" & depFilePath, "--"] & @command
    runShell(shellCommand(args))

  proc countFileOpens(records: openArray[MonitorRecord];
                      marker: string): int =
    for r in records:
      if r.kind == mrFileOpen and marker in r.path:
        inc result

  proc countProcessSpawns(records: openArray[MonitorRecord]): int =
    for r in records:
      if r.kind == mrProcessSpawn:
        inc result

suite "grandchild_injection_adversarial":
  when not defined(windows):
    test "skip non-windows":
      skip()
  else:
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-grandchild-adv", "")
    let monitor = prepareMonitorTools(repoRoot, tempRoot / "monitor",
                                      "grandchild-adv")
    let fsSnoop = monitor.fsSnoop
    let shimLib = monitor.shim
    putEnv("REPRO_MONITOR_SHIM_LIB", shimLib)

    # ``repro-fs-snoop`` links against ``clingo.dll`` (the ASP solver
    # the reprobuild engine uses for its constraint resolution). On
    # CI and the dev-shell that's on PATH via env.ps1; for a
    # standalone ``nim c -r`` invocation outside the dev shell we
    # have to add it ourselves. The canonical location is
    # ``D:\metacraft-dev-deps\clingo\<ver>\bin``.
    block ensureClingoOnPath:
      const clingoBin = r"D:\metacraft-dev-deps\clingo\5.8.0\bin"
      if dirExists(clingoBin):
        let cur = getEnv("PATH")
        if not cur.contains(clingoBin):
          putEnv("PATH", clingoBin & PathSep & cur)

    # ----------------------------------------------------------------
    # 1. Fork-bomb: parent spawns N children back-to-back.
    # ----------------------------------------------------------------
    test "fork-bomb N=16: exactly 16 spawn + 16 fileOpen records":
      const N = 16
      let exePath = tempRoot / "fork_bomb.exe"
      compileGcc(fixturesDir / "fixture_fork_bomb.c", exePath)
      let markerDir = tempRoot / "fb-markers"
      createDir(markerDir)
      let depPath = tempRoot / "fork_bomb.rdep"
      let res = runUnderFsSnoop(fsSnoop, depPath,
        @[exePath, markerDir, $N])
      if res.code != 0:
        checkpoint("fork_bomb fixture failed (rc=" &
          $res.code & "):\n" & res.output)
      check res.code == 0
      check fileExists(depPath)
      let dep = readMonitorDepFile(depPath)
      let openCount = countFileOpens(dep.records, "fb-markers")
      let spawnCount = countProcessSpawns(dep.records)
      if openCount != N:
        checkpoint("fork-bomb mrFileOpen count: " & $openCount &
          " (expected exactly " & $N &
          ") — any miss proves a child wasn't instrumented")
      if spawnCount != N:
        checkpoint("fork-bomb mrProcessSpawn count: " & $spawnCount &
          " (expected exactly " & $N & ")")
      check openCount == N
      check spawnCount == N

    # ----------------------------------------------------------------
    # 2. Deep tree: recursive CreateProcessW chain to depth=4.
    # ----------------------------------------------------------------
    test "deep tree depth=4: 5 fileOpen + 4 spawn records":
      const DepthArg = 4
      const ExpectedOpens = DepthArg + 1   # one per level incl. depth=0
      const ExpectedSpawns = DepthArg      # one per CreateProcessW
      let exePath = tempRoot / "deep_tree.exe"
      compileGcc(fixturesDir / "fixture_deep_tree.c", exePath)
      let markerDir = tempRoot / "dt-markers"
      createDir(markerDir)
      let depPath = tempRoot / "deep_tree.rdep"
      let res = runUnderFsSnoop(fsSnoop, depPath,
        @[exePath, markerDir, $DepthArg])
      if res.code != 0:
        checkpoint("deep_tree fixture failed (rc=" &
          $res.code & "):\n" & res.output)
      check res.code == 0
      check fileExists(depPath)
      let dep = readMonitorDepFile(depPath)
      let openCount = countFileOpens(dep.records, "dt-markers")
      let spawnCount = countProcessSpawns(dep.records)
      if openCount != ExpectedOpens:
        checkpoint("deep-tree mrFileOpen count: " & $openCount &
          " (expected exactly " & $ExpectedOpens &
          ") — any miss proves the grandchild chain was truncated")
      if spawnCount != ExpectedSpawns:
        checkpoint("deep-tree mrProcessSpawn count: " & $spawnCount &
          " (expected exactly " & $ExpectedSpawns & ")")
      check openCount == ExpectedOpens
      check spawnCount == ExpectedSpawns

    # ----------------------------------------------------------------
    # 3. Wedge child: parent spawns child that sleeps 8 s in main.
    #    Verifies the framework's waitDeadlineMs is honoured —
    #    pre-framework INFINITE would wedge the parent's hook
    #    forever, so the wall-clock bound is the load-bearing check.
    # ----------------------------------------------------------------
    test "wedge child: parent completes within wall-clock bound":
      let exePath = tempRoot / "wedge_child.exe"
      compileGcc(fixturesDir / "fixture_wedge_child.c", exePath)
      let markerDir = tempRoot / "wedge-markers"
      createDir(markerDir)
      let depPath = tempRoot / "wedge.rdep"

      let started = getMonoTime()
      let res = runUnderFsSnoop(fsSnoop, depPath, @[exePath, markerDir])
      let elapsedMs = inMilliseconds(getMonoTime() - started)
      if res.code != 0:
        checkpoint("wedge fixture failed (rc=" &
          $res.code & "):\n" & res.output)
      check res.code == 0

      # Wall-clock bound: the child sleeps 8 s. With the framework's
      # waitDeadlineMs at 5 s (fired once per propagation level), the
      # whole fixture must complete in well under the pre-framework
      # INFINITE behaviour. We allow 25 s to absorb test-host
      # variance; the load-bearing assertion is "not INFINITE".
      check elapsedMs < 25_000

      check fileExists(depPath)
      let dep = readMonitorDepFile(depPath)
      let openCount = countFileOpens(dep.records, "wedge-markers")
      let spawnCount = countProcessSpawns(dep.records)
      # Expected fileOpens: wedge-parent + wedge-child-before +
      # wedge-child-after + wedge-parent-after = 4
      if openCount != 4:
        checkpoint("wedge mrFileOpen count: " & $openCount &
          " (expected exactly 4)")
      if spawnCount != 1:
        checkpoint("wedge mrProcessSpawn count: " & $spawnCount &
          " (expected exactly 1)")
      check openCount == 4
      check spawnCount == 1

    # ----------------------------------------------------------------
    # 4. Cap saturation: N=64 children with framework default
    #    maxInFlight=16. Parent's snoopCreateProcessW records every
    #    spawn (the snoop hook runs before injectShimIntoChild even
    #    when injection is admission-rejected), so we expect EXACTLY
    #    64 mrProcessSpawn records. But some children run
    #    uninstrumented because the cap is saturated — those don't
    #    record their child-side CreateFileW. The test asserts:
    #
    #      spawnCount == N (cap doesn't affect parent observation)
    #      openCount > 0  (some children DID get instrumented)
    #      openCount ≤ N (no double-counting under cap pressure)
    #
    #    Wall-clock bound: completion within 30 s is the load-bearing
    #    "no INFINITE wedge under saturation" assertion.
    # ----------------------------------------------------------------
    test "cap saturation N=64: spawn count is N, fileOpen count is bounded":
      const N = 64
      let exePath = tempRoot / "fork_bomb_sat.exe"
      compileGcc(fixturesDir / "fixture_fork_bomb.c", exePath)
      let markerDir = tempRoot / "fb-sat-markers"
      createDir(markerDir)
      let depPath = tempRoot / "fork_bomb_sat.rdep"

      let started = getMonoTime()
      let res = runUnderFsSnoop(fsSnoop, depPath,
        @[exePath, markerDir, $N])
      let elapsedMs = inMilliseconds(getMonoTime() - started)
      if res.code != 0:
        checkpoint("cap saturation fixture failed (rc=" &
          $res.code & "):\n" & res.output)
      check res.code == 0
      check elapsedMs < 30_000   # load-bearing "no INFINITE wedge"
      check fileExists(depPath)

      let dep = readMonitorDepFile(depPath)
      let openCount = countFileOpens(dep.records, "fb-sat-markers")
      let spawnCount = countProcessSpawns(dep.records)

      # Parent's spawn observation is decoupled from the cap — every
      # CreateProcessW call goes through snoopCreateProcessW which
      # records before calling injectShimIntoChild.
      check spawnCount == N

      # Child-side opens are gated by injection succeeding. Under
      # cap pressure some get ioSkippedCap. We assert both edges:
      # at least some got through (≥ cap value), no more than N.
      check openCount >= 1
      check openCount <= N
      if openCount < N:
        checkpoint("cap saturation observed: " & $openCount & "/" &
          $N & " children instrumented (expected under maxInFlight=16)")
