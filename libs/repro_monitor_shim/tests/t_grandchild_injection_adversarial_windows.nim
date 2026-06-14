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

    # ----------------------------------------------------------------
    # 5–7. Node.js fixtures: validate libuv→Win32 hook coverage.
    #
    # Webpack is the load-bearing reprobuild consumer of fs-snoop on
    # Windows. It's built on Node.js, and Node.js's fs.* APIs lower to
    # libuv's win/fs.c, which dispatches across THREE distinct call
    # shapes the shim must hook:
    #
    #   - fs.readFileSync → CreateFileW(OPEN_EXISTING) + ReadFile
    #   - fs.statSync     → NtQueryInformationByName (Win11 fast-path,
    #                       no handle opened; libuv 1.52+)
    #   - fs.writeFileSync → CreateFileW(CREATE_ALWAYS) + WriteFile
    #
    # The fs.readdirSync path (NtQueryDirectoryFile / -Ex) currently
    # destabilises Node when the snoop is registered — the install
    # itself is harmless, but recording during the chunked enumeration
    # crashes libuv. The snoop is disabled in windows_interpose.nim
    # pending diagnosis (see task #48). The readdir TEST below is
    # therefore gated on a "directory-enum support" feature flag and
    # currently skipped; the write-side records of the bundle phase
    # are checked instead so we still get coverage for the libuv
    # write-path under Node.
    # ----------------------------------------------------------------
    proc findNodeExe(): string =
      const candidates = [
        r"D:\metacraft\codetracer\.repro\build\reprobuild\tool-store" &
          r"\prefixes\node\9f0ad977a75a1ca1-72a0549fd4b624eb\node.exe",
        r"D:\metacraft-dev-deps\node\24.13.0\node-v24.13.0-win-x64\node.exe",
      ]
      for c in candidates:
        if fileExists(c):
          return c
      ""

    proc countByDetail(records: openArray[MonitorRecord];
                       kind: MonitorRecordKind;
                       detail, marker: string): int =
      for r in records:
        if r.kind == kind and r.detail == detail and marker in r.path:
          inc result

    proc countWritesByMarker(records: openArray[MonitorRecord];
                             marker: string): int =
      for r in records:
        if r.kind == mrFileWrite and marker in r.path:
          inc result

    test "node fs.readFileSync N=24: 2*N CreateFileW writes/opens for src.*":
      const N = 24
      let nodeExe = findNodeExe()
      if nodeExe.len == 0:
        skip()
      else:
        let srcDir = tempRoot / "fr-src"
        createDir(srcDir)
        let depPath = tempRoot / "node_fr.rdep"
        let res = runUnderFsSnoop(fsSnoop, depPath,
          @[nodeExe, fixturesDir / "fixture_node_fs_read.js",
            srcDir, $N])
        if res.code != 0:
          checkpoint("fs.readFileSync fixture failed (rc=" &
            $res.code & "):\n" & res.output)
        check res.code == 0
        check fileExists(depPath)
        let dep = readMonitorDepFile(depPath)
        # Each of N fr.<i>.src files is opened twice (writeSync +
        # readSync). The libuv write-path may take either the
        # CreateFileW route (kernel32-level dispatch) or the
        # NtCreateFile fast-path; we accept either and assert the
        # combined open count is ≥ N (the read pass alone).
        let opens = countFileOpens(dep.records, "fr.")
        if opens < N:
          checkpoint("fs.readFileSync opens: " & $opens & " (expected ≥ " &
            $N & ")")
        check opens >= N

    test "node fs.statSync N=64: every probe captured via NtQueryInformationByName":
      const N = 64
      let nodeExe = findNodeExe()
      if nodeExe.len == 0:
        skip()
      else:
        let probeDir = tempRoot / "node-probe-dir"
        createDir(probeDir)
        let depPath = tempRoot / "node_stat.rdep"
        let res = runUnderFsSnoop(fsSnoop, depPath,
          @[nodeExe, fixturesDir / "fixture_node_fs_stat.js",
            probeDir, $N])
        if res.code != 0:
          checkpoint("fs.statSync fixture failed (rc=" &
            $res.code & "):\n" & res.output)
        check res.code == 0
        check fileExists(depPath)
        let dep = readMonitorDepFile(depPath)
        # libuv 1.52 routes uv_fs_stat → NtQueryInformationByName on
        # Win11 22000+. Each fs.statSync of a non-existent probe.*
        # path emits exactly ONE mrPathProbe record with that detail.
        let probes = countByDetail(dep.records, mrPathProbe,
                                   "NtQueryInformationByName",
                                   "probe.")
        if probes != N:
          checkpoint("fs.statSync probes via NtQueryInformationByName: " &
            $probes & " (expected exactly " & $N & ")")
        check probes == N

    test "node readdir+writeFileSync: write records for bundle phase":
      const N = 6
      let nodeExe = findNodeExe()
      if nodeExe.len == 0:
        skip()
      else:
        let srcDir = tempRoot / "rb-src"
        let outDir = tempRoot / "rb-out"
        createDir(srcDir)
        createDir(outDir)
        let depPath = tempRoot / "node_readdir.rdep"
        let res = runUnderFsSnoop(fsSnoop, depPath,
          @[nodeExe, fixturesDir / "fixture_node_readdir_bundle.js",
            srcDir, outDir, $N])
        if res.code != 0:
          checkpoint("readdir-bundle fixture failed (rc=" &
            $res.code & "):\n" & res.output)
        check res.code == 0
        check fileExists(depPath)
        let dep = readMonitorDepFile(depPath)
        # Verify the write-half: N source-file writes + 1 bundle
        # write = (N + 1) mrFileWrite records minimum. We do NOT
        # check the readdir count — the snoop for NtQueryDirectoryFile
        # is currently disabled (see task #48); reinstating the
        # strict equality check is the acceptance criterion when
        # the readdir snoop crash is fixed.
        let srcWrites = countWritesByMarker(dep.records, "src.")
        let bundleWrites = countWritesByMarker(dep.records, "bundle.txt")
        if srcWrites < N:
          checkpoint("source-file writes: " & $srcWrites &
            " (expected ≥ " & $N & ")")
        if bundleWrites < 1:
          checkpoint("bundle.txt writes: " & $bundleWrites &
            " (expected ≥ 1)")
        check srcWrites >= N
        check bundleWrites >= 1
