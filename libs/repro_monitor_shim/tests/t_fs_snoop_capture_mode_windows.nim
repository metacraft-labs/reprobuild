## Integration test: reproduces the codetracer-webpack wedge at the
## fs-snoop CLI level, without going through the reprobuild engine.
##
## The wedge profile (memory: project_codetracer_webpack_wedge_postsuccess):
## a sh-script action that spawns Node.js wedges at sh→bash with no
## node spawn, BUT only when fs-snoop's child stdio is captured into
## a pipe (the way ``osproc.startProcess`` on Windows captures by
## default). When fs-snoop inherits the parent's terminal stdio, the
## same chain runs in 9 seconds. This test exercises both modes
## directly via the fs-snoop ``--capture-stdio`` flag (added in this
## round) so the wedge surfaces in 30 seconds instead of 5 minutes
## under the full build engine.
##
## Also validates spec-required directory-enumerate coverage: the
## fixture's ``fs.readdirSync`` MUST land in the depfile, regardless
## of whether the readdir snoop in the shim is installed or routed via
## a different API (task #49).

import std/[os, monotimes, strutils, tempfiles, times, unittest]
import repro_test_support
import repro_monitor_depfile/types
import repro_monitor_depfile/reader

when defined(windows):
  let testDir = currentSourcePath().parentDir()
  let fixturesDir = testDir / "fixtures"

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

  proc runFsSnoop(fsSnoopExe, depFilePath: string;
                   command: openArray[string];
                   captureStdio: bool;
                   captureStdioPath: string = ""): CmdResult =
    var args = @[fsSnoopExe, "--depfile=" & depFilePath]
    if captureStdio:
      args.add("--capture-stdio")
    if captureStdioPath.len > 0:
      args.add("--capture-stdio-path=" & captureStdioPath)
    args.add("--")
    for a in command:
      args.add(a)
    runShell(shellCommand(args))

  proc dirEnumerateCount(records: openArray[MonitorRecord];
                          marker: string): int =
    for r in records:
      if r.kind == mrDirectoryEnumerate and marker in r.path:
        inc result

  proc probeCount(records: openArray[MonitorRecord]; marker: string): int =
    for r in records:
      if r.kind == mrPathProbe and marker in r.path:
        inc result

  proc fileWriteCount(records: openArray[MonitorRecord];
                       marker: string): int =
    for r in records:
      if r.kind == mrFileWrite and marker in r.path:
        inc result

