import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

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

proc shellCommand(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

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

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  let socketPath = "/tmp/repro-m31-rq-" & $getCurrentProcessId() & ".sock"
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

proc hasMonitorEvidence(action: JsonNode): bool =
  action{"evidence"}{"monitorReads"}.getElems().len > 0 or
    action{"evidence"}{"monitorProbes"}.getElems().len > 0

proc checkFrontendBundleOutputs(projectRoot: string) =
  check fileExists(projectRoot / "public" / "ui.js")
  check fileExists(projectRoot / "src" / "index.js")
  check fileExists(projectRoot / "index.js.map")
  check fileExists(projectRoot / "server_index.js")
  check fileExists(projectRoot / "server_index.js.map")
  check fileExists(projectRoot / "src" / "subwindow.js")
  check fileExists(projectRoot / "subwindow.js.map")
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
  check fileExists(projectRoot / "public" / "resources" / "calltrace.js")
  check fileExists(projectRoot / "public" / "third_party" / "io.js")
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

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "repro"
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & (tempRoot / "nimcache-repro"),
    "--out:" & result,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)

proc compilePublicReproTestBin(repoRoot: string): string =
  result = repoRoot / "build" / "test-bin" / "repro"
  createDir(result.splitPath.head)
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" /
      "m35-watch-relative-public-repro",
    "--out:" & result,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)

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
      "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-watch-shim",
      "--out:" & arm64Path,
      repoRoot / "libs" / "repro_monitor_shim" / "src" /
        "repro_monitor_shim" / "macos_interpose.nim"
    ]), repoRoot)
    discard requireSuccess(shellCommand([
      "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
      "--passC:-arch arm64e", "--passL:-arch arm64e",
      "--path:/Users/zahary/metacraft/ct_interpose/src",
      "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-watch-shim-arm64e",
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
      result.fsSnoop, "m32-watch-repro-fs-snoop")

proc runWatchAndEdit(reproBin, target, repoRoot, pathValue, logPath, editPath,
                     editText: string; debounceMs = 50;
                     env: openArray[(string, string)] = []): string =
  var envLines = "export PATH=" & q(pathValue) & "\n"
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
  check res.code == 0
  log

proc runWatchCurrentProjectAndEdit(reproBin, projectRoot, pathValue, logPath,
                                   editPath, editText: string;
                                   debounceMs = 50;
                                   env: openArray[(string, string)] = []): string =
  var envLines = "export PATH=" & q(pathValue) & "\n"
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
  check res.code == 0
  log

proc runWatchAndReplace(reproBin, target, repoRoot, pathValue, logPath,
                        editPath, oldText, newText: string; debounceMs = 50;
                        env: openArray[(string, string)] = []): string =
  var envLines = "export PATH=" & q(pathValue) & "\n"
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
    "RB_OLD=" & q(oldText) & " RB_NEW=" & q(newText) &
      " perl -0pi -e 'BEGIN{$old=$ENV{RB_OLD};$new=$ENV{RB_NEW}} " &
      "s/\\Q$old\\E/$new/g' " & q(editPath) & "\n" &
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
  check res.code == 0
  log

proc runWatchAndCopy(reproBin, target, repoRoot, pathValue, logPath,
                     sourcePath, destPath: string; debounceMs = 50;
                     env: openArray[(string, string)] = []): string =
  var envLines = "export PATH=" & q(pathValue) & "\n"
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
    "mkdir -p " & q(destPath.splitPath.head) & "\n" &
    "cp " & q(sourcePath) & " " & q(destPath) & "\n" &
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

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"
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

      discard compilePublicReproTestBin(repoRoot)
      let reproBin = "build/test-bin/repro"
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

    test "CodeTracer copied checkout watch rebuilds selected C action only":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m31-codetracer-watch", "")
      defer: removeDir(tempRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = compileRepro(repoRoot, tempRoot)
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)

      let selectedTarget =
        projectRoot & "#c-sudoku-object-with-generated-header"
      let cSource = projectRoot / "test-programs" /
        "c_sudoku_solver" / "main.c"
      let log = runWatchAndEdit(reproBin, selectedTarget, repoRoot,
        codeTracerPathValue(tempRoot), tempRoot / "codetracer-watch.log", cSource,
        "\n/* reprobuild m31 watch edit */\n", env = monitorEnv)
      check log.contains("repro watch: event seen path=")
      check log.contains(
        "selectedTarget: c-sudoku-object-with-generated-header")
      check log.contains("scheduler: actions=3")
      check not log.contains("action: nim-js-ipc-registry-test")
      check not log.contains("action: c-sudoku-object-tup")

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      check report{"actions"}.len == 3
      assertAction(report, "generate-config-header", "asCacheHit", false)
      assertAction(report, "build-c-dir", "asUpToDate", false)
      assertAction(report, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)
      let selectedC = reportAction(report, "c-sudoku-object-with-generated-header")
      check selectedC{"dependencyPolicyKind"}.getStr() == "dgAutomaticMonitor"
      check hasMonitorEvidence(selectedC)
      check reportAction(report, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(report, "c-sudoku-object-tup").kind == JNull

    test "CodeTracer copied checkout watch rebuilds selected frontend aggregate":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m38-codetracer-frontend-watch", "")
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
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)

      let selectedTarget = projectRoot & "#frontend"
      let importedInput = projectRoot / "src" / "frontend" / "index.html"
      let log = runWatchAndEdit(reproBin, selectedTarget, repoRoot,
        codeTracerPathValue(tempRoot), tempRoot / "codetracer-frontend-watch.log",
        importedInput, "\n<!-- reprobuild m39 watch frontend static edit -->\n",
        env = monitorEnv)
      check log.contains("repro watch: target=" & selectedTarget)
      check log.contains("repro watch: event seen path=")
      check log.contains("repro watch: cycle 2 start rebuild")
      check log.contains("repro watch: max cycles reached")
      check log.contains("selectedTarget: frontend")
      check log.contains("scheduler: actions=17")
      check not log.contains("action: nim-js-ipc-registry-test")
      check not log.contains("action: generate-config-header")
      check not log.contains("action: c-sudoku-object-tup")
      check not log.contains("action: c-sudoku-object-with-generated-header")
      checkFrontendBundleOutputs(projectRoot)

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      check report{"actions"}.len == 17
      assertAction(report, "frontend-ui-js", "asCacheHit", false)
      assertAction(report, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(report, "frontend-index-js", "asCacheHit", false)
      assertAction(report, "frontend-src-index-js", "asCacheHit", false)
      assertAction(report, "frontend-server-index-js", "asCacheHit", false)
      assertAction(report, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(report, "frontend-src-subwindow-js", "asCacheHit", false)
      assertAction(report, "frontend-index-html", "asSucceeded", true)
      assertAction(report, "frontend-subwindow-html", "asCacheHit", false)
      assertAction(report, "frontend-src-helpers-js", "asCacheHit", false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(report,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(report, "asSucceeded", true)
      check reportAction(report, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(report, "generate-config-header").kind == JNull
      check reportAction(report, "c-sudoku-object-tup").kind == JNull
      check reportAction(report,
        "c-sudoku-object-with-generated-header").kind == JNull

    test "CodeTracer copied checkout watch rebuilds selected app aggregate":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m44-codetracer-aggregate-watch", "")
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
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      var nativeEnv: seq[(string, string)] = @[]
      for item in monitorEnv:
        nativeEnv.add(item)
      for item in nativeLibraryEnv(repoRoot):
        nativeEnv.add(item)

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copyAggregateCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)

      let selectedTarget = projectRoot & "#codetracer"
      let nativeInput = projectRoot / "src" / "ct" / "codetracer.nim"
      let oldText = "CodeTracer - the user-friendly time-travelling debugger"
      let newText = "CodeTracer - the user-friendly reprobuild m44 debugger"
      check readFile(nativeInput).contains(oldText)
      let pathValue = codeTracerHybridNimPathValue(codeTracerRoot, tempRoot)
      check requireSuccess("PATH=" & q(pathValue) & " " &
        shellCommand(["sh", "-c", "command -v nim"]), repoRoot).strip().len > 0
      let log = runWatchAndReplace(reproBin, selectedTarget, repoRoot,
        pathValue, tempRoot / "codetracer-aggregate-watch.log", nativeInput,
        oldText, newText, env = nativeEnv)
      check log.contains("repro watch: target=" & selectedTarget)
      check log.contains("repro watch: event seen path=")
      check log.contains("repro watch: cycle 2 start rebuild")
      check log.contains("repro watch: max cycles reached")
      check log.contains("selectedTarget: codetracer")
      check log.contains("scheduler: actions=21")
      check not log.contains("action: nim-js-ipc-registry-test")
      check not log.contains("action: generate-config-header")
      check not log.contains("action: c-sudoku-object-tup")
      check not log.contains("action: c-sudoku-object-with-generated-header")
      checkFrontendBundleOutputs(projectRoot)
      checkConfigOutputs(projectRoot)
      check fileExists(projectRoot / "src" / "bin" / "ct")
      check fileExists(projectRoot / "src" / "bin" / "db-backend-record")

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      check report{"actions"}.len == 21
      assertAction(report, "frontend-ui-js", "asCacheHit", false)
      assertAction(report, "frontend-public-ui-js", "asCacheHit", false)
      assertAction(report, "frontend-index-js", "asCacheHit", false)
      assertAction(report, "frontend-src-index-js", "asCacheHit", false)
      assertAction(report, "frontend-server-index-js", "asCacheHit", false)
      assertAction(report, "frontend-subwindow-js", "asCacheHit", false)
      assertAction(report, "frontend-src-subwindow-js", "asCacheHit", false)
      assertAction(report, "frontend-index-html", "asCacheHit", false)
      assertAction(report, "frontend-subwindow-html", "asCacheHit", false)
      assertAction(report, "frontend-src-helpers-js", "asCacheHit", false)
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputAction(report,
          "src/frontend/styles/" & stylesheet, "asCacheHit", false)
      assertPublicResourceActions(report, "asSucceeded", true)
      assertAction(report, "config-default-layout-json", "asCacheHit", false)
      assertAction(report, "config-default-config-yaml", "asCacheHit", false)
      assertAction(report, "db-backend-record", "asCacheHit", false)
      assertAction(report, "ct", "asSucceeded", true)
      check reportAction(report, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(report, "generate-config-header").kind == JNull
      check reportAction(report, "c-sudoku-object-tup").kind == JNull
      check reportAction(report,
        "c-sudoku-object-with-generated-header").kind == JNull

    test "CodeTracer copied checkout watch builds added frontend public resource":
      let repoRoot = getCurrentDir()
      let codeTracerRoot = absolutePath(repoRoot / ".." / "codetracer")
      let realProjectFile = codeTracerRoot / "reprobuild.nim"
      check fileExists(realProjectFile)

      let tempRoot = createTempDir("repro-m41-codetracer-resource-watch", "")
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

      let selectedTarget = projectRoot & "#frontend-public-resources"
      let sourcePath = codeTracerRoot / "src" / "public" / "resources" /
        "shared" / "add_file.svg"
      let destPath = projectRoot / "src" / "public" / "resources" /
        "shared" / "add_file.svg"
      let log = runWatchAndCopy(reproBin, selectedTarget, repoRoot,
        codeTracerPathValue(tempRoot), tempRoot / "codetracer-resource-watch.log",
        sourcePath, destPath)
      check log.contains("repro watch: target=" & selectedTarget)
      check log.contains("repro watch: event seen path=")
      check log.contains("repro watch: cycle 2 start rebuild")
      check log.contains("repro watch: max cycles reached")
      check log.contains("selectedTarget: frontend-public-resources")
      check log.contains("scheduler: actions=1")
      check log.contains(
        "action: " & publicResourceAction &
          " status=asSucceeded launched=true")
      check not log.contains("action: frontend-ui-js")
      check not log.contains("action: frontend-index-js")
      check not log.contains("action: nim-js-ipc-registry-test")
      check not log.contains("action: c-sudoku-object-tup")
      check fileExists(projectRoot / "public" / "resources" / "shared" /
        "add_file.svg")
      check readFile(sourcePath) == readFile(projectRoot / "public" /
        "resources" / "shared" / "add_file.svg")

      let report = parseFile(projectRoot / ".repro" / "build" /
        "reprobuild" / "build-report.json")
      check report{"actions"}.len == 1
      assertAction(report, publicResourceAction, "asSucceeded", true)
      check reportAction(report, "frontend-ui-js").kind == JNull
      check reportAction(report, "frontend-index-js").kind == JNull
      check reportAction(report, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(report, "c-sudoku-object-tup").kind == JNull

else:
  suite "e2e_repro_watch":
    test "event-driven watch E2E is macOS kqueue-only in M31":
      echo "SKIP: repro watch filesystem E2E currently requires macOS kqueue"
