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

const StylusFixtureSource = r"""
#include <errno.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int mkdir_p(const char *path) {
  char *copy = strdup(path);
  if (copy == NULL) return 126;
  for (char *p = copy + 1; *p != '\0'; p++) {
    if (*p == '/') {
      *p = '\0';
      if (mkdir(copy, 0777) != 0 && errno != EEXIST) {
        free(copy);
        return 1;
      }
      *p = '/';
    }
  }
  if (mkdir(copy, 0777) != 0 && errno != EEXIST) {
    free(copy);
    return 1;
  }
  free(copy);
  return 0;
}

static int ensure_parent(const char *path) {
  char *copy = strdup(path);
  if (copy == NULL) return 126;
  char *dir = dirname(copy);
  int code = mkdir_p(dir);
  free(copy);
  return code;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("stylus 1.0.0");
    return 0;
  }
  const char *output = "";
  const char *source = "";
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) output = argv[++i];
    else if (argv[i][0] == '-') return 64;
    else source = argv[i];
  }
  if (output[0] == '\0' || source[0] == '\0') return 65;
  if (ensure_parent(output) != 0) return 1;
  FILE *in = fopen(source, "r");
  if (in == NULL) return 2;
  FILE *out = fopen(output, "w");
  if (out == NULL) {
    fclose(in);
    return 3;
  }
  fprintf(out, "/* %s */\n", source);
  char buffer[4096];
  size_t n = 0;
  while ((n = fread(buffer, 1, sizeof(buffer), in)) > 0) {
    if (fwrite(buffer, 1, n, out) != n) {
      fclose(in);
      fclose(out);
      return 4;
    }
  }
  fclose(in);
  fclose(out);
  return 0;
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

proc compilePublicReproTestBin(repoRoot: string): string =
  result = repoRoot / "build" / "test-bin" / "repro"
  createDir(result.splitPath.head)
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" /
      "m35-codetracer-relative-public-repro",
    "--out:" & result,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

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

proc copyTree(sourceRoot, destRoot: string) =
  for sourcePath in walkDirRec(sourceRoot):
    let relative = relativePath(sourcePath, sourceRoot)
    let destPath = destRoot / relative
    if dirExists(sourcePath):
      createDir(destPath)
    elif fileExists(sourcePath):
      createDir(destPath.splitPath.head)
      copyFile(sourcePath, destPath)

proc linkCodeTracerSiblingDeps(codeTracerRoot, projectRoot: string) =
  for dep in ["isonim", "nim-everywhere"]:
    let sourcePath = codeTracerRoot.parentDir / dep
    let destPath = projectRoot.parentDir / dep
    if dirExists(sourcePath) and not pathExists(destPath):
      discard requireSuccess(shellCommand([
        "ln", "-s", sourcePath, destPath
      ]))

proc copyCodeTracerReprobuildFiles(codeTracerRoot, projectRoot: string) =
  linkCodeTracerSiblingDeps(codeTracerRoot, projectRoot)
  copyFile(codeTracerRoot / "reprobuild.nim", projectRoot / "reprobuild.nim")
  if dirExists(codeTracerRoot / "reprobuild"):
    copyTree(codeTracerRoot / "reprobuild", projectRoot / "reprobuild")
  copyFile(codeTracerRoot / "nim.cfg", projectRoot / "nim.cfg")

proc copySelectedCodeTracerProject(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "test-programs" / "c_sudoku_solver")
  copyCodeTracerReprobuildFiles(codeTracerRoot, projectRoot)
  copyFile(codeTracerRoot / "src" / "helpers.js", projectRoot / "helpers.js")
  copyTree(codeTracerRoot / "src" / "frontend",
    projectRoot / "src" / "frontend")
  copyTree(codeTracerRoot / "src" / "common",
    projectRoot / "src" / "common")
  copyTree(codeTracerRoot / "src" / "lsp",
    projectRoot / "src" / "lsp")
  createDir(projectRoot / "src" / "ct")
  copyFile(codeTracerRoot / "src" / "ct" / "version.nim",
    projectRoot / "src" / "ct" / "version.nim")
  copyTree(codeTracerRoot / "src" / "ct" / "acp",
    projectRoot / "src" / "ct" / "acp")
  createDir(projectRoot / "src" / "public" / "resources")
  createDir(projectRoot / "src" / "public" / "third_party")
  copyFile(codeTracerRoot / "src" / "public" / "Tupfile",
    projectRoot / "src" / "public" / "Tupfile")
  copyFile(codeTracerRoot / "src" / "public" / "resources" / "calltrace.js",
    projectRoot / "src" / "public" / "resources" / "calltrace.js")
  copyFile(codeTracerRoot / "src" / "public" / "third_party" / "io.js",
    projectRoot / "src" / "public" / "third_party" / "io.js")
  createDir(projectRoot / "src" / "public" / "third_party" / "monaco-themes" /
    "themes" / "customThemes" / "json")
  for theme in ["codetracerWhite.json", "codetracerDark.json"]:
    copyFile(codeTracerRoot / "src" / "public" / "third_party" /
      "monaco-themes" /
      "themes" / "customThemes" / "json" / theme,
      projectRoot / "src" / "public" / "third_party" / "monaco-themes" /
      "themes" / "customThemes" / "json" / theme)
  copyFile(codeTracerRoot / "test-programs" / "c_sudoku_solver" / "main.c",
    projectRoot / "test-programs" / "c_sudoku_solver" / "main.c")
  discard requireSuccess(shellCommand([
    "ln", "-s", codeTracerRoot / "libs", projectRoot / "libs"
  ]))

proc copyNativeCodeTracerProject(codeTracerRoot, projectRoot: string) =
  copyCodeTracerReprobuildFiles(codeTracerRoot, projectRoot)
  copyTree(codeTracerRoot / "src" / "ct", projectRoot / "src" / "ct")
  copyTree(codeTracerRoot / "src" / "common", projectRoot / "src" / "common")
  copyTree(codeTracerRoot / "src" / "db_connector",
    projectRoot / "src" / "db_connector")
  copyTree(codeTracerRoot / "src" / "shell-integrations",
    projectRoot / "src" / "shell-integrations")
  discard requireSuccess(shellCommand([
    "ln", "-s", codeTracerRoot / "libs", projectRoot / "libs"
  ]))

proc copyAggregateCodeTracerProject(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "test-programs" / "c_sudoku_solver")
  copyCodeTracerReprobuildFiles(codeTracerRoot, projectRoot)
  copyFile(codeTracerRoot / "src" / "helpers.js", projectRoot / "helpers.js")
  copyTree(codeTracerRoot / "src" / "frontend",
    projectRoot / "src" / "frontend")
  copyTree(codeTracerRoot / "src" / "common",
    projectRoot / "src" / "common")
  copyTree(codeTracerRoot / "src" / "lsp",
    projectRoot / "src" / "lsp")
  copyTree(codeTracerRoot / "src" / "ct", projectRoot / "src" / "ct")
  copyTree(codeTracerRoot / "src" / "db_connector",
    projectRoot / "src" / "db_connector")
  copyTree(codeTracerRoot / "src" / "shell-integrations",
    projectRoot / "src" / "shell-integrations")
  createDir(projectRoot / "src" / "config")
  copyFile(codeTracerRoot / "src" / "config" / "default_layout.json",
    projectRoot / "src" / "config" / "default_layout.json")
  copyFile(codeTracerRoot / "src" / "config" / "default_config.yaml",
    projectRoot / "src" / "config" / "default_config.yaml")
  createDir(projectRoot / "src" / "public" / "resources")
  createDir(projectRoot / "src" / "public" / "third_party")
  copyFile(codeTracerRoot / "src" / "public" / "Tupfile",
    projectRoot / "src" / "public" / "Tupfile")
  copyFile(codeTracerRoot / "src" / "public" / "resources" / "calltrace.js",
    projectRoot / "src" / "public" / "resources" / "calltrace.js")
  copyFile(codeTracerRoot / "src" / "public" / "third_party" / "io.js",
    projectRoot / "src" / "public" / "third_party" / "io.js")
  createDir(projectRoot / "src" / "public" / "third_party" /
    "monaco-themes" / "themes" / "customThemes" / "json")
  for theme in ["codetracerWhite.json", "codetracerDark.json"]:
    copyFile(codeTracerRoot / "src" / "public" / "third_party" /
      "monaco-themes" / "themes" / "customThemes" / "json" / theme,
      projectRoot / "src" / "public" / "third_party" / "monaco-themes" /
      "themes" / "customThemes" / "json" / theme)
  copyFile(codeTracerRoot / "test-programs" / "c_sudoku_solver" / "main.c",
    projectRoot / "test-programs" / "c_sudoku_solver" / "main.c")
  discard requireSuccess(shellCommand([
    "ln", "-s", codeTracerRoot / "libs", projectRoot / "libs"
  ]))

proc codeTracerPathValue(tempRoot: string; includeClang = false): string =
  let binDir = tempRoot / "codetracer-tool-bin"
  createDir(binDir)
  let sourcePath = binDir / "gcc-proxy.c"
  let gccPath = binDir / "gcc"
  let clangPath = binDir / "clang"
  writeFile(sourcePath, GccProxySource)
  discard requireSuccess(shellCommand(["cc", sourcePath, "-o", gccPath]))
  if includeClang:
    discard requireSuccess(shellCommand(["ln", "-s", gccPath, clangPath]))
  let stylusSourcePath = binDir / "stylus-fixture.c"
  let stylusPath = binDir / "stylus"
  writeFile(stylusSourcePath, StylusFixtureSource)
  discard requireSuccess(shellCommand(["cc", stylusSourcePath, "-o", stylusPath]))
  binDir & $PathSep & getEnv("PATH")

proc codeTracerNativePathValue(codeTracerRoot, tempRoot: string): string =
  let nimBinDir = codeTracerRoot / "non-nix-build" / "deps" / "nim" / "bin"
  let nimPath = nimBinDir / "nim"
  check fileExists(nimPath)
  nimBinDir & $PathSep & codeTracerPathValue(tempRoot, includeClang = true)

proc codeTracerHybridNimPathValue(codeTracerRoot, tempRoot: string): string =
  let basePath = codeTracerPathValue(tempRoot, includeClang = true)
  let binDir = tempRoot / "codetracer-tool-bin"
  let localNim = codeTracerRoot / "non-nix-build" / "deps" / "nim" /
    "bin" / "nim"
  let hostNim = findExe("nim")
  check fileExists(localNim)
  check hostNim.len > 0
  writeExecutable(binDir / "nim",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"js\" ]; then\n" &
    "  exec " & q(hostNim) & " \"$@\"\n" &
    "fi\n" &
    "exec " & q(localNim) & " \"$@\"\n")
  basePath

proc nixStorePaths(output: string): seq[string] =
  for line in output.splitLines:
    let item = line.strip()
    if item.startsWith("/nix/store/"):
      result.add(item)

proc nativeLibraryEnv(repoRoot: string): seq[(string, string)] =
  let output = requireSuccess(shellCommand([
    "nix", "build", "--no-link", "--print-out-paths",
    "nixpkgs#openssl.out",
    "nixpkgs#sqlite.out",
    "nixpkgs#pcre.out",
    "nixpkgs#libzip.out"
  ]), repoRoot)
  let storePaths = nixStorePaths(output)
  check storePaths.len == 4

  var libraryPaths: seq[string] = @[]
  var includePaths: seq[string] = @[]
  for storePath in storePaths:
    libraryPaths.add(storePath / "lib")
    includePaths.add(storePath / "include")
  if getEnv("LIBRARY_PATH").len > 0:
    libraryPaths.add(getEnv("LIBRARY_PATH"))
  if getEnv("C_INCLUDE_PATH").len > 0:
    includePaths.add(getEnv("C_INCLUDE_PATH"))

  result = @[
    ("LIBRARY_PATH", libraryPaths.join($PathSep)),
    ("C_INCLUDE_PATH", includePaths.join($PathSep))
  ]

proc build(reproBin, target, repoRoot, pathValue: string;
           env: openArray[(string, string)] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  requireSuccess(shellCommand([reproBin, "build", target,
    "--tool-provisioning=path"], entries), repoRoot)

proc buildCurrentProject(reproBin, projectRoot, pathValue: string;
                         env: openArray[(string, string)] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  requireSuccess(shellCommand([reproBin, "build", "--tool-provisioning=path"],
    entries), projectRoot)

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

proc checkPublicResourceOutputs(projectRoot: string) =
  let pairs = [
    ("src/public/Tupfile", "public/Tupfile"),
    ("src/public/resources/calltrace.js", "public/resources/calltrace.js"),
    ("src/public/third_party/io.js", "public/third_party/io.js"),
    ("src/public/third_party/monaco-themes/themes/customThemes/json/" &
      "codetracerWhite.json",
      "public/third_party/monaco-themes/themes/customThemes/json/" &
      "codetracerWhite.json")
  ]
  for (source, output) in pairs:
    check fileExists(projectRoot / output)
    check readFile(projectRoot / source) == readFile(projectRoot / output)

proc assertPublicResourceActions(report: JsonNode; status: string;
                                 launched: bool) =
  assertAction(report, publicResourceAction, status, launched)

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

proc monitorEvidenceContains(action: JsonNode; suffix: string): bool =
  for key in ["monitorReads", "monitorProbes"]:
    for item in action{"evidence"}{key}.getElems():
      if item.getStr().endsWith(suffix):
        return true

proc declaredEvidenceContains(action: JsonNode; suffix: string): bool =
  for item in action{"evidence"}{"declaredInputs"}.getElems():
    if item.getStr().endsWith(suffix):
      return true

proc checkFrontendBundleOutputs(projectRoot: string) =
  check fileExists(projectRoot / "ui.js")
  check fileExists(projectRoot / "public" / "ui.js")
  check fileExists(projectRoot / "index.js")
  check fileExists(projectRoot / "index.js.map")
  check fileExists(projectRoot / "src" / "index.js")
  check fileExists(projectRoot / "server_index.js")
  check fileExists(projectRoot / "server_index.js.map")
  check fileExists(projectRoot / "subwindow.js")
  check fileExists(projectRoot / "subwindow.js.map")
  check fileExists(projectRoot / "src" / "subwindow.js")
  for stylesheet in [
    "default_white_theme.css",
    "default_dark_theme_electron.css",
    "default_dark_theme_extension.css",
    "default_dark_theme.css",
    "loader.css",
    "subwindow.css"
  ]:
    check fileExists(projectRoot / "src" / "frontend" / "styles" /
      stylesheet)
  check fileExists(projectRoot / "index.html")
  check fileExists(projectRoot / "subwindow.html")
  check fileExists(projectRoot / "src" / "helpers.js")
  check readFile(projectRoot / "ui.js") ==
    readFile(projectRoot / "public" / "ui.js")
  check readFile(projectRoot / "index.js") ==
    readFile(projectRoot / "src" / "index.js")
  check readFile(projectRoot / "subwindow.js") ==
    readFile(projectRoot / "src" / "subwindow.js")
  check readFile(projectRoot / "src" / "frontend" / "index.html") ==
    readFile(projectRoot / "index.html")
  check readFile(projectRoot / "src" / "frontend" / "subwindow.html") ==
    readFile(projectRoot / "subwindow.html")
  check readFile(projectRoot / "helpers.js") ==
    readFile(projectRoot / "src" / "helpers.js")

proc checkConfigOutputs(projectRoot: string) =
  check fileExists(projectRoot / "config" / "default_layout.json")
  check fileExists(projectRoot / "config" / "default_config.yaml")
  check readFile(projectRoot / "src" / "config" / "default_layout.json") ==
    readFile(projectRoot / "config" / "default_layout.json")
  check readFile(projectRoot / "src" / "config" / "default_config.yaml") ==
    readFile(projectRoot / "config" / "default_config.yaml")

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

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      let projectText = readFile(projectRoot / "reprobuild.nim")
      check projectText == readFile(realProjectFile)
      check not projectText.contains("writeProject")
      check not projectText.contains("buildAction(")
      check not projectText.contains("gcc.compile")
      check not projectText.contains("nim_js")
      check not projectText.contains("nimJs")
      check not projectText.contains("\"nim-js >=2\"")
      check not projectText.contains("args = @[")

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
      check selected.contains("scheduler: actions=3")
      check selected.contains(
        "action: generate-config-header status=asSucceeded launched=true")
      check selected.contains(
        "action: build-c-dir status=asSucceeded launched=true")
      check selected.contains(
        "action: c-sudoku-object-with-generated-header status=asSucceeded launched=true")
      check not selected.contains("action: nim-js-ipc-registry-test")
      check not selected.contains("action: c-sudoku-object-tup")
      check fileExists(projectRoot / "build" / "generated" / "ct_config.h")
      check fileExists(projectRoot / "build" / "c" / "main.with-header.o")
      check not fileExists(projectRoot / "tests" / "ipc_registry_test.js")
      check not fileExists(projectRoot / "build" / "c" / "main.tup.o")

      let selectedReport = parseFile(valueAfter(selected, "buildReport:"))
      check selectedReport{"actions"}.len == 3
      assertAction(selectedReport, "generate-config-header", "asSucceeded", true)
      assertAction(selectedReport, "build-c-dir", "asSucceeded", true)
      assertAction(selectedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)
      check reportAction(selectedReport, "build-c-dir"){"runQuotaBackend"}.
        getStr() == "builtin"
      let selectedC = reportAction(selectedReport,
        "c-sudoku-object-with-generated-header")
      check selectedC{"dependencyPolicyKind"}.getStr() == "dgAutomaticMonitor"
      check hasMonitorEvidence(selectedC)
      check selectedC{"evidence"}{"monitorReads"}.getElems().
        anyIt(it.getStr().endsWith("test-programs/c_sudoku_solver/main.c"))
      check reportAction(selectedReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(selectedReport, "frontend-ui-js").kind == JNull
      check reportAction(selectedReport, "frontend-public-ui-js").kind == JNull
      check reportAction(selectedReport, "frontend-subwindow-js").kind == JNull
      check reportAction(selectedReport, "frontend-src-subwindow-js").kind ==
        JNull
      check reportAction(selectedReport, "frontend-index-js").kind == JNull
      check reportAction(selectedReport, "frontend-src-index-js").kind == JNull
      check reportAction(selectedReport, "frontend-server-index-js").kind ==
        JNull
      check reportAction(selectedReport, "frontend").kind == JNull
      check reportAction(selectedReport, "c-sudoku-object-tup").kind == JNull
      check mainSymbol("build/c/main.with-header.o", projectRoot).len > 0

    test "selected frontend public ui.js target builds real Nim JS closure with monitor evidence":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m33-codetracer-ui-js", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

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
      let selectedTarget = projectRoot & "#frontend-public-ui-js"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check first.contains("selectedTarget: frontend-public-ui-js")
      check first.contains("scheduler: actions=2")
      check first.contains(
        "action: frontend-ui-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-public-ui-js status=asSucceeded launched=true")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: frontend-index-js")
      check not first.contains("action: frontend-server-index-js")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      check fileExists(projectRoot / "ui.js")
      check fileExists(projectRoot / "public" / "ui.js")
      check readFile(projectRoot / "ui.js") ==
        readFile(projectRoot / "public" / "ui.js")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 2
      assertAction(firstReport, "frontend-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-public-ui-js", "asSucceeded", true)
      let frontendAction = reportAction(firstReport, "frontend-ui-js")
      check frontendAction{"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(frontendAction)
      check monitorEvidenceContains(frontendAction, "src/frontend/ui_js.nim")
      check monitorEvidenceContains(frontendAction,
        "src/frontend/ui/calltrace.nim")
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "frontend-index-js").kind == JNull
      check reportAction(firstReport, "frontend-server-index-js").kind == JNull
      check reportAction(firstReport, "frontend").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-public-ui-js", "asCacheHit", false)

      let importedInput = projectRoot / "src" / "frontend" / "ui" /
        "calltrace.nim"
      writeFile(importedInput, readFile(importedInput) &
        "\n# reprobuild m33 selected frontend edit\n")
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check not changed.contains("action: frontend-index-js")
      check not changed.contains("action: frontend-server-index-js")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "frontend-ui-js", "asSucceeded", true)
      assertAction(changedReport, "frontend-public-ui-js", "asSucceeded", true)
      check reportAction(changedReport, "frontend-index-js").kind == JNull
      check reportAction(changedReport, "frontend-server-index-js").kind ==
        JNull
      check reportAction(changedReport, "frontend").kind == JNull
      check reportAction(changedReport, "c-sudoku-object-tup").kind == JNull

    test "selected frontend src subwindow.js target builds real Nim JS closure with monitor evidence":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m34-codetracer-subwindow-js", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

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
      let selectedTarget = projectRoot & "#frontend-src-subwindow-js"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check first.contains("selectedTarget: frontend-src-subwindow-js")
      check first.contains("scheduler: actions=2")
      check first.contains(
        "action: frontend-subwindow-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-src-subwindow-js status=asSucceeded launched=true")
      check not first.contains("action: frontend-ui-js")
      check not first.contains("action: frontend-public-ui-js")
      check not first.contains("action: frontend-index-js")
      check not first.contains("action: frontend-server-index-js")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      check fileExists(projectRoot / "subwindow.js")
      check fileExists(projectRoot / "subwindow.js.map")
      check fileExists(projectRoot / "src" / "subwindow.js")
      check readFile(projectRoot / "subwindow.js") ==
        readFile(projectRoot / "src" / "subwindow.js")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 2
      assertAction(firstReport, "frontend-subwindow-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-subwindow-js", "asSucceeded", true)
      let frontendAction = reportAction(firstReport, "frontend-subwindow-js")
      check frontendAction{"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(frontendAction)
      check monitorEvidenceContains(frontendAction,
        "src/frontend/subwindow.nim")
      check monitorEvidenceContains(frontendAction, "src/frontend/lang.nim")
      check reportAction(firstReport, "frontend-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-public-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-index-js").kind == JNull
      check reportAction(firstReport, "frontend-server-index-js").kind == JNull
      check reportAction(firstReport, "frontend").kind == JNull
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-subwindow-js", "asCacheHit",
        false)

      let importedInput = projectRoot / "src" / "frontend" / "lang.nim"
      writeFile(importedInput, readFile(importedInput) &
        "\n# reprobuild m34 selected frontend edit\n")
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check not changed.contains("action: frontend-ui-js")
      check not changed.contains("action: frontend-index-js")
      check not changed.contains("action: frontend-server-index-js")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "frontend-subwindow-js", "asSucceeded", true)
      assertAction(changedReport, "frontend-src-subwindow-js", "asSucceeded",
        true)
      check reportAction(changedReport, "frontend-ui-js").kind == JNull
      check reportAction(changedReport, "frontend-index-js").kind == JNull
      check reportAction(changedReport, "frontend-server-index-js").kind ==
        JNull
      check reportAction(changedReport, "frontend").kind == JNull
      check reportAction(changedReport, "c-sudoku-object-tup").kind == JNull

    test "selected frontend src index.js target builds real Nim JS closure with monitor evidence":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m36-codetracer-index-js", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

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
      let selectedTarget = projectRoot & "#frontend-src-index-js"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check first.contains("selectedTarget: frontend-src-index-js")
      check first.contains("scheduler: actions=2")
      check first.contains(
        "action: frontend-index-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-src-index-js status=asSucceeded launched=true")
      check not first.contains("action: frontend-ui-js")
      check not first.contains("action: frontend-public-ui-js")
      check not first.contains("action: frontend-subwindow-js")
      check not first.contains("action: frontend-src-subwindow-js")
      check not first.contains("action: frontend-server-index-js")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      check fileExists(projectRoot / "index.js")
      check fileExists(projectRoot / "index.js.map")
      check fileExists(projectRoot / "src" / "index.js")
      check readFile(projectRoot / "index.js") ==
        readFile(projectRoot / "src" / "index.js")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 2
      assertAction(firstReport, "frontend-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-index-js", "asSucceeded", true)
      let frontendAction = reportAction(firstReport, "frontend-index-js")
      check frontendAction{"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(frontendAction)
      check monitorEvidenceContains(frontendAction, "src/frontend/index.nim")
      check monitorEvidenceContains(frontendAction,
        "src/frontend/index/window.nim")
      check reportAction(firstReport, "frontend-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-public-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-subwindow-js").kind == JNull
      check reportAction(firstReport, "frontend-src-subwindow-js").kind ==
        JNull
      check reportAction(firstReport, "frontend-server-index-js").kind == JNull
      check reportAction(firstReport, "frontend").kind == JNull
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "frontend-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-index-js", "asCacheHit", false)

      let importedInput = projectRoot / "src" / "frontend" / "index" /
        "window.nim"
      writeFile(importedInput, readFile(importedInput) &
        "\n# reprobuild m36 selected frontend edit\n")
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check not changed.contains("action: frontend-ui-js")
      check not changed.contains("action: frontend-subwindow-js")
      check not changed.contains("action: frontend-server-index-js")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "frontend-index-js", "asSucceeded", true)
      assertAction(changedReport, "frontend-src-index-js", "asSucceeded", true)
      check reportAction(changedReport, "frontend-ui-js").kind == JNull
      check reportAction(changedReport, "frontend-subwindow-js").kind == JNull
      check reportAction(changedReport, "frontend-server-index-js").kind ==
        JNull
      check reportAction(changedReport, "frontend").kind == JNull
      check reportAction(changedReport, "c-sudoku-object-tup").kind == JNull

    test "selected db-backend-record target builds real native Nim binary":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m42-codetracer-db-backend-record", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copyNativeCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let pathValue = codeTracerNativePathValue(codeTracerRoot, tempRoot)
      check requireSuccess(shellCommand(["sh", "-c", "command -v nim"],
        [("PATH", pathValue)]), repoRoot).strip() ==
        codeTracerRoot / "non-nix-build" / "deps" / "nim" / "bin" / "nim"
      var nativeEnv: seq[(string, string)] = @[]
      for item in monitorEnv:
        nativeEnv.add(item)
      for item in nativeLibraryEnv(repoRoot):
        nativeEnv.add(item)
      let selectedTarget = projectRoot & "#db-backend-record"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check first.contains("selectedTarget: db-backend-record")
      check first.contains("scheduler: actions=1")
      check first.contains(
        "action: db-backend-record status=asSucceeded launched=true")
      check not first.contains("action: frontend-ui-js")
      check not first.contains("action: frontend-index-js")
      check not first.contains("action: frontend-server-index-js")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      check fileExists(projectRoot / "src" / "bin" / "db-backend-record")

      let fileOutput = requireSuccess(shellCommand([
        "file", "src/bin/db-backend-record"
      ]), projectRoot)
      check fileOutput.contains("Mach-O")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 1
      assertAction(firstReport, "db-backend-record", "asSucceeded", true)
      let nativeAction = reportAction(firstReport, "db-backend-record")
      check nativeAction{"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(nativeAction)
      check declaredEvidenceContains(nativeAction,
        "src/ct/db_backend_record.nim")
      check monitorEvidenceContains(nativeAction,
        "src/ct/trace/storage_and_import.nim")
      check reportAction(firstReport, "frontend-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-index-js").kind == JNull
      check reportAction(firstReport, "frontend-server-index-js").kind == JNull
      check reportAction(firstReport, "frontend").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "db-backend-record", "asCacheHit", false)

      let nativeInput = projectRoot / "src" / "ct" / "db_backend_record.nim"
      writeFile(nativeInput, readFile(nativeInput) &
        "\n# reprobuild m42 selected native edit\n")
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check not changed.contains("action: frontend-ui-js")
      check not changed.contains("action: frontend-index-js")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "db-backend-record", "asSucceeded", true)

    test "selected ct target builds real native Nim binary":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m43-codetracer-ct", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copyNativeCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let pathValue = codeTracerNativePathValue(codeTracerRoot, tempRoot)
      check requireSuccess(shellCommand(["sh", "-c", "command -v nim"],
        [("PATH", pathValue)]), repoRoot).strip() ==
        codeTracerRoot / "non-nix-build" / "deps" / "nim" / "bin" / "nim"
      var nativeEnv: seq[(string, string)] = @[]
      for item in monitorEnv:
        nativeEnv.add(item)
      for item in nativeLibraryEnv(repoRoot):
        nativeEnv.add(item)
      let selectedTarget = projectRoot & "#ct"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check first.contains("selectedTarget: ct")
      check first.contains("scheduler: actions=1")
      check first.contains("action: ct status=asSucceeded launched=true")
      check not first.contains("action: db-backend-record")
      check not first.contains("action: frontend-ui-js")
      check not first.contains("action: frontend-index-js")
      check not first.contains("action: frontend-server-index-js")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      check fileExists(projectRoot / "src" / "bin" / "ct")
      discard requireSuccess(shellCommand([
        "sh", "-c", "test -x src/bin/ct"
      ]), projectRoot)

      let fileOutput = requireSuccess(shellCommand([
        "file", "src/bin/ct"
      ]), projectRoot)
      check fileOutput.contains("Mach-O")
      check fileOutput.contains("executable")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 1
      assertAction(firstReport, "ct", "asSucceeded", true)
      let nativeAction = reportAction(firstReport, "ct")
      check nativeAction{"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(nativeAction)
      check declaredEvidenceContains(nativeAction, "src/ct/codetracer.nim")
      check monitorEvidenceContains(nativeAction, "src/ct/codetracerconf.nim")
      check reportAction(firstReport, "db-backend-record").kind == JNull
      check reportAction(firstReport, "frontend-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-index-js").kind == JNull
      check reportAction(firstReport, "frontend-server-index-js").kind == JNull
      check reportAction(firstReport, "frontend").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check second.contains("action: ct status=asCacheHit launched=false")
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "ct", "asCacheHit", false)

      let nativeInput = projectRoot / "src" / "ct" / "codetracer.nim"
      writeFile(nativeInput, readFile(nativeInput) &
        "\n# reprobuild m43 selected native edit\n")
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check not changed.contains("action: db-backend-record")
      check not changed.contains("action: frontend-ui-js")
      check not changed.contains("action: frontend-index-js")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "ct", "asSucceeded", true)

    test "selected codetracer aggregate builds implemented app slice":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m44-codetracer-aggregate", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = compilePublicReproTestBin(repoRoot)

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copyAggregateCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let pathValue = codeTracerHybridNimPathValue(codeTracerRoot, tempRoot)
      check requireSuccess(shellCommand(["sh", "-c", "command -v nim"],
        [("PATH", pathValue)]), repoRoot).strip().len > 0
      var nativeEnv: seq[(string, string)] = @[]
      for item in monitorEnv:
        nativeEnv.add(item)
      for item in nativeLibraryEnv(repoRoot):
        nativeEnv.add(item)

      let selectedTarget = projectRoot & "#codetracer"
      let first = buildCurrentProject(reproBin, projectRoot, pathValue,
        nativeEnv)
      check first.contains("defaultTarget: codetracer")
      check first.contains("selectedTarget: codetracer")
      check first.contains("scheduler: actions=21")
      check first.contains("action: ct status=asSucceeded launched=true")
      check first.contains(
        "action: db-backend-record status=asSucceeded launched=true")
      check first.contains(
        "action: config-default-layout-json status=asSucceeded launched=true")
      check first.contains(
        "action: config-default-config-yaml status=asSucceeded launched=true")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: generate-config-header")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      checkFrontendBundleOutputs(projectRoot)
      checkPublicResourceOutputs(projectRoot)
      checkConfigOutputs(projectRoot)
      check fileExists(projectRoot / "src" / "bin" / "ct")
      check fileExists(projectRoot / "src" / "bin" / "db-backend-record")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 21
      assertAction(firstReport, "frontend-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-public-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-server-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-subwindow-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-subwindow-js", "asSucceeded",
        true)
      assertAction(firstReport, "frontend-index-html", "asSucceeded", true)
      assertAction(firstReport, "frontend-subwindow-html", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-helpers-js", "asSucceeded", true)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(firstReport,
          "src/frontend/styles/" & stylesheet, "asSucceeded", true)
      assertPublicResourceActions(firstReport, "asSucceeded", true)
      assertAction(firstReport, "config-default-layout-json", "asSucceeded",
        true)
      assertAction(firstReport, "config-default-config-yaml", "asSucceeded",
        true)
      assertAction(firstReport, "db-backend-record", "asSucceeded", true)
      assertAction(firstReport, "ct", "asSucceeded", true)
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "generate-config-header").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull
      check reportAction(firstReport, "ct"){"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(reportAction(firstReport, "ct"))
      check monitorEvidenceContains(reportAction(firstReport, "ct"),
        "src/ct/codetracerconf.nim")
      check declaredEvidenceContains(reportAction(firstReport, "ct"),
        "src/ct/codetracer.nim")

      let aggregateIdentity =
        readPathOnlyBuildIdentity(valueAfter(first, "toolIdentity:"))
      check aggregateIdentity.profiles.anyIt(it.executableName == "nim")
      check not aggregateIdentity.profiles.anyIt(it.executableName == "nim-js")

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check second.contains("selectedTarget: codetracer")
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      check secondReport{"actions"}.len == 21
      assertAction(secondReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-server-index-js", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-subwindow-js", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-index-html", "asCacheHit", false)
      assertAction(secondReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-src-helpers-js", "asCacheHit",
        false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(secondReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(secondReport, "asSucceeded", true)
      assertAction(secondReport, "config-default-layout-json", "asCacheHit",
        false)
      assertAction(secondReport, "config-default-config-yaml", "asCacheHit",
        false)
      assertAction(secondReport, "db-backend-record", "asCacheHit", false)
      assertAction(secondReport, "ct", "asCacheHit", false)

      let nativeInput = projectRoot / "src" / "ct" / "codetracer.nim"
      let nativeSource = readFile(nativeInput)
      check nativeSource.contains(
        "CodeTracer - the user-friendly time-travelling debugger")
      writeFile(nativeInput, nativeSource.replace(
        "CodeTracer - the user-friendly time-travelling debugger",
        "CodeTracer - the user-friendly reprobuild m44 debugger"))
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      check not changed.contains("action: nim-js-ipc-registry-test")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(changedReport, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(changedReport, "frontend-index-js", "asCacheHit", false)
      assertAction(changedReport, "frontend-src-index-js", "asCacheHit",
        false)
      assertAction(changedReport, "frontend-server-index-js", "asCacheHit",
        false)
      assertAction(changedReport, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(changedReport, "frontend-src-subwindow-js", "asCacheHit",
        false)
      assertAction(changedReport, "frontend-index-html", "asCacheHit", false)
      assertAction(changedReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(changedReport, "frontend-src-helpers-js", "asCacheHit",
        false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(changedReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(changedReport, "asSucceeded", true)
      assertAction(changedReport, "config-default-layout-json", "asCacheHit",
        false)
      assertAction(changedReport, "config-default-config-yaml", "asCacheHit",
        false)
      assertAction(changedReport, "db-backend-record", "asCacheHit", false)
      assertAction(changedReport, "ct", "asSucceeded", true)
      check reportAction(changedReport, "nim-js-ipc-registry-test").kind ==
        JNull
      check reportAction(changedReport, "generate-config-header").kind == JNull
      check reportAction(changedReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(changedReport,
        "c-sudoku-object-with-generated-header").kind == JNull

    test "selected frontend server index.js target builds real Nim JS closure with monitor evidence":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m37-codetracer-server-index-js", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

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
      let selectedTarget = projectRoot & "#frontend-server-index-js"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check first.contains("selectedTarget: frontend-server-index-js")
      check first.contains("scheduler: actions=1")
      check first.contains(
        "action: frontend-server-index-js status=asSucceeded launched=true")
      check not first.contains("action: frontend-index-js")
      check not first.contains("action: frontend-src-index-js")
      check not first.contains("action: frontend-ui-js")
      check not first.contains("action: frontend-public-ui-js")
      check not first.contains("action: frontend-subwindow-js")
      check not first.contains("action: frontend-src-subwindow-js")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      check fileExists(projectRoot / "server_index.js")
      check fileExists(projectRoot / "server_index.js.map")
      check not fileExists(projectRoot / "src" / "index.js")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 1
      assertAction(firstReport, "frontend-server-index-js", "asSucceeded", true)
      let frontendAction = reportAction(firstReport, "frontend-server-index-js")
      check frontendAction{"dependencyPolicyKind"}.getStr() ==
        "dgAutomaticMonitor"
      check hasMonitorEvidence(frontendAction)
      check monitorEvidenceContains(frontendAction, "src/frontend/index.nim")
      check monitorEvidenceContains(frontendAction,
        "src/frontend/index/window.nim")
      check reportAction(firstReport, "frontend-index-js").kind == JNull
      check reportAction(firstReport, "frontend-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-subwindow-js").kind == JNull
      check reportAction(firstReport, "frontend").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "frontend-server-index-js", "asCacheHit",
        false)

      let importedInput = projectRoot / "src" / "frontend" / "index" /
        "window.nim"
      writeFile(importedInput, readFile(importedInput) &
        "\n# reprobuild m37 selected frontend edit\n")
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check not changed.contains("action: frontend-index-js")
      check not changed.contains("action: frontend-ui-js")
      check not changed.contains("action: frontend-subwindow-js")
      check not changed.contains("action: c-sudoku-object-tup")
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertAction(changedReport, "frontend-server-index-js", "asSucceeded",
        true)
      check reportAction(changedReport, "frontend-index-js").kind == JNull
      check reportAction(changedReport, "frontend-ui-js").kind == JNull
      check reportAction(changedReport, "frontend-subwindow-js").kind == JNull
      check reportAction(changedReport, "frontend").kind == JNull
      check reportAction(changedReport, "c-sudoku-object-tup").kind == JNull

    test "selected frontend public resource tree target copies generated resources":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m41-codetracer-public-resources", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let pathValue = codeTracerPathValue(tempRoot)
      let selectedTarget = projectRoot & "#frontend-public-resources"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue)
      check first.contains("selectedTarget: frontend-public-resources")
      check first.contains("providerInvocations: 1")
      check first.contains(
        "action: frontend-public-resources status=asSucceeded launched=true")
      check first.contains("scheduler: actions=1")
      check not first.contains("action: frontend-ui-js")
      check not first.contains("action: frontend-index-js")
      check not first.contains("action: frontend-subwindow-js")
      check not first.contains("action: frontend-server-index-js")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: generate-config-header")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      checkPublicResourceOutputs(projectRoot)

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 1
      assertPublicResourceActions(firstReport, "asSucceeded", true)
      check reportAction(firstReport, "frontend-ui-js").kind == JNull
      check reportAction(firstReport, "frontend-index-js").kind == JNull
      check reportAction(firstReport, "frontend-subwindow-js").kind == JNull
      check reportAction(firstReport, "frontend-server-index-js").kind == JNull
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "generate-config-header").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      check secondReport{"actions"}.len == 1
      assertPublicResourceActions(secondReport, "asSucceeded", true)

      let addedSource = projectRoot / "src" / "public" / "resources" /
        "shared" / "add_file.svg"
      createDir(addedSource.splitPath.head)
      copyFile(codeTracerRoot / "src" / "public" / "resources" / "shared" /
        "add_file.svg", addedSource)
      let added = build(reproBin, selectedTarget, repoRoot, pathValue)
      check added.contains("providerInvocations: 1")
      check added.contains("scheduler: actions=1")
      check added.contains(
        "action: frontend-public-resources status=asSucceeded launched=true")
      check fileExists(projectRoot / "public" / "resources" / "shared" /
        "add_file.svg")
      check readFile(addedSource) == readFile(projectRoot / "public" /
        "resources" / "shared" / "add_file.svg")

      removeFile(projectRoot / "src" / "public" / "third_party" / "io.js")
      let removed = build(reproBin, selectedTarget, repoRoot, pathValue)
      check removed.contains("providerInvocations: 1")
      check removed.contains("scheduler: actions=1")
      let removedReport = parseFile(valueAfter(removed, "buildReport:"))
      check removedReport{"actions"}.len == 1
      check not fileExists(projectRoot / "public" / "third_party" / "io.js")

    test "m51_codetracer_stdlib_file_ops":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)
      let projectText = readFile(realProjectFile)
      check projectText.contains("import repro_dsl_stdlib")
      check projectText.contains("fs.copyFile")
      check projectText.contains("fs.writeText")
      check projectText.contains("fs.ensureDir")
      check projectText.contains("fs.preserveTree")
      check not projectText.contains("sh(")
      check not projectText.contains("mkdir -p")
      check not projectText.contains(" cp ")
      check not projectText.contains("buildAction(\"frontend-public-resource")

      let tempRoot = createTempDir("repro-m51-codetracer-stdlib-fs", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"
      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == projectText

      let pathValue = codeTracerPathValue(tempRoot)
      let first = build(reproBin, projectRoot & "#frontend-public-resources",
        repoRoot, pathValue)
      check first.contains("selectedTarget: frontend-public-resources")
      check first.contains("scheduler: actions=1")
      check first.contains(
        "action: frontend-public-resources status=asSucceeded launched=true")
      check first.contains("runquota=builtin")
      checkPublicResourceOutputs(projectRoot)

      removeFile(projectRoot / "src" / "public" / "third_party" / "io.js")
      let removed = build(reproBin, projectRoot & "#frontend-public-resources",
        repoRoot, pathValue)
      check removed.contains("scheduler: actions=1")
      check not fileExists(projectRoot / "public" / "third_party" / "io.js")

    test "selected frontend aggregate target builds current frontend bundle set":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m38-codetracer-frontend", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"

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
      let selectedTarget = projectRoot & "#frontend"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check first.contains("selectedTarget: frontend")
      check first.contains("scheduler: actions=17")
      check first.contains(
        "action: frontend-ui-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-public-ui-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-index-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-src-index-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-server-index-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-subwindow-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-src-subwindow-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-index-html status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-subwindow-html status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-src-helpers-js status=asSucceeded launched=true")
      check first.contains(
        "action: frontend-public-resources status=asSucceeded launched=true")
      check not first.contains("action: nim-js-ipc-registry-test")
      check not first.contains("action: generate-config-header")
      check not first.contains("action: c-sudoku-object-tup")
      check not first.contains("action: c-sudoku-object-with-generated-header")
      checkFrontendBundleOutputs(projectRoot)
      checkPublicResourceOutputs(projectRoot)

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 17
      assertAction(firstReport, "frontend-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-public-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-server-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-subwindow-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-subwindow-js", "asSucceeded",
        true)
      assertAction(firstReport, "frontend-index-html", "asSucceeded", true)
      assertAction(firstReport, "frontend-subwindow-html", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-helpers-js", "asSucceeded", true)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(firstReport,
          "src/frontend/styles/" & stylesheet, "asSucceeded", true)
      assertPublicResourceActions(firstReport, "asSucceeded", true)
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "generate-config-header").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertAction(secondReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-server-index-js", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-subwindow-js", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-index-html", "asCacheHit", false)
      assertAction(secondReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-src-helpers-js", "asCacheHit",
        false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(secondReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(secondReport, "asSucceeded", true)

      let indexHtml = projectRoot / "src" / "frontend" / "index.html"
      writeFile(indexHtml, readFile(indexHtml) &
        "\n<!-- reprobuild m39 frontend static html edit -->\n")
      let htmlChanged = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check not htmlChanged.contains("action: nim-js-ipc-registry-test")
      check not htmlChanged.contains("action: generate-config-header")
      check not htmlChanged.contains("action: c-sudoku-object-tup")
      check not htmlChanged.contains(
        "action: c-sudoku-object-with-generated-header")
      let htmlChangedReport = parseFile(valueAfter(htmlChanged, "buildReport:"))
      assertAction(htmlChangedReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(htmlChangedReport, "frontend-public-ui-js", "asCacheHit",
        false)
      assertAction(htmlChangedReport, "frontend-index-js", "asCacheHit", false)
      assertAction(htmlChangedReport, "frontend-src-index-js", "asCacheHit",
        false)
      assertAction(htmlChangedReport, "frontend-server-index-js", "asCacheHit",
        false)
      assertAction(htmlChangedReport, "frontend-subwindow-js", "asCacheHit",
        false)
      assertAction(htmlChangedReport, "frontend-src-subwindow-js",
        "asCacheHit", false)
      assertAction(htmlChangedReport, "frontend-index-html", "asSucceeded",
        true)
      assertAction(htmlChangedReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(htmlChangedReport, "frontend-src-helpers-js", "asCacheHit",
        false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(htmlChangedReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(htmlChangedReport, "asSucceeded", true)
      check readFile(projectRoot / "src" / "frontend" / "index.html") ==
        readFile(projectRoot / "index.html")
      check reportAction(htmlChangedReport, "nim-js-ipc-registry-test").kind ==
        JNull
      check reportAction(htmlChangedReport, "generate-config-header").kind ==
        JNull
      check reportAction(htmlChangedReport, "c-sudoku-object-tup").kind == JNull

      writeFile(projectRoot / "helpers.js",
        readFile(projectRoot / "helpers.js") &
        "\n// reprobuild m39 static helper edit\n")
      let helperChanged = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      check not helperChanged.contains("action: nim-js-ipc-registry-test")
      check not helperChanged.contains("action: generate-config-header")
      check not helperChanged.contains("action: c-sudoku-object-tup")
      check not helperChanged.contains(
        "action: c-sudoku-object-with-generated-header")
      let helperChangedReport =
        parseFile(valueAfter(helperChanged, "buildReport:"))
      assertAction(helperChangedReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(helperChangedReport, "frontend-public-ui-js", "asCacheHit",
        false)
      assertAction(helperChangedReport, "frontend-index-js", "asCacheHit",
        false)
      assertAction(helperChangedReport, "frontend-src-index-js", "asCacheHit",
        false)
      assertAction(helperChangedReport, "frontend-server-index-js",
        "asCacheHit", false)
      assertAction(helperChangedReport, "frontend-subwindow-js", "asCacheHit",
        false)
      assertAction(helperChangedReport, "frontend-src-subwindow-js",
        "asCacheHit", false)
      assertAction(helperChangedReport, "frontend-index-html", "asCacheHit",
        false)
      assertAction(helperChangedReport, "frontend-subwindow-html",
        "asCacheHit", false)
      assertAction(helperChangedReport, "frontend-src-helpers-js",
        "asSucceeded", true)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(helperChangedReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(helperChangedReport, "asSucceeded", true)
      check readFile(projectRoot / "helpers.js") ==
        readFile(projectRoot / "src" / "helpers.js")
      check reportAction(helperChangedReport,
        "nim-js-ipc-registry-test").kind == JNull
      check reportAction(helperChangedReport, "generate-config-header").kind ==
        JNull
      check reportAction(helperChangedReport, "c-sudoku-object-tup").kind ==
        JNull

    test "m52_codetracer_uses_stdlib_packages":
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
      let projectText = readFile(projectRoot / "reprobuild.nim")
      check projectText == readFile(realProjectFile)
      check not projectText.contains("writeProject")
      check not projectText.contains("usesImportPath")
      check not projectText.contains("defineCliInterface")
      check not dirExists(projectRoot / "reprobuild" / "packages")

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
      check first.contains("scheduler: actions=22")
      check first.contains("action: generate-config-header status=asSucceeded launched=true")
      check first.contains("action: build-c-dir status=asSucceeded launched=true")
      check first.contains("action: nim-js-ipc-registry-test status=asSucceeded launched=true")
      check first.contains("action: frontend-ui-js status=asSucceeded launched=true")
      check first.contains("action: frontend-public-ui-js status=asSucceeded launched=true")
      check first.contains("action: frontend-index-js status=asSucceeded launched=true")
      check first.contains("action: frontend-src-index-js status=asSucceeded launched=true")
      check first.contains("action: frontend-server-index-js status=asSucceeded launched=true")
      check first.contains("action: frontend-subwindow-js status=asSucceeded launched=true")
      check first.contains("action: frontend-src-subwindow-js status=asSucceeded launched=true")
      check first.contains("action: frontend-index-html status=asSucceeded launched=true")
      check first.contains("action: frontend-subwindow-html status=asSucceeded launched=true")
      check first.contains("action: frontend-src-helpers-js status=asSucceeded launched=true")
      check first.contains("action: frontend-public-resources status=asSucceeded launched=true")
      check first.contains("action: c-sudoku-object-tup status=asSucceeded launched=true")
      check first.contains("action: c-sudoku-object-with-generated-header status=asSucceeded launched=true")
      check fileExists(projectRoot / "build" / "generated" / "ct_config.h")
      check fileExists(projectRoot / "tests" / "ipc_registry_test.js")
      check fileExists(projectRoot / "ui.js")
      check fileExists(projectRoot / "public" / "ui.js")
      check fileExists(projectRoot / "index.js")
      check fileExists(projectRoot / "index.js.map")
      check fileExists(projectRoot / "src" / "index.js")
      check fileExists(projectRoot / "server_index.js")
      check fileExists(projectRoot / "server_index.js.map")
      check fileExists(projectRoot / "subwindow.js")
      check fileExists(projectRoot / "subwindow.js.map")
      check fileExists(projectRoot / "src" / "subwindow.js")
      check fileExists(projectRoot / "index.html")
      check fileExists(projectRoot / "subwindow.html")
      check fileExists(projectRoot / "src" / "helpers.js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        check fileExists(projectRoot / "src" / "frontend" / "styles" /
          stylesheet)
      checkPublicResourceOutputs(projectRoot)
      check fileExists(projectRoot / "build" / "c" / "main.tup.o")
      check fileExists(projectRoot / "build" / "c" / "main.with-header.o")

      let identity = readPathOnlyBuildIdentity(valueAfter(first, "toolIdentity:"))
      check identity.profiles.len == 4
      check identity.profiles.allIt(it.installMethod == "path")
      check identity.profiles.allIt(it.cachePortability == cpLocalOnly)
      check identity.profiles.anyIt(it.executableName == "nim")
      check identity.profiles.anyIt(it.executableName == "node")
      check identity.profiles.anyIt(it.executableName == "gcc")
      check identity.profiles.anyIt(it.executableName == "stylus")
      check not identity.profiles.anyIt(it.executableName == "nim-js")
      check not identity.profiles.anyIt(it.executableName == "sh")

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      assertAction(firstReport, "generate-config-header", "asSucceeded", true)
      assertAction(firstReport, "build-c-dir", "asSucceeded", true)
      assertAction(firstReport, "nim-js-ipc-registry-test", "asSucceeded", true)
      assertAction(firstReport, "frontend-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-public-ui-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-server-index-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-subwindow-js", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-subwindow-js", "asSucceeded",
        true)
      assertAction(firstReport, "frontend-index-html", "asSucceeded", true)
      assertAction(firstReport, "frontend-subwindow-html", "asSucceeded", true)
      assertAction(firstReport, "frontend-src-helpers-js", "asSucceeded", true)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(firstReport,
          "src/frontend/styles/" & stylesheet, "asSucceeded", true)
      assertPublicResourceActions(firstReport, "asSucceeded", true)
      assertAction(firstReport, "c-sudoku-object-tup", "asSucceeded", true)
      assertAction(firstReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)
      check reportAction(firstReport, "generate-config-header"){"runQuotaBackend"}.
        getStr() == "builtin"
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
      assertAction(secondReport, "build-c-dir", "asUpToDate", false)
      assertAction(secondReport, "nim-js-ipc-registry-test", "asCacheHit", false)
      assertAction(secondReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-server-index-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(secondReport, "frontend-src-subwindow-js", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-index-html", "asCacheHit", false)
      assertAction(secondReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(secondReport, "frontend-src-helpers-js", "asCacheHit",
        false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(secondReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(secondReport, "asSucceeded", true)
      assertAction(secondReport, "c-sudoku-object-tup", "asCacheHit", false)
      assertAction(secondReport, "c-sudoku-object-with-generated-header",
        "asCacheHit", false)

      let cSource = projectRoot / "test-programs" / "c_sudoku_solver" / "main.c"
      writeFile(cSource, readFile(cSource) &
        "\n/* reprobuild m29 selected-source edit */\n")
      let cChanged = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      let cChangedReport = parseFile(valueAfter(cChanged, "buildReport:"))
      assertAction(cChangedReport, "generate-config-header", "asCacheHit", false)
      assertAction(cChangedReport, "build-c-dir", "asUpToDate", false)
      assertAction(cChangedReport, "nim-js-ipc-registry-test", "asCacheHit", false)
      assertAction(cChangedReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(cChangedReport, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(cChangedReport, "frontend-index-js", "asCacheHit", false)
      assertAction(cChangedReport, "frontend-src-index-js", "asCacheHit",
        false)
      assertAction(cChangedReport, "frontend-server-index-js", "asCacheHit",
        false)
      assertAction(cChangedReport, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(cChangedReport, "frontend-src-subwindow-js", "asCacheHit",
        false)
      assertAction(cChangedReport, "frontend-index-html", "asCacheHit", false)
      assertAction(cChangedReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(cChangedReport, "frontend-src-helpers-js", "asCacheHit",
        false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(cChangedReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(cChangedReport, "asSucceeded", true)
      assertAction(cChangedReport, "c-sudoku-object-tup", "asSucceeded", true)
      assertAction(cChangedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)

      removeFile(projectRoot / "build" / "generated" / "ct_config.h")
      let headerDeleted = build(reproBin, projectRoot, repoRoot, pathValue,
        monitorEnv)
      let headerDeletedReport = parseFile(valueAfter(headerDeleted, "buildReport:"))
      assertAction(headerDeletedReport, "generate-config-header", "asSucceeded", true)
      assertAction(headerDeletedReport, "build-c-dir", "asUpToDate", false)
      assertAction(headerDeletedReport, "nim-js-ipc-registry-test", "asCacheHit", false)
      assertAction(headerDeletedReport, "frontend-ui-js", "asCacheHit", false)
      assertAction(headerDeletedReport, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(headerDeletedReport, "frontend-index-js", "asCacheHit",
        false)
      assertAction(headerDeletedReport, "frontend-src-index-js", "asCacheHit",
        false)
      assertAction(headerDeletedReport, "frontend-server-index-js",
        "asCacheHit", false)
      assertAction(headerDeletedReport, "frontend-subwindow-js", "asCacheHit",
        false)
      assertAction(headerDeletedReport, "frontend-src-subwindow-js",
        "asCacheHit", false)
      assertAction(headerDeletedReport, "frontend-index-html", "asCacheHit",
        false)
      assertAction(headerDeletedReport, "frontend-subwindow-html", "asCacheHit",
        false)
      assertAction(headerDeletedReport, "frontend-src-helpers-js",
        "asCacheHit", false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(headerDeletedReport,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(headerDeletedReport, "asSucceeded", true)
      assertAction(headerDeletedReport, "c-sudoku-object-tup", "asCacheHit", false)
      assertAction(headerDeletedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)

else:
  suite "e2e_codetracer_in_place_project_file":
    test "CodeTracer automatic monitor project gate is macOS-only":
      echo "SKIP: automatic monitor dependency gathering currently requires macOS"
