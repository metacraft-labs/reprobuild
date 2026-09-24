## `repro watch` arms its filesystem watcher over the inputs the last build
## OBSERVED — and on a warm tree those inputs exist only because the engine
## reconstructed them from the action-cache record.
##
## THE REGRESSION THIS EXISTS TO CATCH HAS ALREADY SHIPPED ONCE, and
## `BuildCommandOutcome.inputEvidencePaths` carries the note: when the
## watched set was derived from the persisted build report, a `repro watch`
## without `--write-report` armed on the project file and its parent only.
## inotify and kqueue directory watches are not recursive, so an edit under
## `src/` produced no event and the loop blocked forever. A watcher armed on
## an empty set does not look broken. It prints a line, it waits, and it
## never says why nothing happened.
##
## `BuildEngineConfig.elideCacheHitEvidencePaths` re-opens exactly that
## hazard from the other end. It lets a run declare that no consumer wants
## the cache-hit evidence's path STRINGS — which is true of `repro build`,
## and catastrophically false of `repro watch`. So this file grades the
## wiring end to end, through the real CLI, with no in-process seam:
##
##   PHASE 1 — the watch loop. The cache is WARMED FIRST, by a plain
##   `repro build`, so the watch's own cycle 1 is an all-cache-hit no-op.
##   That is the load-bearing difference from every other watch e2e in this
##   directory: their cycle 1 is a cold build whose evidence is collected
##   live from the monitor and is never elided, so they would stay green
##   against a watcher that had gone blind on warm trees — which is the
##   only kind of tree a developer runs `repro watch` on twice. Cycle 1
##   here reconstructs its evidence from records, the watcher is armed from
##   that reconstruction, and an edit to a source file must still produce
##   cycle 2.
##
##   PHASE 2 — `--write-report`. The report's `actions[].evidence` is the
##   other reader of the same strings, and it is also asked for on a WARM
##   tree so the arrays it emits come from the reconstruction rather than
##   from a live capture.
##
## BOUNDED FAILURE, ON PURPOSE. The natural failure of phase 1 is a watch
## loop that blocks forever, which a CI runner reports as a job timeout with
## no attribution. So the script bounds the post-edit wait itself and the
## readiness line's `watching paths=<n>` count is asserted directly: a
## watcher that armed on the project file alone fails on the NUMBER, in
## seconds, and names what it saw.
##
## MOCK POLICY — NO MOCKS. A real `repro` binary, a real project file, a
## real tool on PATH, a real runquotad, the real action cache, the real
## kqueue/inotify watcher. Nothing here is stubbed.