suite "fs_snoop_capture_mode_integration":
  when not defined(windows):
    test "skip non-windows":
      skip()
  else:
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-fssnoop-cap", "")
    let monitor = prepareMonitorTools(repoRoot, tempRoot / "monitor",
                                      "fssnoop-cap")
    let fsSnoop = monitor.fsSnoop
    let shimLib = monitor.shim
    putEnv("REPRO_MONITOR_SHIM_LIB", shimLib)

    # Ensure clingo on PATH for the fs-snoop CLI's clingo.dll dep.
    block ensureClingoOnPath:
      const clingoBin = r"D:\metacraft-dev-deps\clingo\5.8.0\bin"
      if dirExists(clingoBin):
        let cur = getEnv("PATH")
        if not cur.contains(clingoBin):
          putEnv("PATH", clingoBin & PathSep & cur)

    test "node-webpack-proxy: inherited-stdio mode (baseline — must NOT wedge)":
      const N = 12
      const M = 200  # Modest stdout flood — bounded so inherited mode finishes.
      let nodeExe = findNodeExe()
      if nodeExe.len == 0:
        skip()
      else:
        let srcDir = tempRoot / "inh-src"
        let outDir = tempRoot / "inh-out"
        createDir(srcDir)
        createDir(outDir)
        let depPath = tempRoot / "inh.rdep"
        let started = getMonoTime()
        let res = runFsSnoop(fsSnoop, depPath,
          @[nodeExe, fixturesDir / "fixture_node_webpack_proxy.js",
            srcDir, outDir, $N, $M],
          captureStdio = false)
        let elapsedMs = inMilliseconds(getMonoTime() - started)
        if res.code != 0:
          checkpoint("fixture failed (rc=" & $res.code & "):\n" &
            res.output)
        check res.code == 0
        check elapsedMs < 30_000   # load-bearing "no wedge"
        check fileExists(depPath)
        let dep = readMonitorDepFile(depPath)
        # bundle.txt write — fixture's exit gate; if the depfile has
        # it, the child reached the end without crashing.
        check fileWriteCount(dep.records, "bundle.txt") >= 1

    test "node-webpack-proxy: capture-stdio mode (reproduces build-engine wedge if buggy)":
      const N = 12
      const M = 5000  # Heavier stdout flood — would fill a 64KB pipe.
      let nodeExe = findNodeExe()
      if nodeExe.len == 0:
        skip()
      else:
        let srcDir = tempRoot / "cap-src"
        let outDir = tempRoot / "cap-out"
        createDir(srcDir)
        createDir(outDir)
        let depPath = tempRoot / "cap.rdep"
        let stdioPath = tempRoot / "cap-stdio.log"
        let started = getMonoTime()
        let res = runFsSnoop(fsSnoop, depPath,
          @[nodeExe, fixturesDir / "fixture_node_webpack_proxy.js",
            srcDir, outDir, $N, $M],
          captureStdio = true,
          captureStdioPath = stdioPath)
        let elapsedMs = inMilliseconds(getMonoTime() - started)
        if res.code != 0:
          checkpoint("capture-mode fixture failed (rc=" & $res.code &
            "; elapsed=" & $elapsedMs & "ms):\n" & res.output)
        # Diagnostic: if the wedge reproduces, the wall-clock will
        # explode (>60s) AND the captured stdio file will be
        # truncated (no final "OK n=…" line).
        if elapsedMs > 60_000:
          checkpoint("WEDGE REPRODUCED: capture mode hit 60s timeout")
          if fileExists(stdioPath):
            let last = readFile(stdioPath)[^1024 .. ^1]
            checkpoint("last 1KB of captured stdio:\n" & last)
        check res.code == 0
        check elapsedMs < 30_000
        check fileExists(depPath)
        let dep = readMonitorDepFile(depPath)
        check fileWriteCount(dep.records, "bundle.txt") >= 1

    test "node-webpack-proxy: capture-stdio coverage (directory-enumerate present)":
      ## Per reprobuild spec, ``mrDirectoryEnumerate`` is REQUIRED.
      ## Removing the readdir hook to avoid the libuv-1.52 crash is
      ## not acceptable; this test will FAIL until the underlying
      ## API is identified and hooked safely.
      const N = 8
      const M = 100  # Small stdout — focus on records, not stdio.
      let nodeExe = findNodeExe()
      if nodeExe.len == 0:
        skip()
      else:
        let srcDir = tempRoot / "dir-src"
        let outDir = tempRoot / "dir-out"
        createDir(srcDir)
        createDir(outDir)
        let depPath = tempRoot / "dir.rdep"
        let res = runFsSnoop(fsSnoop, depPath,
          @[nodeExe, fixturesDir / "fixture_node_webpack_proxy.js",
            srcDir, outDir, $N, $M],
          captureStdio = false)
        if res.code != 0:
          checkpoint("dir-coverage fixture failed (rc=" & $res.code &
            "):\n" & res.output)
        check res.code == 0
        let dep = readMonitorDepFile(depPath)
        let dirEnums = dirEnumerateCount(dep.records, "dir-src")
        if dirEnums < 1:
          checkpoint("FAIL: 0 mrDirectoryEnumerate records for the " &
            "readdir on srcDir. The shim is not hooking the API libuv " &
            "1.52 uses for fs.readdirSync on Win11 26100 (task #49).")
        check dirEnums >= 1
        # Probe coverage: N fs.statSync calls on non-existent paths.
        let probes = probeCount(dep.records, "probe.")
        if probes < N:
          checkpoint("path-probe records: " & $probes & " (expected ≥ " &
            $N & ")")
        check probes >= N
