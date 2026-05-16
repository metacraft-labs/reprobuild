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
  let socketPath = "/tmp/repro-m21-rq-" & $getCurrentProcessId() & ".sock"
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

proc nimString(value: string): string =
  value.escape()

proc copySelectedCodeTracerFiles(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "src" / "frontend" / "tests")
  createDir(projectRoot / "src" / "frontend" / "index")
  createDir(projectRoot / "src" / "frontend" / "lib")
  createDir(projectRoot / "src" / "c")
  copyFile(codeTracerRoot / "src" / "frontend" / "tests" /
    "ipc_registry_test.nim",
    projectRoot / "src" / "frontend" / "tests" / "ipc_registry_test.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "index" /
    "ipc_registry.nim",
    projectRoot / "src" / "frontend" / "index" / "ipc_registry.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "lib" / "jslib.nim",
    projectRoot / "src" / "frontend" / "lib" / "jslib.nim")
  copyFile(codeTracerRoot / "test-programs" / "c_sudoku_solver" / "main.c",
    projectRoot / "src" / "c" / "main.c")

proc writeProject(path: string) =
  createDir(path.splitPath.head)
  let recordScript =
    "set -eu\n" &
    "out=$1\n" &
    "mkdir -p \"$(dirname \"$out\")\"\n" &
    "test -f src/frontend/tests/ipc_registry_test.nim\n" &
    "test -f src/c/main.c\n" &
    "printf '%s\\n' \"$BASH\" > \"$out\"\n"
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package codeTracerDevSlice:\n" &
    "  uses:\n" &
    "    \"nim >=2.0\"\n" &
    "    \"node >=20\"\n" &
    "    \"gcc >=1\"\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      discard buildAction(\"record-nix-sh\",\n" &
    "        codeTracerDevSlice.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & nimString(recordScript) & ", " &
      nimString("sh") & ", " & nimString("build/nix-sh.txt") & "]),\n" &
    "        inputs = @[" &
      nimString("src/frontend/tests/ipc_registry_test.nim") & ", " &
      nimString("src/c/main.c") & "],\n" &
    "        outputs = @[" & nimString("build/nix-sh.txt") & "])\n")

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc assertNixIdentity(identity: PathOnlyBuildIdentity) =
  check identity.profiles.len == 4
  check identity.profiles.allIt(it.installMethod == "nix")
  check identity.profiles.allIt(it.adapterStrength == asStrong)
  check identity.profiles.allIt(it.cachePortability == cpPortable)
  for executableName in ["nim", "node", "gcc", "sh"]:
    check identity.profiles.anyIt(it.executableName == executableName)
  for profile in identity.profiles:
    check profile.nixSelector.startsWith("nixpkgs#")
    check profile.realizedStorePaths.len >= 1
    check profile.selectedStorePath.startsWith("/nix/store/")
    check profile.resolvedExecutablePath.startsWith("/nix/store/")
    check profile.resolvedExecutablePath.endsWith("/bin/" & profile.executableName)
    check profile.lockIdentity.len > 0
    check profile.realizationBoundary == profile.selectedStorePath
    check profile.probes.len == 1
    check profile.probes[0].exitCode == 0
    check profile.probes[0].output.strip().len > 0

suite "e2e_codetracer_dev_environment_slice":
  test "Nix-backed develop resolves typed CodeTracer tools and build uses the same profiles":
    let repoRoot = getCurrentDir()
    let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
    check fileExists(codeTracerRoot / "src" / "frontend" / "tests" /
      "ipc_registry_test.nim")
    check fileExists(codeTracerRoot / "test-programs" / "c_sudoku_solver" /
      "main.c")

    let tempRoot = createTempDir("repro-m21-codetracer-dev", "")
    defer: removeDir(tempRoot)

    let reproBin = tempRoot / "repro"
    discard requireSuccess(shellCommand([
      "nim", "c", "--verbosity:0", "--hints:off",
      "--nimcache:" & (tempRoot / "nimcache-repro"),
      "--out:" & reproBin,
      repoRoot / "apps" / "repro" / "repro.nim"
    ]), repoRoot)

    let projectRoot = tempRoot / "project"
    createDir(projectRoot)
    copySelectedCodeTracerFiles(codeTracerRoot, projectRoot)
    writeProject(projectRoot / "reprobuild.nim")
    let target = projectRoot

    let noFlag = requireFailure(shellCommand([reproBin, "develop", target]),
      repoRoot)
    check noFlag.contains("refusing implicit PATH fallback")

    let checks =
      "set -eu\n" &
      "test -f src/frontend/tests/ipc_registry_test.nim\n" &
      "test -f src/frontend/index/ipc_registry.nim\n" &
      "test -f src/frontend/lib/jslib.nim\n" &
      "test -f src/c/main.c\n" &
      "test -f \"$REPRO_TOOL_PROFILE_ARTIFACT\"\n" &
      "test -f \"$REPRO_TOOL_PROFILE_INSPECTION\"\n" &
      "test \"$REPRO_PROJECT_ROOT\" = \"$PWD\"\n" &
      "for tool in nim node gcc sh; do\n" &
      "  path=$(command -v \"$tool\")\n" &
      "  case \"$path\" in /nix/store/*/bin/$tool) ;; *) echo \"$tool=$path\"; exit 20;; esac\n" &
      "  \"$tool\" --version >/dev/null\n" &
      "  echo \"$tool=$path\"\n" &
      "done\n" &
      "echo M21_DEVELOP_OK\n"
    let develop = requireSuccess(shellCommand([reproBin, "develop", target,
      "--tool-provisioning=nix", "--", "sh", "-c", checks]), repoRoot)
    check develop.contains("M21_DEVELOP_OK")
    check develop.contains("tool-provisioning=nix")
    for executableName in ["nim", "node", "gcc", "sh"]:
      check develop.contains(executableName & "=/nix/store/")

    let developIdentityPath = valueAfter(develop, "toolIdentity:")
    let developInspectionPath = valueAfter(develop, "inspection:")
    check fileExists(developIdentityPath)
    check fileExists(developInspectionPath)
    check readFile(developIdentityPath)[0 .. 3] == "RBTP"
    check readFile(developIdentityPath)[0] != '{'
    let developIdentity = readPathOnlyBuildIdentity(developIdentityPath)
    assertNixIdentity(developIdentity)

    let inspection = parseFile(developInspectionPath)
    check inspection{"profiles"}.getElems().len == 4
    for profile in inspection{"profiles"}:
      check profile{"installMethod"}.getStr() == "nix"
      check profile{"adapterStrength"}.getStr() == "strong"
      check profile{"cachePortability"}.getStr() == "portable"
      check profile{"resolvedExecutablePath"}.getStr().startsWith("/nix/store/")
      check profile{"probes"}[0]{"output"}.getStr().strip().len > 0

    let summary = requireSuccess(shellCommand([reproBin, "develop", target,
      "--tool-provisioning=nix"]), repoRoot)
    check summary.contains("tool: nim /nix/store/")
    check summary.contains("tool: node /nix/store/")
    check summary.contains("tool: gcc /nix/store/")
    check summary.contains("tool: sh /nix/store/")

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let build = requireSuccess(shellCommand([reproBin, "build", target,
      "--tool-provisioning=nix"]), repoRoot)
    check build.contains("tool-provisioning=nix")
    check build.contains("action: record-nix-sh status=asSucceeded launched=true")
    let buildIdentity = readPathOnlyBuildIdentity(valueAfter(build, "toolIdentity:"))
    assertNixIdentity(buildIdentity)
    check readFile(projectRoot / "build" / "nix-sh.txt").startsWith(
      "/nix/store/")