when defined(macosx) or defined(linux):
  import std/[json, os, osproc, strutils, tempfiles, unittest]

  import repro_test_support

  proc pathExists(path: string): bool =
    try:
      discard getFileInfo(path, followSymlink = false)
      true
    except OSError:
      false

  proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
      socket: string] =
    let daemonBin = requireRunQuotaDaemonBin(repoRoot)
    let socketPath = runquotaSocketEndpoint(
      "repro-watch-evidence-rq-" & $getCurrentProcessId())
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

  proc writeTool(binDir: string) =
    writeExecutable(binDir / "evidence-tool",
      "#!/bin/sh\n" &
      "set -eu\n" &
      "if [ \"${1:-}\" = \"--version\" ]; then echo 'evidence-tool 1.0.0'; exit 0; fi\n" &
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

  proc writeProject(path: string) =
    let projectRoot = path.splitPath.head
    createDir(projectRoot / "reprobuild" / "packages")
    writeFile(projectRoot / "reprobuild" / "packages" / "evidence_tool.nim",
      "import repro_project_dsl\n\n" &
      "defineCliInterface evidenceTool, \"evidence-tool\":\n" &
      "  call:\n" &
      "    flag input is string, alias = \"--input\", role = input, required = true\n" &
      "    flag shared is string, alias = \"--shared\", role = input, required = true\n" &
      "    flag output is string, alias = \"--output\", role = output, required = true\n" &
      "    flag marker is string, alias = \"--marker\", required = true\n" &
      "    outputs output\n")
    writeFile(path,
      "import repro_project_dsl\n\n" &
      "package watchEvidencePkg:\n" &
      "  usesImportPath \"reprobuild/packages\"\n" &
      "  uses:\n" &
      "    \"evidence-tool >=1.0 <2.0\"\n\n" &
      "  build:\n" &
      "    evidenceTool(actionId = \"build-alpha\",\n" &
      "      input = \"src/alpha.txt\",\n" &
      "      shared = \"src/shared.txt\",\n" &
      "      output = \"build/alpha\",\n" &
      "      marker = \".repro/evidence-runs-alpha.log\")\n")

  proc q(value: string): string = quoteShell(value)

  proc shellJoin(args: openArray[string]): string =
    var parts: seq[string] = @[]
    for a in args: parts.add(q(a))
    parts.join(" ")

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

  proc watchedPathCounts(log: string): seq[int] =
    ## Every ``repro watch: watching paths=<n>`` count the loop reported,
    ## in order. This is the number that collapses when the watcher is
    ## armed on an empty evidence set.
    const Prefix = "repro watch: watching paths="
    for line in log.splitLines:
      let stripped = line.strip()
      if stripped.startsWith(Prefix):
        let digits = stripped[Prefix.len .. ^1].strip()
        try:
          result.add(parseInt(digits))
        except ValueError:
          discard

  proc runBuildOnce(reproBin, projectRoot, pathValue: string;
                    extraArgs: openArray[string] = []):
      tuple[code: int; output: string] =
    var args = @[reproBin, "build", "--tool-provisioning=path",
      "--daemon=off"]
    for a in extraArgs: args.add(a)
    let script =
      "set -eu\n" &
      "export PATH=" & q(pathValue) & "\n" &
      shellJoin(args) & "\n"
    let res = execCmdEx("sh -c " & q(script), workingDir = projectRoot)
    (code: res.exitCode, output: res.output)

  proc runWatchAndEdit(reproBin, projectRoot, pathValue, logPath: string;
                       editAction: string): tuple[code: int; log: string] =
    ## ``repro watch --max-cycles=2``, edit after the watcher is armed, and
    ## a BOUNDED wait for the loop to finish. The bound is the whole point:
    ## the failure this test exists to catch is a watcher that sees nothing,
    ## and its natural expression is a process that never returns.
    let cliArgs = @[reproBin, "watch", "--tool-provisioning=path",
      "--daemon=off", "--max-cycles=2", "--debounce-ms=50"]
    let script =
      "set -eu\n" &
      "export PATH=" & q(pathValue) & "\n" &
      shellJoin(cliArgs) & " > " & q(logPath) & " 2>&1 &\n" &
      "pid=$!\n" &
      "ready=0\n" &
      # Readiness = the first ``watching paths=`` line, emitted only after
      # cycle 1's build completes and the watcher is armed. The window is
      # generous because cycle 1 may still pay for a provider compile on a
      # contended runner; a watch that never becomes ready still exits 124.
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
      # Bounded post-edit wait. A watcher that saw the edit finishes cycle 2
      # and exits on ``max cycles reached``; a BLIND one sits here forever,
      # so 240 s of polling converts that into an attributable failure with
      # the log attached instead of a job timeout.
      "for i in $(seq 1 4800); do\n" &
      "  if ! kill -0 \"$pid\" 2>/dev/null; then wait \"$pid\"; exit $?; fi\n" &
      "  sleep 0.05\n" &
      "done\n" &
      "echo 'watch did not rebuild after the edit' >> " & q(logPath) & "\n" &
      "kill \"$pid\" 2>/dev/null || true\n" &
      "wait \"$pid\" || true\n" &
      "exit 125\n"
    let res = execCmdEx("sh -c " & q(script), workingDir = projectRoot)
    let log =
      if fileExists(logPath): readFile(logPath)
      else: ""
    (code: res.exitCode, log: log)

  suite "t_e2e_repro_watch_arms_on_cache_hit_evidence":

    test "t_e2e_repro_watch_arms_on_cache_hit_evidence":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-watch-evidence", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = requireBinary(
        repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
        "reprobuild.apps.repro")

      let binDir = tempRoot / "bin"
      writeTool(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")

      # ----------------------------------------------------------------
      # Phase 1: warm the cache, then watch.
      # ----------------------------------------------------------------
      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src" / "alpha.txt", "alpha v1\n")
      writeFile(projectRoot / "src" / "shared.txt", "shared v1\n")
      writeProject(projectRoot / "reprobuild.nim")

      # THE WARM-UP IS THE TEST SETUP, not a convenience. It makes the
      # watch loop's cycle 1 an all-cache-hit no-op, so every path the
      # watcher arms on has to come out of `evidenceFromRecord` rather
      # than out of a live monitor capture.
      let warm = runBuildOnce(reproBin, projectRoot, pathValue)
      if warm.code != 0:
        checkpoint(warm.output)
      require warm.code == 0
      # One execution so far: the marker has exactly one line.
      require nonEmptyLines(
        projectRoot / ".repro" / "evidence-runs-alpha.log").len == 1

      let watchLog = tempRoot / "watch.log"
      let editAlpha =
        "printf '%s' 'alpha v2\\n' >> " & q(projectRoot / "src" / "alpha.txt")
      let watched = runWatchAndEdit(reproBin, projectRoot, pathValue,
        watchLog, editAlpha)
      if watched.code != 0:
        checkpoint(watched.log)
      check watched.code == 0

      # The count the regression collapses. Without the evidence paths the
      # watched set is the project file (and, when it does not exist, its
      # parent) — one or two entries. `src/alpha.txt` and `src/shared.txt`
      # are DECLARED inputs of the only edge and reach the watcher solely
      # through `BuildCommandOutcome.inputEvidencePaths`.
      let counts = watchedPathCounts(watched.log)
      checkpoint("watched path counts: " & $counts)
      require counts.len >= 1
      check counts[0] >= 3

      # …and the behavioural half: the edit really produced a rebuild.
      check countOccurrences(watched.log,
        "repro watch: cycle 1 start initial") == 1
      check countOccurrences(watched.log,
        "repro watch: cycle 2 start rebuild") == 1
      check watched.log.contains("repro watch: max cycles reached")
      let alphaLines = nonEmptyLines(
        projectRoot / ".repro" / "evidence-runs-alpha.log")
      checkpoint("alpha marker lines: " & $alphaLines)
      check alphaLines.len == 2

      # ----------------------------------------------------------------
      # Phase 2: --write-report on a WARM tree still carries evidence
      # paths for the cache-hit actions.
      # ----------------------------------------------------------------
      let project2 = tempRoot / "project2"
      createDir(project2 / "src")
      writeFile(project2 / "src" / "alpha.txt", "alpha v1\n")
      writeFile(project2 / "src" / "shared.txt", "shared v1\n")
      writeProject(project2 / "reprobuild.nim")

      let cold = runBuildOnce(reproBin, project2, pathValue)
      if cold.code != 0:
        checkpoint(cold.output)
      require cold.code == 0

      let reportPath = tempRoot / "warm-report.json"
      let reported = runBuildOnce(reproBin, project2, pathValue,
        ["--write-report=" & reportPath])
      if reported.code != 0:
        checkpoint(reported.output)
      require reported.code == 0
      require fileExists(reportPath)

      let report = parseFile(reportPath)
      var sawAction = false
      var sawCacheHit = false
      var declaredInputs: seq[string] = @[]
      for item in report{"actions"}:
        if item{"id"}.getStr() != "build-alpha":
          continue
        sawAction = true
        sawCacheHit = item{"cacheDecision"}.getStr() == "cdHit"
        for entry in item{"evidence"}{"declaredInputs"}:
          declaredInputs.add(entry.getStr())
      checkpoint("report declaredInputs: " & $declaredInputs)
      check sawAction
      # The action must really have been a cache HIT, or the evidence in
      # this document came from a live capture and says nothing about the
      # reconstruction this test is about.
      check sawCacheHit
      # Matched by SUFFIX: the DSL resolves declared inputs to absolute
      # paths, and `evidenceFromRecord` copies `action.inputs` verbatim, so
      # what lands in the document is the action's own absolute spelling.
      # Asserted on the spelling that is really there rather than on a
      # normalised one, because a test that normalised both sides would
      # keep passing if the strings vanished and the normaliser returned
      # the empty match.
      check declaredInputs.len == 2
      var sawAlpha = false
      var sawShared = false
      for entry in declaredInputs:
        if entry.endsWith("src" / "alpha.txt"): sawAlpha = true
        if entry.endsWith("src" / "shared.txt"): sawShared = true
      check sawAlpha
      check sawShared

else:
  import std/unittest

  suite "t_e2e_repro_watch_arms_on_cache_hit_evidence":
    test "warm-tree watch E2E is not available on this platform":
      echo "[platform N/A] repro watch warm-evidence E2E requires kqueue or inotify"
      skip("platform N/A: repro watch warm-evidence E2E requires kqueue or " &
        "inotify")
