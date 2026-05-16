import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc requireFailure(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  check res.code != 0
  res.output

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m19-rq-" & $getCurrentProcessId() & ".sock"
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

proc writeFixtureTools(binDir: string) =
  writeExecutable(binDir / "m19-producer",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm19-producer 1.0.0'; exit 0; fi\n" &
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
    "count=1\n" &
    "if [ -f \"$marker.producer\" ]; then count=$(( $(cat \"$marker.producer\") + 1 )); fi\n" &
    "echo \"$count\" > \"$marker.producer\"\n" &
    "printf 'producer\\nvisible=%s\\nhidden=%s\\nrun=%s\\n' \"$(cat \"$visible\")\" \"$(cat \"$hidden\")\" \"$count\" > \"$output\"\n" &
    "abs_visible=$(cd \"$(dirname \"$visible\")\" && pwd)/$(basename \"$visible\")\n" &
    "abs_hidden=$(cd \"$(dirname \"$hidden\")\" && pwd)/$(basename \"$hidden\")\n" &
    "abs_output=$(cd \"$(dirname \"$output\")\" && pwd)/$(basename \"$output\")\n" &
    "printf '%s: %s %s\\n' \"$abs_output\" \"$abs_visible\" \"$abs_hidden\" > \"$depfile\"\n" &
    "printf 'producer\\n' >> \"$marker\"\n")

  writeExecutable(binDir / "m19-consumer",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm19-consumer 1.0.0'; exit 0; fi\n" &
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
    "count=1\n" &
    "if [ -f \"$marker.consumer\" ]; then count=$(( $(cat \"$marker.consumer\") + 1 )); fi\n" &
    "echo \"$count\" > \"$marker.consumer\"\n" &
    "printf 'consumer\\nrun=%s\\n' \"$count\" > \"$output\"\n" &
    "cat \"$input\" >> \"$output\"\n" &
    "printf 'consumer\\n' >> \"$marker\"\n")

proc writeProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m19Project:\n" &
    "  uses:\n" &
    "    \"m19-producer >=1.0 <2.0\"\n" &
    "    \"m19-consumer >=1.0 <2.0\"\n\n" &
    "  executable producer:\n" &
    "    name \"m19-producer\"\n" &
    "    cli:\n" &
    "      subcmd \"produce\":\n" &
    "        flag visible, string, required = true\n" &
    "        flag hidden, string, required = true\n" &
    "        flag output, string, required = true\n" &
    "        flag depfile, string, required = true\n" &
    "        flag marker, string, required = true\n\n" &
    "  executable consumer:\n" &
    "    name \"m19-consumer\"\n" &
    "    cli:\n" &
    "      subcmd \"consume\":\n" &
    "        flag input, string, required = true\n" &
    "        flag output, string, required = true\n" &
    "        flag marker, string, required = true\n" &
    "    build:\n" &
    "      let marker = \".repro/tool-runs.log\"\n" &
    "      discard buildAction(\"produce\",\n" &
    "        m19Project.executable(\"m19-producer\").produce(\n" &
    "          visible = \"src/visible.txt\",\n" &
    "          hidden = \"src/hidden.txt\",\n" &
    "          output = \"build/generated.txt\",\n" &
    "          depfile = \"build/generated.d\",\n" &
    "          marker = marker),\n" &
    "        inputs = @[\"src/visible.txt\"],\n" &
    "        outputs = @[\"build/generated.txt\"],\n" &
    "        depfile = \"build/generated.d\")\n" &
    "      discard buildAction(\"consume\",\n" &
    "        m19Project.executable(\"m19-consumer\").consume(\n" &
    "          input = \"build/generated.txt\",\n" &
    "          output = \"dist/final.txt\",\n" &
    "          marker = marker),\n" &
    "        deps = @[\"produce\"],\n" &
    "        inputs = @[\"build/generated.txt\"],\n" &
    "        outputs = @[\"dist/final.txt\"])\n" &
    "      discard buildAction(\"unrelated\",\n" &
    "        m19Project.executable(\"m19-consumer\").consume(\n" &
    "          input = \"src/unrelated.txt\",\n" &
    "          output = \"dist/unrelated.txt\",\n" &
    "          marker = \".repro/tool-runs-unrelated.log\"),\n" &
    "        inputs = @[\"src/unrelated.txt\"],\n" &
    "        outputs = @[\"dist/unrelated.txt\"])\n")

proc writeMissingProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m19Missing:\n" &
    "  uses:\n" &
    "    \"m19-missing-tool >=1.0 <2.0\"\n\n" &
    "  executable missing:\n" &
    "    name \"m19-missing-tool\"\n" &
    "    cli:\n" &
    "      subcmd \"run\":\n" &
    "        flag marker, string, required = true\n" &
    "    build:\n" &
    "      discard buildAction(\"missing\",\n" &
    "        m19Missing.executable(\"m19-missing-tool\").run(\n" &
    "          marker = \".repro/missing-ran.log\"),\n" &
    "        outputs = @[\"missing.out\"])\n")

proc nonEmptyLines(path: string): seq[string] =
  if not fileExists(path):
    return @[]
  for line in readFile(path).splitLines:
    let stripped = line.strip()
    if stripped.len > 0:
      result.add(stripped)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc build(reproBin, target, repoRoot, pathValue: string): string =
  requireSuccess("PATH=" & q(pathValue) & " " &
    shellCommand([reproBin, "build", target, "--tool-provisioning=path"]),
    repoRoot)

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

