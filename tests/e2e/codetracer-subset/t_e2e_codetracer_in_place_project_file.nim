import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles

const GccProxySource = r"""
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void read_for_monitor(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return;
  char buffer[4096];
  while (read(fd, buffer, sizeof(buffer)) > 0) {}
  close(fd);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("gcc proxy 1.0.0");
    return 0;
  }
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-include") == 0 && i + 1 < argc) {
      read_for_monitor(argv[i + 1]);
      i++;
    } else if (argv[i][0] != '-' && strstr(argv[i], ".c") != NULL) {
      read_for_monitor(argv[i]);
    }
  }
  unsetenv("DYLD_INSERT_LIBRARIES");
  setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
  char **next_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (next_argv == NULL) return 126;
  next_argv[0] = "/usr/bin/gcc";
  for (int i = 1; i < argc; i++) next_argv[i] = argv[i];
  execv("/usr/bin/gcc", next_argv);
  perror("execv /usr/bin/gcc");
  return 127;
}
"""

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

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string) =
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath,
    sourcePath
  ]), repoRoot)

when defined(macosx):
  proc compileShim(repoRoot, outputPath: string) =
    let arm64Path = outputPath & ".arm64"
    let arm64ePath = outputPath & ".arm64e"
    discard requireSuccess(shellCommand([
      "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
      "--path:/Users/zahary/metacraft/ct_interpose/src",
      "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-ct-shim",
      "--out:" & arm64Path,
      repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "macos_interpose.nim"
    ]), repoRoot)
    discard requireSuccess(shellCommand([
      "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
      "--passC:-arch arm64e", "--passL:-arch arm64e",
      "--path:/Users/zahary/metacraft/ct_interpose/src",
      "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-ct-shim-arm64e",
      "--out:" & arm64ePath,
      repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "macos_interpose.nim"
    ]), repoRoot)
    discard requireSuccess(shellCommand([
      "lipo", "-create", "-output", outputPath, arm64Path, arm64ePath
    ]), repoRoot)

  proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[fsSnoop: string;
      shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim = libDir / "librepro_monitor_shim.dylib"
    compileShim(repoRoot, result.shim)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m32-ct-repro-fs-snoop")

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m29-rq-" & $getCurrentProcessId() & ".sock"
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

proc copySelectedCodeTracerProject(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "src" / "frontend" / "tests")
  createDir(projectRoot / "src" / "frontend" / "index")
  createDir(projectRoot / "src" / "frontend" / "lib")
  createDir(projectRoot / "test-programs" / "c_sudoku_solver")
  copyFile(codeTracerRoot / "reprobuild.nim", projectRoot / "reprobuild.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "tests" /
    "ipc_registry_test.nim",
    projectRoot / "src" / "frontend" / "tests" / "ipc_registry_test.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "index" /
    "ipc_registry.nim",
    projectRoot / "src" / "frontend" / "index" / "ipc_registry.nim")
  copyFile(codeTracerRoot / "src" / "frontend" / "lib" / "jslib.nim",
    projectRoot / "src" / "frontend" / "lib" / "jslib.nim")
  copyFile(codeTracerRoot / "test-programs" / "c_sudoku_solver" / "main.c",
    projectRoot / "test-programs" / "c_sudoku_solver" / "main.c")
  discard requireSuccess(shellCommand([
    "ln", "-s", codeTracerRoot / "libs", projectRoot / "libs"
  ]))

proc codeTracerPathValue(tempRoot: string): string =
  let binDir = tempRoot / "codetracer-tool-bin"
  createDir(binDir)
  let sourcePath = binDir / "gcc-proxy.c"
  let gccPath = binDir / "gcc"
  writeFile(sourcePath, GccProxySource)
  discard requireSuccess(shellCommand(["cc", sourcePath, "-o", gccPath]))
  binDir & $PathSep & getEnv("PATH")

proc build(reproBin, target, repoRoot, pathValue: string;
           env: openArray[(string, string)] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  requireSuccess(shellCommand([reproBin, "build", target,
    "--tool-provisioning=path"], entries), repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

proc assertAction(report: JsonNode; id, status: string; launched: bool) =
  let action = reportAction(report, id)
  check action.kind != JNull
  check action{"status"}.getStr() == status
  check action{"launched"}.getBool() == launched

proc runNode(path: string; cwd = getCurrentDir()): string =
  requireSuccess(shellCommand(["node", path]), cwd)

proc mainSymbol(path, cwd: string): string =
  let output = requireSuccess(shellCommand(["nm", "-g", path]), cwd)
  for line in output.splitLines:
    if line.endsWith(" T _main") or line.endsWith(" T main"):
      return line.strip()
  output

proc jsonStringSet(node: JsonNode): seq[string] =
  for item in node.getElems():
    result.add(item.getStr())

proc hasMonitorEvidence(action: JsonNode): bool =
  action{"evidence"}{"monitorReads"}.getElems().len > 0 or
    action{"evidence"}{"monitorProbes"}.getElems().len > 0

when defined(macosx):
  suite "e2e_codetracer_in_place_project_file":
    test "real committed CodeTracer reprobuild.nim supports action-id target selection":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m30-codetracer-target-selection", "")
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

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let pathValue = codeTracerPathValue(tempRoot)
      let selectedTarget = projectRoot & "#c-sudoku-object-with-generated-header"
      let selected = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check selected.contains("selectedTarget: c-sudoku-object-with-generated-header")
      check selected.contains("scheduler: actions=2")
      check selected.contains(
        "action: generate-config-header status=asSucceeded launched=true")
      check selected.contains(
        "action: c-sudoku-object-with-generated-header status=asSucceeded launched=true")
      check not selected.contains("action: nim-js-ipc-registry-test")
      check not selected.contains("action: c-sudoku-object-tup")
      check fileExists(projectRoot / "build" / "generated" / "ct_config.h")
      check fileExists(projectRoot / "build" / "c" / "main.with-header.o")
      check not fileExists(projectRoot / "tests" / "ipc_registry_test.js")
      check not fileExists(projectRoot / "build" / "c" / "main.tup.o")

      let selectedReport = parseFile(valueAfter(selected, "buildReport:"))
      check selectedReport{"actions"}.len == 2
      assertAction(selectedReport, "generate-config-header", "asSucceeded", true)
      assertAction(selectedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)
      let selectedC = reportAction(selectedReport,
        "c-sudoku-object-with-generated-header")
      check selectedC{"dependencyPolicyKind"}.getStr() == "dgAutomaticMonitor"
      check hasMonitorEvidence(selectedC)
      check selectedC{"evidence"}{"monitorReads"}.getElems().
        anyIt(it.getStr().endsWith("test-programs/c_sudoku_solver/main.c"))
      check reportAction(selectedReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(selectedReport, "c-sudoku-object-tup").kind == JNull
      check mainSymbol("build/c/main.with-header.o", projectRoot).len > 0

    test "real committed CodeTracer reprobuild.nim builds in place through public CLI, provider, scheduler, cache, and invalidation":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m29-codetracer-in-place", "")
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

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let pathValue = codeTracerPathValue(tempRoot)
      let first = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      check first.contains("provisioning-disabled mode active")
      check first.contains("providerCompile:")
      check first.contains("providerGraphSnapshot:")
      check first.contains("scheduler: actions=4")
      check first.contains("action: generate-config-header status=asSucceeded launched=true")
      check first.contains("action: nim-js-ipc-registry-test status=asSucceeded launched=true")
      check first.contains("action: c-sudoku-object-tup status=asSucceeded launched=true")
      check first.contains("action: c-sudoku-object-with-generated-header status=asSucceeded launched=true")
      check fileExists(projectRoot / "build" / "generated" / "ct_config.h")
      check fileExists(projectRoot / "tests" / "ipc_registry_test.js")
      check fileExists(projectRoot / "build" / "c" / "main.tup.o")
      check fileExists(projectRoot / "build" / "c" / "main.with-header.o")

      let identity = readPathOnlyBuildIdentity(valueAfter(first, "toolIdentity:"))
      check identity.profiles.len == 4
      check identity.profiles.allIt(it.installMethod == "path")
      check identity.profiles.allIt(it.cachePortability == cpLocalOnly)
      check identity.profiles.anyIt(it.executableName == "nim")
      check identity.profiles.anyIt(it.executableName == "node")
      check identity.profiles.anyIt(it.executableName == "gcc")
      check identity.profiles.anyIt(it.executableName == "sh")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      assertAction(firstReport, "generate-config-header", "asSucceeded", true)
      assertAction(firstReport, "nim-js-ipc-registry-test", "asSucceeded", true)
      assertAction(firstReport, "c-sudoku-object-tup", "asSucceeded", true)
      assertAction(firstReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)
      check reportAction(firstReport, "generate-config-header"){"runQuotaBackend"}.
        getStr().len > 0
      let tupInputs = jsonStringSet(reportAction(firstReport, "c-sudoku-object-tup"){
        "evidence"}{"declaredInputs"})
      check tupInputs.anyIt(it.endsWith("test-programs/c_sudoku_solver/main.c"))
      check not tupInputs.anyIt(it.endsWith("build/generated/ct_config.h"))
      let headerInputs = jsonStringSet(reportAction(firstReport,
        "c-sudoku-object-with-generated-header"){"evidence"}{"declaredInputs"})
      check headerInputs.anyIt(it.endsWith("test-programs/c_sudoku_solver/main.c"))
      check headerInputs.anyIt(it.endsWith("build/generated/ct_config.h"))

      let monitoredC = reportAction(firstReport, "c-sudoku-object-tup")
      check monitoredC{"dependencyPolicyKind"}.getStr() == "dgAutomaticMonitor"
      check hasMonitorEvidence(monitoredC)

      check runNode("tests/ipc_registry_test.js", projectRoot).contains(
        "[OK] handlers still invoked after reconnect")
      check mainSymbol("build/c/main.tup.o", projectRoot).len > 0
      check mainSymbol("build/c/main.with-header.o", projectRoot).len > 0

      let second = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "generate-config-header", "asCacheHit", false)
      assertAction(secondReport, "nim-js-ipc-registry-test", "asCacheHit", false)
      assertAction(secondReport, "c-sudoku-object-tup", "asCacheHit", false)
      assertAction(secondReport, "c-sudoku-object-with-generated-header",
        "asCacheHit", false)

      let cSource = projectRoot / "test-programs" / "c_sudoku_solver" / "main.c"
      writeFile(cSource, readFile(cSource) &
        "\n/* reprobuild m29 selected-source edit */\n")
      let cChanged = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      let cChangedReport = parseFile(valueAfter(cChanged, "buildReport:"))
      assertAction(cChangedReport, "generate-config-header", "asCacheHit", false)
      assertAction(cChangedReport, "nim-js-ipc-registry-test", "asCacheHit", false)
      assertAction(cChangedReport, "c-sudoku-object-tup", "asSucceeded", true)
      assertAction(cChangedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)

      removeFile(projectRoot / "build" / "generated" / "ct_config.h")
      let headerDeleted = build(reproBin, projectRoot, repoRoot, pathValue,
        monitorEnv)
      let headerDeletedReport = parseFile(valueAfter(headerDeleted, "buildReport:"))
      assertAction(headerDeletedReport, "generate-config-header", "asSucceeded", true)
      assertAction(headerDeletedReport, "nim-js-ipc-registry-test", "asCacheHit", false)
      assertAction(headerDeletedReport, "c-sudoku-object-tup", "asCacheHit", false)
      assertAction(headerDeletedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)

else:
  suite "e2e_codetracer_in_place_project_file":
    test "CodeTracer automatic monitor project gate is macOS-only":
      echo "SKIP: automatic monitor dependency gathering currently requires macOS"
