## Named-Targets M3 verification: ``repro watch name1 name2`` against
## a two-target fixture. Asserts that:
##
##   1. cycle 1 builds the union of both target closures in ONE engine
##      pass (single ``scheduler: actions=`` line per cycle);
##   2. editing a source file owned only by ``alpha``'s closure causes
##      cycle 2 to rerun ``alpha`` while ``beta`` stays cache-hit; and
##   3. editing a source file referenced by BOTH closures causes both
##      to rerun in the subsequent cycle.
##
## The test wires ``--max-cycles=N`` so the watch loop terminates
## deterministically after a known number of build cycles.
##
## Platform gate: the watch backend in
## ``libs/repro_cli_support/src/repro_cli_support/watch.nim`` has a
## kqueue impl for macOS, an inotify impl for Linux, and a
## ReadDirectoryChangesW impl for Windows. The M3 surface itself is
## platform-independent (it lifts the M2 resolver into a shared helper
## and feeds it into both ``runBuildCommand`` and ``runWatchCommand``),
## so the test runs anywhere the watcher has a real backend. Windows
## CI shells around ``sh -c`` differ enough from POSIX that we gate
## those out the same way the existing M31 test does.

when defined(macosx) or defined(linux):
  import std/[os, osproc, strutils, tempfiles, unittest]

  import repro_test_support

  proc pathExists(path: string): bool =
    try:
      discard getFileInfo(path, followSymlink = false)
      true
    except OSError:
      false

  proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
      socket: string] =
    let runquotaRoot = repoRoot.parentDir / "runquota"
    let daemonBin = runquotaRoot / "build" / "bin" /
      addFileExt("runquotad", ExeExt)
    if not fileExists(daemonBin):
      raise newException(OSError,
        "runquotad binary missing at " & daemonBin)
    let socketPath = "/tmp/repro-m3-multi-rq-" & $getCurrentProcessId() & ".sock"
    if fileExists(socketPath):
      removeFile(socketPath)
    let daemon = startProcess(daemonBin, args = [
      "--socket", socketPath,
      "--cpu-milli", "16000",
      "--memory-bytes", "17179869184"
    ], options = {poUsePath})
    putEnv("RUNQUOTA_SOCKET", socketPath)
    for _ in 0 ..< 200:
      if pathExists(socketPath):
        return (process: daemon, socket: socketPath)
      sleep(25)
    daemon.terminate()
    raise newException(OSError, "runquotad socket did not appear")

  proc writeExecutable(path, content: string) =
    createDir(path.splitPath.head)
    writeFile(path, content)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

  proc writeM3Tool(binDir: string) =
    ## A tool that copies an input + a shared file into the output and
    ## stamps a marker. Each target binds its own ``input`` and its own
    ## ``marker`` so the test can prove from marker line-counts which
    ## edges fired on each cycle.
    writeExecutable(binDir / "m3-tool",
      "#!/bin/sh\n" &
      "set -eu\n" &
      "if [ \"${1:-}\" = \"--version\" ]; then echo 'm3-tool 1.0.0'; exit 0; fi\n" &
      "input= shared= output= marker=\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    --input) input=$2; shift 2 ;;\n" &
      "    --shared) shared=$2; shift 2 ;;\n" &
      "    --output) output=$2; shift 2 ;;\n" &
      "    --marker) marker=$2; shift 2 ;;\n" &
      "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
      "  esac\n" &
      "done\n" &
      "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
      "cat \"$input\" \"$shared\" > \"$output\"\n" &
      "printf '%s\\n' \"$output\" >> \"$marker\"\n")

  proc writeMultiTargetProject(path: string) =
    ## Two independent edges, ``build/alpha`` and ``build/beta``. Each
    ## edge has its own dedicated source file (``src/alpha.txt`` /
    ## ``src/beta.txt``) plus a shared file (``src/shared.txt``) so the
    ## test can distinguish:
    ##   - editing ``src/alpha.txt`` → only ``alpha`` rebuilds;
    ##   - editing ``src/shared.txt`` → both ``alpha`` and ``beta``
    ##     rebuild.
    ## A third anonymous edge ``gamma`` is NOT selected on the CLI so
    ## the test can also assert the union didn't accidentally collapse
    ## to "build everything".
    let projectRoot = path.splitPath.head
    createDir(projectRoot / "reprobuild" / "packages")
    writeFile(projectRoot / "reprobuild" / "packages" / "m3_tool.nim",
      "import repro_project_dsl\n\n" &
      "defineCliInterface m3Tool, \"m3-tool\":\n" &
      "  call:\n" &
      "    flag input is string, alias = \"--input\", role = input, required = true\n" &
      "    flag shared is string, alias = \"--shared\", role = input, required = true\n" &
      "    flag output is string, alias = \"--output\", role = output, required = true\n" &
      "    flag marker is string, alias = \"--marker\", required = true\n" &
      "    outputs output\n")
    writeFile(path,
      "import repro_project_dsl\n\n" &
      "package m3MultiPkg:\n" &
      "  usesImportPath \"reprobuild/packages\"\n" &
      "  uses:\n" &
      "    \"m3-tool >=1.0 <2.0\"\n\n" &
      "  build:\n" &
      "    let markerAlpha = \".repro/m3-runs-alpha.log\"\n" &
      "    let markerBeta = \".repro/m3-runs-beta.log\"\n" &
      "    let markerGamma = \".repro/m3-runs-gamma.log\"\n" &
      "    m3Tool(actionId = \"build-alpha\",\n" &
      "      input = \"src/alpha.txt\",\n" &
      "      shared = \"src/shared.txt\",\n" &
      "      output = \"build/alpha\",\n" &
      "      marker = markerAlpha)\n" &
      "    m3Tool(actionId = \"build-beta\",\n" &
      "      input = \"src/beta.txt\",\n" &
      "      shared = \"src/shared.txt\",\n" &
      "      output = \"build/beta\",\n" &
      "      marker = markerBeta)\n" &
      "    m3Tool(actionId = \"build-gamma\",\n" &
      "      input = \"src/gamma.txt\",\n" &
      "      shared = \"src/shared.txt\",\n" &
      "      output = \"build/gamma\",\n" &
      "      marker = markerGamma)\n")

  proc countOccurrences(text, needle: string): int =
    if needle.len == 0:
      return 0
    var pos = 0
    while true:
      let idx = text.find(needle, pos)
      if idx < 0: break
      inc result
      pos = idx + needle.len

  proc nonEmptyLines(path: string): seq[string] =
    if not fileExists(path):
      return @[]
    for line in readFile(path).splitLines:
      let stripped = line.strip()
      if stripped.len > 0:
        result.add(stripped)

  proc q(value: string): string = quoteShell(value)

  proc shellJoin(args: openArray[string]): string =
    var parts: seq[string] = @[]
    for a in args: parts.add(q(a))
    parts.join(" ")

  proc runWatchMulti(reproBin, projectRoot, pathValue, logPath: string;
                     selectors: openArray[string];
                     maxCycles: int;
                     editAction: string): tuple[code: int; log: string] =
    ## Spawn ``repro watch <selectors...> --max-cycles=N`` in the
    ## background, wait for the first ``watching paths=`` line, then run
    ## ``editAction`` (a shell snippet that touches one or more source
    ## files). The watch loop terminates by itself once ``maxCycles`` is
    ## reached.
    var cliArgs = @[reproBin, "watch"]
    for s in selectors: cliArgs.add(s)
    cliArgs.add("--tool-provisioning=path")
    cliArgs.add("--daemon=off")
    cliArgs.add("--max-cycles=" & $maxCycles)
    cliArgs.add("--debounce-ms=50")
    let script =
      "set -eu\n" &
      "export PATH=" & q(pathValue) & "\n" &
      shellJoin(cliArgs) & " > " & q(logPath) & " 2>&1 &\n" &
      "pid=$!\n" &
      "ready=0\n" &
      # Readiness = the first ``watching paths=`` line, which the watch loop
      # emits only AFTER cycle 1's initial build completes and the filesystem
      # watcher is armed (see runWatchTarget in repro_cli_support: build →
      # openFilesystemWatcher → emit "watching paths="). The edit below must
      # not fire before that, or its event races an unarmed watcher. The
      # initial build includes a (possibly cold) provider compile; on a
      # heavily-shared runner that can take minutes, so the readiness window
      # must be generous. 12000 * 0.05s = 600 s — large enough to ride out
      # contention, while a watch that never becomes ready (genuine failure)
      # still exits 124 and fails ``check phase*.code == 0``.
      "for i in $(seq 1 12000); do\n" &
      "  if grep -q 'repro watch: watching paths=' " & q(logPath) &
        "; then ready=1; break; fi\n" &
      "  if ! kill -0 \"$pid\" 2>/dev/null; then wait \"$pid\"; exit $?; fi\n" &
      "  sleep 0.05\n" &
      "done\n" &
      "if [ \"$ready\" != 1 ]; then\n" &
      "  echo 'watch did not become ready' >> " & q(logPath) & "\n" &
      "  kill \"$pid\" 2>/dev/null || true\n" &
      "  wait \"$pid\" || true\n" &
      "  exit 124\n" &
      "fi\n" &
      editAction & "\n" &
      "wait \"$pid\"\n"
    let res = execCmdEx("sh -c " & q(script), workingDir = projectRoot)
    let log =
      if fileExists(logPath): readFile(logPath)
      else: ""
    (code: res.exitCode, log: log)

  suite "t_e2e_repro_watch_multiple_named_targets":

    test "t_e2e_repro_watch_multiple_named_targets":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m3-watch-multi", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      # Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
      # (``reprobuild.apps.repro`` → ``build/bin/repro``, built by the apps
      # collection before tests run). Assert it exists instead of recompiling
      # ``apps/repro/repro.nim`` at test runtime.
      let reproBin = requireBinary(
        repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
        "reprobuild.apps.repro")

      let binDir = tempRoot / "bin"
      writeM3Tool(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src" / "alpha.txt", "alpha v1\n")
      writeFile(projectRoot / "src" / "beta.txt", "beta v1\n")
      writeFile(projectRoot / "src" / "gamma.txt", "gamma v1\n")
      writeFile(projectRoot / "src" / "shared.txt", "shared v1\n")
      writeMultiTargetProject(projectRoot / "reprobuild.nim")

      # ----------------------------------------------------------------
      # Phase 1: ``repro watch alpha beta --max-cycles=2``. After the
      # initial cycle, edit ``src/alpha.txt`` (owned only by alpha's
      # closure). The second cycle should re-run alpha and leave beta
      # cache-hit. Gamma is NEVER selected, so its marker must stay
      # empty across both phases.
      # ----------------------------------------------------------------
      let phase1Log = tempRoot / "phase1.log"
      let editAlpha =
        "printf '%s' 'alpha v2\\n' >> " & q(projectRoot / "src" / "alpha.txt")
      let phase1 = runWatchMulti(reproBin, projectRoot, pathValue, phase1Log,
        ["alpha", "beta"], maxCycles = 2, editAction = editAlpha)
      if phase1.code != 0:
        checkpoint(phase1.log)
      check phase1.code == 0

      # Two cycles ran, both in one engine pass per cycle.
      check countOccurrences(phase1.log, "repro watch: cycle 1 start initial") == 1
      check countOccurrences(phase1.log, "repro watch: cycle 2 start rebuild") == 1
      check phase1.log.contains("repro watch: max cycles reached")
      # Each cycle is one engine pass — single ``scheduler:`` line per
      # cycle (so 2 across the whole log).
      check countOccurrences(phase1.log, "scheduler: actions=") == 2

      # Alpha marker: cycle 1 ran it, cycle 2 ran it again (edit hit its
      # input). Beta marker: cycle 1 ran it, cycle 2 saw no change to
      # beta's inputs so the action was a cache hit (marker not bumped).
      # Gamma marker: never selected, must stay empty.
      let alphaLines = nonEmptyLines(projectRoot / ".repro" / "m3-runs-alpha.log")
      let betaLines = nonEmptyLines(projectRoot / ".repro" / "m3-runs-beta.log")
      let gammaLines = nonEmptyLines(projectRoot / ".repro" / "m3-runs-gamma.log")
      check alphaLines.len == 2
      check betaLines.len == 1
      check gammaLines.len == 0

      # ----------------------------------------------------------------
      # Phase 2: a fresh project copy, then ``repro watch alpha beta
      # --max-cycles=2`` and edit ``src/shared.txt`` (referenced by
      # BOTH alpha's and beta's closures). The second cycle should
      # re-run BOTH actions.
      # ----------------------------------------------------------------
      let project2 = tempRoot / "project2"
      createDir(project2 / "src")
      writeFile(project2 / "src" / "alpha.txt", "alpha v1\n")
      writeFile(project2 / "src" / "beta.txt", "beta v1\n")
      writeFile(project2 / "src" / "gamma.txt", "gamma v1\n")
      writeFile(project2 / "src" / "shared.txt", "shared v1\n")
      writeMultiTargetProject(project2 / "reprobuild.nim")

      let phase2Log = tempRoot / "phase2.log"
      let editShared =
        "printf '%s' 'shared v2\\n' >> " & q(project2 / "src" / "shared.txt")
      let phase2 = runWatchMulti(reproBin, project2, pathValue, phase2Log,
        ["alpha", "beta"], maxCycles = 2, editAction = editShared)
      if phase2.code != 0:
        checkpoint(phase2.log)
      check phase2.code == 0

      check countOccurrences(phase2.log, "repro watch: cycle 1 start initial") == 1
      check countOccurrences(phase2.log, "repro watch: cycle 2 start rebuild") == 1
      check phase2.log.contains("repro watch: max cycles reached")
      check countOccurrences(phase2.log, "scheduler: actions=") == 2

      # Both markers got 2 lines (cycle 1 initial + cycle 2 rebuild).
      let alpha2 = nonEmptyLines(project2 / ".repro" / "m3-runs-alpha.log")
      let beta2 = nonEmptyLines(project2 / ".repro" / "m3-runs-beta.log")
      let gamma2 = nonEmptyLines(project2 / ".repro" / "m3-runs-gamma.log")
      check alpha2.len == 2
      check beta2.len == 2
      check gamma2.len == 0

else:
  import std/unittest

  suite "t_e2e_repro_watch_multiple_named_targets":
    test "t_e2e_repro_watch_multiple_named_targets":
      echo "SKIP: repro watch multi-target E2E requires kqueue or inotify"