suite "e2e_local_reprobuild_project_build":
  test "public CLI builds local DSL project through provider, scheduler, cache, and depfile evidence":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m19-local-project", "")
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
    writeFixtureTools(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "visible.txt", "visible v1\n")
    writeFile(projectRoot / "src" / "hidden.txt", "hidden v1\n")
    writeFile(projectRoot / "src" / "unrelated.txt", "unrelated v1\n")
    writeProject(projectRoot / "reprobuild.nim")
    let target = projectRoot
    let marker = projectRoot / ".repro" / "tool-runs.log"
    let unrelatedMarker = projectRoot / ".repro" / "tool-runs-unrelated.log"

    let first = build(reproBin, target, repoRoot, pathValue)
    check first.contains("providerCompile:")
    check first.contains("providerGraphSnapshot:")
    check first.contains("scheduler: actions=3")
    check first.contains("evidence=depfile:2")
    check nonEmptyLines(marker) == @["producer", "consumer"]
    check nonEmptyLines(unrelatedMarker) == @["consumer"]
    check fileExists(projectRoot / "build" / "generated.txt")
    check fileExists(projectRoot / "build" / "generated.d")
    check fileExists(projectRoot / "dist" / "final.txt")
    check fileExists(projectRoot / "dist" / "unrelated.txt")

    let identity = readPathOnlyBuildIdentity(valueAfter(first, "toolIdentity:"))
    check identity.profiles.len == 2
    check identity.profiles[0].installMethod == "path"
    check identity.profiles.allIt(it.adapterStrength == asWeak)
    check identity.profiles.anyIt(it.resolvedExecutablePath == binDir / "m19-producer")
    check identity.profiles.anyIt(it.resolvedExecutablePath == binDir / "m19-consumer")

    let snapshotPath = valueAfter(first, "providerGraphSnapshot:")
    let reportPath = valueAfter(first, "buildReport:")
    check fileExists(snapshotPath)
    check readFile(snapshotPath)[0 .. 3] == "RBPG"
    check fileExists(reportPath)
    let firstReport = parseFile(reportPath)
    check firstReport{"providerInvocations"}.getInt() >= 1
    check reportAction(firstReport, "produce"){"status"}.getStr() == "asSucceeded"
    check reportAction(firstReport, "consume"){"status"}.getStr() == "asSucceeded"
    check reportAction(firstReport, "produce"){"runQuotaBackend"}.getStr().len > 0
    check reportAction(firstReport, "produce"){"evidence"}{"depfileInputs"}.
      getElems().anyIt(it.getStr().endsWith("src/hidden.txt"))
    check fileExists(projectRoot / ".repro" / "build" / "reprobuild" /
      "build-engine-cache" / "action-cache" / "action-results.records")

    let markerAfterFirst = readFile(marker)
    let unrelatedMarkerAfterFirst = readFile(unrelatedMarker)
    let second = build(reproBin, target, repoRoot, pathValue)
    check readFile(marker) == markerAfterFirst
    check readFile(unrelatedMarker) == unrelatedMarkerAfterFirst
    check second.contains("action: produce status=asCacheHit launched=false")
    check second.contains("action: consume status=asCacheHit launched=false")
    check second.contains("action: unrelated status=asCacheHit launched=false")

    writeFile(projectRoot / "src" / "hidden.txt", "hidden v2\n")
    let hiddenChanged = build(reproBin, target, repoRoot, pathValue)
    check nonEmptyLines(marker) == @["producer", "consumer", "producer",
      "consumer"]
    check readFile(unrelatedMarker) == unrelatedMarkerAfterFirst
    check hiddenChanged.contains("action: produce status=asSucceeded launched=true")
    check hiddenChanged.contains("action: consume status=asSucceeded launched=true")
    check hiddenChanged.contains(
      "action: unrelated status=asCacheHit launched=false")
    check readFile(projectRoot / "dist" / "final.txt").contains("hidden=hidden v2")

    removeFile(projectRoot / "build" / "generated.txt")
    let upstreamOutputDeleted = build(reproBin, target, repoRoot, pathValue)
    check nonEmptyLines(marker) == @["producer", "consumer", "producer",
      "consumer", "producer", "consumer"]
    check readFile(unrelatedMarker) == unrelatedMarkerAfterFirst
    check upstreamOutputDeleted.contains(
      "action: produce status=asSucceeded launched=true")
    check upstreamOutputDeleted.contains(
      "action: consume status=asSucceeded launched=true")
    check upstreamOutputDeleted.contains(
      "action: unrelated status=asCacheHit launched=false")

    let noFlag = requireFailure(shellCommand([reproBin, "build", target]), repoRoot)
    check noFlag.contains("refusing implicit PATH fallback")

    let missingRoot = tempRoot / "missing-project"
    writeMissingProject(missingRoot / "reprobuild.nim")
    let missing = requireFailure("PATH=" & q(pathValue) & " " &
      shellCommand([reproBin, "build", missingRoot, "--tool-provisioning=path"]),
      repoRoot)
    check missing.contains("tool-resolution failed")
    check missing.contains("m19-missing-tool")
    check not fileExists(missingRoot / ".repro" / "missing-ran.log")
