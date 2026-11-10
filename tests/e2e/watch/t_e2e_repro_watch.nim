import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

from repro_test_support import requireBinary, monitorShimPath,
  requireRunQuotaDaemonBin, runquotaSocketEndpoint

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

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
    "repro-m31-rq-" & $getCurrentProcessId())
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184",
    # Test daemon: keep it out of the host-wide observation store, which
    # it would otherwise open (and write) before it binds its socket.
    "--no-write-stats"
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

proc writeFixtureTools(binDir: string) =
  writeExecutable(binDir / "m31-producer",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm31-producer 1.0.0'; exit 0; fi\n" &
    "test \"${1:-}\" = produce\n" &
    "shift\n" &
    "visible= hidden= output= depfile= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --visible) visible=$2; shift 2 ;;\n" &
    "    --hidden) hidden=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --depfile) depfile=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$depfile\")\" \"$(dirname \"$marker\")\"\n" &
    "printf 'producer\\nvisible=%s\\nhidden=%s\\n' \"$(cat \"$visible\")\" \"$(cat \"$hidden\")\" > \"$output\"\n" &
    "abs_visible=$(cd \"$(dirname \"$visible\")\" && pwd)/$(basename \"$visible\")\n" &
    "abs_hidden=$(cd \"$(dirname \"$hidden\")\" && pwd)/$(basename \"$hidden\")\n" &
    "abs_output=$(cd \"$(dirname \"$output\")\" && pwd)/$(basename \"$output\")\n" &
    "printf '%s: %s %s\\n' \"$abs_output\" \"$abs_visible\" \"$abs_hidden\" > \"$depfile\"\n" &
    "printf 'producer\\n' >> \"$marker\"\n")

  writeExecutable(binDir / "m31-consumer",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm31-consumer 1.0.0'; exit 0; fi\n" &
    "test \"${1:-}\" = consume\n" &
    "shift\n" &
    "input= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "printf 'consumer\\n' > \"$output\"\n" &
    "cat \"$input\" >> \"$output\"\n" &
    "printf 'consumer\\n' >> \"$marker\"\n")

  writeExecutable(binDir / "m40-copy",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm40-copy 1.0.0'; exit 0; fi\n" &
    "test \"${1:-}\" = copy\n" &
    "shift\n" &
    "input= output= marker=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --input) input=$2; shift 2 ;;\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    --marker) marker=$2; shift 2 ;;\n" &
    "    *) echo \"unknown arg $1\" >&2; exit 64 ;;\n" &
    "  esac\n" &
    "done\n" &
    "mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "cp \"$input\" \"$output\"\n" &
    "printf 'copy:%s\\n' \"$output\" >> \"$marker\"\n")

proc writeProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m31Project:\n" &
    "  uses:\n" &
    "    \"m31-producer >=1.0 <2.0\"\n" &
    "    \"m31-consumer >=1.0 <2.0\"\n\n" &
    "  executable producer:\n" &
    "    name \"m31-producer\"\n" &
    "    cli:\n" &
    "      subcmd \"produce\":\n" &
    "        flag visible, string, required = true\n" &
    "        flag hidden, string, required = true\n" &
    "        flag output, string, required = true\n" &
    "        flag depfile, string, required = true\n" &
    "        flag marker, string, required = true\n\n" &
    "  executable consumer:\n" &
    "    name \"m31-consumer\"\n" &
    "    cli:\n" &
    "      subcmd \"consume\":\n" &
    "        flag input, string, required = true\n" &
    "        flag output, string, required = true\n" &
    "        flag marker, string, required = true\n" &
    "    build:\n" &
    "      let marker = \".repro/tool-runs.log\"\n" &
    "      discard buildAction(\"produce\",\n" &
    "        m31Project.executable(\"m31-producer\").produce(\n" &
    "          visible = \"src/visible.txt\",\n" &
    "          hidden = \"src/hidden.txt\",\n" &
    "          output = \"build/generated.txt\",\n" &
    "          depfile = \"build/generated.d\",\n" &
    "          marker = marker),\n" &
    "        inputs = @[\"src/visible.txt\"],\n" &
    "        outputs = @[\"build/generated.txt\"],\n" &
    "        depfile = \"build/generated.d\")\n" &
    "      discard buildAction(\"consume\",\n" &
    "        m31Project.executable(\"m31-consumer\").consume(\n" &
    "          input = \"build/generated.txt\",\n" &
    "          output = \"dist/final.txt\",\n" &
    "          marker = marker),\n" &
    "        deps = @[\"produce\"],\n" &
    "        inputs = @[\"build/generated.txt\"],\n" &
    "        outputs = @[\"dist/final.txt\"])\n" &
    "      discard buildAction(\"unrelated\",\n" &
    "        m31Project.executable(\"m31-consumer\").consume(\n" &
    "          input = \"src/unrelated.txt\",\n" &
    "          output = \"dist/unrelated.txt\",\n" &
    "          marker = \".repro/tool-runs-unrelated.log\"),\n" &
    "        inputs = @[\"src/unrelated.txt\"],\n" &
    "        outputs = @[\"dist/unrelated.txt\"])\n" &
    "      defaultBuildAction(\"consume\")\n")

proc writeDirectoryEnumerationProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import std/[algorithm, os]\n" &
    "import repro_project_dsl\n\n" &
    "package m40WatchProject:\n" &
    "  uses:\n" &
    "    \"m40-copy >=1.0 <2.0\"\n\n" &
    "  executable copier:\n" &
    "    name \"m40-copy\"\n" &
    "    cli:\n" &
    "      subcmd \"copy\":\n" &
    "        flag input, string, required = true\n" &
    "        flag output, string, required = true\n" &
    "        flag marker, string, required = true\n" &
    "    build:\n" &
    "      providerDirectoryInput(\"src/resources\")\n" &
    "      var sourceFiles: seq[string] = @[]\n" &
    "      for sourcePath in walkFiles(\"src/resources/*\"):\n" &
    "        sourceFiles.add(sourcePath)\n" &
    "      sourceFiles.sort()\n" &
    "      var copyDeps: seq[string] = @[]\n" &
    "      let marker = \".repro/m40-watch-tool-runs.log\"\n" &
    "      for sourcePath in sourceFiles:\n" &
    "        let name = splitPath(sourcePath).tail\n" &
    "        let actionId = \"copy-\" & name\n" &
    "        let output = \"dist/\" & name & \".out\"\n" &
    "        copyDeps.add(actionId)\n" &
    "        discard buildAction(actionId,\n" &
    "          m40WatchProject.copy(input = sourcePath, output = output,\n" &
    "            marker = marker),\n" &
    "          inputs = @[sourcePath],\n" &
    "          outputs = @[output])\n" &
    "      discard buildAction(\"aggregate\",\n" &
    "        m40WatchProject.copy(input = \"src/aggregate.txt\",\n" &
    "          output = \"dist/aggregate.stamp\", marker = marker),\n" &
    "        deps = copyDeps,\n" &
    "        inputs = @[\"src/aggregate.txt\"],\n" &
    "        outputs = @[\"dist/aggregate.stamp\"])\n")

