## Named-Targets M2 verification: ``repro build name1 name2 name3``
## against a fixture project with three independent targets. Asserts
## all three closures build in ONE engine pass (single ``scheduler:``
## line) and the build report enumerates each target.

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
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  if not fileExists(daemonBin):
    raise newException(OSError,
      "runquotad binary missing at " & daemonBin)
  let socketPath = "/tmp/repro-m2-multi-rq-" & $getCurrentProcessId() & ".sock"
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

proc writeM2Tool(binDir: string) =
  writeExecutable(binDir / "m2-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm2-tool 1.0.0'; exit 0; fi\n" &
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
    "printf '%s\\n' \"$output\" >> \"$marker\"\n")

proc writeMultiTargetProject(path: string) =
  ## Three independent edges produce ``build/alpha``, ``build/beta``,
  ## ``build/gamma`` plus a fourth ``build/delta`` we do NOT select on
  ## the CLI. The M2 resolver must build the first three (and only
  ## those) in a single engine pass.
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m2_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface m2Tool, \"m2-tool\":\n" &
    "  call:\n" &
    "    flag input is string, alias = \"--input\", role = input, required = true\n" &
    "    flag output is string, alias = \"--output\", role = output, required = true\n" &
    "    flag marker is string, alias = \"--marker\", required = true\n" &
    "    outputs output\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m2MultiPkg:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m2-tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let marker = \".repro/m2-runs.log\"\n" &
    "    m2Tool(actionId = \"build-alpha\",\n" &
    "      input = \"src/alpha.txt\",\n" &
    "      output = \"build/alpha\",\n" &
    "      marker = marker)\n" &
    "    m2Tool(actionId = \"build-beta\",\n" &
    "      input = \"src/beta.txt\",\n" &
    "      output = \"build/beta\",\n" &
    "      marker = marker)\n" &
    "    m2Tool(actionId = \"build-gamma\",\n" &
    "      input = \"src/gamma.txt\",\n" &
    "      output = \"build/gamma\",\n" &
    "      marker = marker)\n" &
    "    m2Tool(actionId = \"build-delta\",\n" &
    "      input = \"src/delta.txt\",\n" &
    "      output = \"build/delta\",\n" &
    "      marker = marker)\n")

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc countOccurrences(text, needle: string): int =
  if needle.len == 0:
    return 0
  var pos = 0
  while true:
    let idx = text.find(needle, pos)
    if idx < 0: break
    inc result
    pos = idx + needle.len

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

suite "t_e2e_repro_build_multiple_named_targets":

  test "t_e2e_repro_build_multiple_named_targets":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m2-multi-targets", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = tempRoot / "repro"
    discard requireSuccess(shellCommand([
      "nim", "c", "--verbosity:0", "--hints:off",
      "--nimcache:" & (tempRoot / "nimcache-repro"),
      "--out:" & reproBin,
      repoRoot / "apps" / "repro" / "repro.nim"
    ]), repoRoot)

    let binDir = tempRoot / "bin"
    writeM2Tool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "alpha.txt", "alpha v1\n")
    writeFile(projectRoot / "src" / "beta.txt", "beta v1\n")
    writeFile(projectRoot / "src" / "gamma.txt", "gamma v1\n")
    writeFile(projectRoot / "src" / "delta.txt", "delta v1\n")
    writeMultiTargetProject(projectRoot / "reprobuild.nim")

    # Invoke ``repro build alpha beta gamma`` from inside the project
    # directory. The M2 resolver must take the union of their dependency
    # closures and execute them in a single ``runBuildCommand`` pass.
    #
    # Pin ``--daemon=off`` so the test exercises the build engine in
    # direct mode without coupling to whichever user-daemon happens to
    # be running on the host. The default ``--daemon=auto`` either
    # reuses a pre-existing ``repro-daemon`` (whose forwarded env may
    # carry stale PATH entries from a previous unrelated test) or
    # launches a new daemon that subsequent tests inherit. Either
    # coupling produces hangs / spurious cache misses that are not
    # bugs in the Named-Targets M2 resolver this test guards. Mirrors
    # the pin applied in ``t_e2e_repro_build_named_target.nim``
    # (commit 30a7ce6) and ``t_e2e_m51_dsl_stdlib_file_ops.nim``
    # (commit 091cba4).
    let output = requireSuccess(shellCommand([
      reproBin, "build", "alpha", "beta", "gamma",
      "--daemon=off",
      "--tool-provisioning=path", "--log=actions"
    ], [("PATH", pathValue)]), projectRoot)

    # Single engine pass: exactly one ``scheduler:`` line is emitted by
    # ``executeBuildTarget`` per invocation.
    check countOccurrences(output, "scheduler: actions=") == 1
    # All three selected closures land — and the fourth (delta) does
    # NOT, proving the union didn't accidentally collapse to "build
    # everything".
    check output.contains(
      "action: build-alpha status=asSucceeded launched=true")
    check output.contains(
      "action: build-beta status=asSucceeded launched=true")
    check output.contains(
      "action: build-gamma status=asSucceeded launched=true")
    check not output.contains("action: build-delta")

    # Output artifacts exist:
    check fileExists(projectRoot / "build" / "alpha")
    check fileExists(projectRoot / "build" / "beta")
    check fileExists(projectRoot / "build" / "gamma")
    check not fileExists(projectRoot / "build" / "delta")

    # Build report enumerates each selected target.
    let reportPath = valueAfter(output, "buildReport:")
    check reportPath.len > 0
    let report = parseFile(reportPath)
    check report{"actions"}.len == 3
    check reportAction(report, "build-alpha"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(report, "build-beta"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(report, "build-gamma"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(report, "build-delta").kind == JNull