proc nonEmptyLines(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let stripped = line.strip()
    if stripped.len > 0:
      result.add(stripped)

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

proc reportActionWithDeclaredOutput(report: JsonNode; output: string): JsonNode =
  for item in report{"actions"}:
    for declared in item{"evidence"}{"declaredOutputs"}.getElems():
      if declared.getStr() == output:
        return item
  newJNull()

proc assertAction(report: JsonNode; id, status: string; launched: bool) =
  let action = reportAction(report, id)
  check action.kind != JNull
  check action{"status"}.getStr() == status
  check action{"launched"}.getBool() == launched

proc assertOutputAction(report: JsonNode; output, status: string;
                        launched: bool) =
  let action = reportActionWithDeclaredOutput(report, output)
  check action.kind != JNull
  check action{"status"}.getStr() == status
  check action{"launched"}.getBool() == launched

const publicResourceAction = "frontend-public-resources"

proc assertPublicResourceActions(report: JsonNode; status: string;
                                 launched: bool) =
  assertAction(report, publicResourceAction, status, launched)

proc checkpointBuildReportFailures(projectRoot: string) =
  let reportPath = projectRoot / ".repro" / "build" / "reprobuild" /
    "build-report.json"
  if not fileExists(reportPath):
    return
  let report = parseFile(reportPath)
  for action in report{"actions"}:
    if action{"status"}.getStr() == "asFailed":
      checkpoint(action{"id"}.getStr() & " exit=" &
        $action{"exitCode"}.getInt() & "\nstderr:\n" &
        action{"stderr"}.getStr() & "\nstdout:\n" &
        action{"stdout"}.getStr())

proc reproGraphBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc compilePublicReproTestBin(repoRoot: string): string =
  reproGraphBinary(repoRoot)

proc runWatchAndEdit(reproBin, target, repoRoot, pathValue, logPath, editPath,
                     editText: string; debounceMs = 50;
                     env: openArray[(string, string)] = []): string =
  var envLines = "export PATH=" & q(pathValue) & "\n"
  let wrapperLogPath = logPath & ".nim-wrapper.log"
  envLines.add("export REPRO_WATCH_NIM_WRAPPER_LOG=" & q(wrapperLogPath) & "\n")
  for (name, value) in env:
    envLines.add("export " & name & "=" & q(value) & "\n")
  let script =
    "set -eu\n" &
    envLines &
    shellCommand([reproBin, "watch", target, "--tool-provisioning=path",
      "--max-cycles=2", "--debounce-ms=" & $debounceMs]) &
      " > " & q(logPath) & " 2>&1 &\n" &
    "pid=$!\n" &
    "ready=0\n" &
    "for i in $(seq 1 600); do\n" &
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
    "printf '%s' " & q(editText) & " >> " & q(editPath) & "\n" &
    "wait \"$pid\"\n"
  let res = runShell("sh -c " & q(script), repoRoot)
  let log =
    if fileExists(logPath):
      readFile(logPath)
    else:
      ""
  if res.code != 0:
    checkpoint(res.output)
    checkpoint(log)
    if fileExists(wrapperLogPath):
      checkpoint(readFile(wrapperLogPath))
    checkpointBuildReportFailures(target.split("#")[0])
  check res.code == 0
  log

proc runWatchCurrentProjectAndEdit(reproBin, projectRoot, pathValue, logPath,
                                   editPath, editText: string;
                                   debounceMs = 50;
                                   env: openArray[(string, string)] = []): string =
  var envLines = "export PATH=" & q(pathValue) & "\n"
  let wrapperLogPath = logPath & ".nim-wrapper.log"
  envLines.add("export REPRO_WATCH_NIM_WRAPPER_LOG=" & q(wrapperLogPath) & "\n")
  for (name, value) in env:
    envLines.add("export " & name & "=" & q(value) & "\n")
  let script =
    "set -eu\n" &
    envLines &
    shellCommand([reproBin, "watch", "--tool-provisioning=path",
      "--max-cycles=2", "--debounce-ms=" & $debounceMs]) &
      " > " & q(logPath) & " 2>&1 &\n" &
    "pid=$!\n" &
    "ready=0\n" &
    "for i in $(seq 1 600); do\n" &
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
    "printf '%s' " & q(editText) & " >> " & q(editPath) & "\n" &
    "wait \"$pid\"\n"
  let res = runShell("sh -c " & q(script), projectRoot)
  let log =
    if fileExists(logPath):
      readFile(logPath)
    else:
      ""
  if res.code != 0:
    checkpoint(res.output)
    checkpoint(log)
    if fileExists(wrapperLogPath):
      checkpoint(readFile(wrapperLogPath))
    checkpointBuildReportFailures(projectRoot)
  check res.code == 0
  log

when defined(macosx):
  suite "e2e_repro_watch":
    test "local project watch rebuilds selected target from depfile event":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m31-local-watch", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = compilePublicReproTestBin(repoRoot)
      let binDir = tempRoot / "bin"
      writeFixtureTools(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src" / "visible.txt", "visible v1\n")
      writeFile(projectRoot / "src" / "hidden.txt", "hidden v1\n")
      writeFile(projectRoot / "src" / "unrelated.txt", "unrelated v1\n")
      writeProject(projectRoot / "reprobuild.nim")

      let log = runWatchAndEdit(reproBin, projectRoot & "#consume", repoRoot,
        pathValue, tempRoot / "local-watch.log",
        projectRoot / "src" / "hidden.txt", "hidden v2\n")
      check log.contains("repro watch: cycle 1 start initial")
      check log.contains("repro watch: event seen path=")
      check log.contains("repro watch: cycle 2 start rebuild")
      check log.contains("repro watch: max cycles reached")
      check log.contains("selectedTarget: consume")
      check log.contains("scheduler: actions=2")
      check not log.contains("action: unrelated")
      check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
        @["producer", "consumer", "producer", "consumer"]
      check nonEmptyLines(projectRoot / ".repro" /
        "tool-runs-unrelated.log").len == 0

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      assertAction(report, "produce", "asSucceeded", true)
      assertAction(report, "consume", "asSucceeded", true)
      check reportAction(report, "unrelated").kind == JNull

    test "local project no-target watch uses current project default action":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m45-local-default-watch", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = compilePublicReproTestBin(repoRoot)
      let binDir = tempRoot / "bin"
      writeFixtureTools(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src")
      writeFile(projectRoot / "src" / "visible.txt", "visible v1\n")
      writeFile(projectRoot / "src" / "hidden.txt", "hidden v1\n")
      writeFile(projectRoot / "src" / "unrelated.txt", "unrelated v1\n")
      writeProject(projectRoot / "reprobuild.nim")

      let log = runWatchCurrentProjectAndEdit(reproBin, projectRoot, pathValue,
        tempRoot / "m45-local-default-watch.log",
        projectRoot / "src" / "hidden.txt", "hidden v2\n")
      check log.contains("repro watch: target=.")
      check log.contains("repro watch: cycle 1 start initial")
      check log.contains("repro watch: event seen path=")
      check log.contains("repro watch: cycle 2 start rebuild")
      check log.contains("repro watch: max cycles reached")
      check log.contains("defaultTarget: consume")
      check log.contains("selectedTarget: consume")
      check log.contains("scheduler: actions=2")
      check not log.contains("action: unrelated")
      check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
        @["producer", "consumer", "producer", "consumer"]
      check nonEmptyLines(projectRoot / ".repro" /
        "tool-runs-unrelated.log").len == 0

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      assertAction(report, "produce", "asSucceeded", true)
      assertAction(report, "consume", "asSucceeded", true)
      check reportAction(report, "unrelated").kind == JNull

    test "local project watch reruns provider root after enumerated directory add":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m40-directory-watch", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = compilePublicReproTestBin(repoRoot)
      let binDir = tempRoot / "bin"
      writeFixtureTools(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src" / "resources")
      writeFile(projectRoot / "src" / "aggregate.txt", "aggregate\n")
      writeFile(projectRoot / "src" / "resources" / "alpha.txt", "alpha\n")
      writeFile(projectRoot / "src" / "resources" / "beta.txt", "beta\n")
      writeDirectoryEnumerationProject(projectRoot / "reprobuild.nim")

      let selectedTarget = projectRoot & "#aggregate"
      let newInput = projectRoot / "src" / "resources" / "gamma.txt"
      let log = runWatchAndEdit(reproBin, selectedTarget, repoRoot, pathValue,
        tempRoot / "m40-directory-watch.log", newInput, "gamma\n")
      check log.contains("repro watch: target=" & selectedTarget)
      check log.contains("repro watch: event seen path=")
      check log.contains("repro watch: cycle 2 start rebuild")
      check log.contains("selectedTarget: aggregate")
      check log.contains("scheduler: actions=4")
      check log.contains("action: copy-gamma.txt status=asSucceeded launched=true")
      check fileExists(projectRoot / "dist" / "gamma.txt.out")
      check readFile(projectRoot / "dist" / "gamma.txt.out") == "gamma\n"

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      check report{"actions"}.len == 4
      assertAction(report, "copy-gamma.txt", "asSucceeded", true)
      check reportAction(report, "copy-alpha.txt").kind != JNull
      check reportAction(report, "copy-beta.txt").kind != JNull
      check reportAction(report, "aggregate").kind != JNull

else:
  suite "e2e_repro_watch":
    test "event-driven watch E2E is macOS kqueue-only in M31":
      echo "[platform N/A] repro watch filesystem E2E currently requires macOS kqueue"
      skip("platform N/A: repro watch filesystem E2E currently requires " &
        "macOS kqueue")
      # M31 confines the event-driven watch E2E to macOS kqueue, so on every
      # other host this arm has nothing to exercise. The marker declares that;
      # the `skip` makes the runner report it, so the whole suite is counted
      # as unrun on Linux instead of contributing a green case.
