import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles

const MonitorFixtureSource = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static char *read_all(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return NULL;
  char buffer[4096];
  ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
  close(fd);
  if (count < 0) return NULL;
  buffer[count] = '\0';
  char *copy = malloc((size_t)count + 1);
  if (copy == NULL) return NULL;
  memcpy(copy, buffer, (size_t)count + 1);
  return copy;
}

static const char *flag_value(int argc, char **argv, const char *name) {
  for (int i = 2; i + 1 < argc; i++) {
    if (strcmp(argv[i], name) == 0) return argv[i + 1];
  }
  return "";
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("m32-monitor-producer 1.0.0");
    return 0;
  }
  if (argc < 10 || strcmp(argv[1], "produce") != 0) return 64;
  const char *visible_path = flag_value(argc, argv, "--visible");
  const char *hidden_path = flag_value(argc, argv, "--hidden");
  const char *output_path = flag_value(argc, argv, "--output");
  const char *marker_path = flag_value(argc, argv, "--marker");
  char *visible = read_all(visible_path);
  char *hidden = read_all(hidden_path);
  if (visible == NULL || hidden == NULL) return 65;
  FILE *output = fopen(output_path, "w");
  if (output == NULL) return 66;
  fprintf(output, "visible=%shidden=%s", visible, hidden);
  fclose(output);
  FILE *marker = fopen(marker_path, "a");
  if (marker == NULL) return 67;
  fputs("producer\n", marker);
  fclose(marker);
  free(visible);
  free(hidden);
  return 0;
}
"""

const M52StdlibFixtureSource = r"""
#include <errno.h>
#include <libgen.h>
#include <stdbool.h>
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

static int copy_with_header(const char *source, const char *output) {
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

static int write_text(const char *output, const char *text) {
  if (ensure_parent(output) != 0) return 1;
  FILE *out = fopen(output, "w");
  if (out == NULL) return 2;
  fputs(text, out);
  fclose(out);
  return 0;
}

int main(int argc, char **argv) {
  const char *tool = strrchr(argv[0], '/');
  tool = tool == NULL ? argv[0] : tool + 1;
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    if (strcmp(tool, "nim") == 0) puts("nim 2.2.4");
    else if (strcmp(tool, "gcc") == 0) puts("gcc fixture 1.0.0");
    else puts("stylus fixture 1.0.0");
    return 0;
  }

  if (strcmp(tool, "nim") == 0) {
    if (argc < 2 || strcmp(argv[1], "c") != 0) return 64;
    const char *output = "";
    const char *source = "";
    for (int i = 2; i < argc; i++) {
      if (strncmp(argv[i], "--out:", 6) == 0) output = argv[i] + 6;
      else if (argv[i][0] != '-') source = argv[i];
    }
    if (output[0] == '\0' || source[0] == '\0') return 65;
    char text[4096];
    snprintf(text, sizeof(text), "nim:c:%s\n", source);
    return write_text(output, text);
  }

  if (strcmp(tool, "gcc") == 0) {
    const char *output = "";
    const char *source = "";
    const char *pic = "no";
    const char *compile = "no";
    for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) output = argv[++i];
      else if (strcmp(argv[i], "-fPIC") == 0) pic = "yes";
      else if (strcmp(argv[i], "-c") == 0) compile = "yes";
      else if (strcmp(argv[i], "-include") == 0 && i + 1 < argc) i++;
      else if (argv[i][0] != '-') source = argv[i];
    }
    if (output[0] == '\0' || source[0] == '\0') return 65;
    char text[4096];
    snprintf(text, sizeof(text), "gcc:%s:%s:%s\n", source, pic, compile);
    return write_text(output, text);
  }

  const char *output = "";
  const char *source = "";
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) output = argv[++i];
    else if (argv[i][0] == '-') return 64;
    else source = argv[i];
  }
  if (output[0] == '\0' || source[0] == '\0') return 65;
  return copy_with_header(source, output);
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

proc requireFailure(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  check res.code != 0
  res.output

proc hasInlineFlag(args: openArray[string]; prefix: string): bool =
  for arg in args:
    if arg == prefix or arg.startsWith(prefix & "="):
      return true

proc requestsQuietProgress(args: openArray[string]): bool =
  for arg in args:
    if arg.startsWith("--progress="):
      let value = arg.split("=", maxsplit = 1)[1].toLowerAscii()
      if value in ["quiet", "silent", "none", "off"]:
        return true

proc addDefaultTestBuildLog(args: var seq[string];
                            extraArgs: openArray[string]) =
  if not hasInlineFlag(extraArgs, "--log") and not requestsQuietProgress(extraArgs):
    args.add("--log=actions")

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

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string) =
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath,
    sourcePath
  ]), repoRoot)

when defined(macosx) or defined(linux):
  proc compileShim(repoRoot, outputPath: string) =
    when defined(macosx):
      let arm64Path = outputPath & ".arm64"
      let arm64ePath = outputPath & ".arm64e"
      let monitorHooksPath = repoRoot / "libs" / "repro_monitor_hooks" / "src"
      discard requireSuccess(shellCommand([
        "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
        "--path:" & monitorHooksPath,
        "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-local-shim",
        "--out:" & arm64Path,
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "macos_interpose.nim"
      ]), repoRoot)
      discard requireSuccess(shellCommand([
        "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
        "--passC:-arch arm64e", "--passL:-arch arm64e",
        "--path:" & monitorHooksPath,
        "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-local-shim-arm64e",
        "--out:" & arm64ePath,
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "macos_interpose.nim"
      ]), repoRoot)
      discard requireSuccess(shellCommand([
        "lipo", "-create", "-output", outputPath, arm64Path, arm64ePath
      ]), repoRoot)
    else:
      discard requireSuccess(shellCommand([
        "nim", "c", "--app:lib", "--threads:on", "--verbosity:0", "--hints:off",
        "--nimcache:" & repoRoot / "build" / "nimcache" / "m32-local-shim",
        "--out:" & outputPath,
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "linux_preload.nim"
      ]), repoRoot)

  proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[fsSnoop: string;
      shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim =
      when defined(linux):
        libDir / "librepro_monitor_shim.so"
      else:
        libDir / "librepro_monitor_shim.dylib"
    compileShim(repoRoot, result.shim)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m32-local-repro-fs-snoop")

  proc writeMonitorFixtureTool(binDir: string) =
    let sourcePath = binDir / "m32-monitor-producer.c"
    let toolPath = binDir / "m32-monitor-producer"
    createDir(binDir)
    writeFile(sourcePath, MonitorFixtureSource)
    discard requireSuccess(shellCommand(["cc", sourcePath, "-o", toolPath]))

  proc writeMonitorProject(path: string) =
    createDir(path.splitPath.head)
    writeFile(path,
      "import repro_project_dsl\n\n" &
      "package m32Project:\n" &
      "  uses:\n" &
      "    \"m32-monitor-producer >=1.0 <2.0\"\n\n" &
      "  executable producer:\n" &
      "    name \"m32-monitor-producer\"\n" &
      "    cli:\n" &
      "      subcmd \"produce\":\n" &
      "        flag visible, string, required = true\n" &
      "        flag hidden, string, required = true\n" &
      "        flag output, string, required = true\n" &
      "        flag marker, string, required = true\n" &
      "    build:\n" &
      "      discard buildAction(\"produce\",\n" &
      "        m32Project.produce(\n" &
      "          visible = \"src/visible.txt\",\n" &
      "          hidden = \"src/hidden.txt\",\n" &
      "          output = \"build/generated.txt\",\n" &
      "          marker = \".repro/tool-runs.log\"),\n" &
      "        inputs = @[\"src/visible.txt\"],\n" &
      "        outputs = @[\"build/generated.txt\"],\n" &
      "        dependencyPolicy = automaticMonitorPolicy())\n")

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
    "        outputs = @[\"dist/unrelated.txt\"])\n" &
    "      defaultBuildAction(\"consume\")\n")

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

proc writePolicyProject(path: string; policyText: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m32PolicyProject:\n" &
    "  uses:\n" &
    "    \"m19-producer >=1.0 <2.0\"\n\n" &
    "  executable producer:\n" &
    "    name \"m19-producer\"\n" &
    "    cli:\n" &
    "      subcmd \"produce\":\n" &
    "        flag visible, string, required = true\n" &
    "        flag hidden, string, required = true\n" &
    "        flag output, string, required = true\n" &
    "        flag depfile, string, required = true\n" &
    "        flag marker, string, required = true\n" &
    "    build:\n" &
    "      discard buildAction(\"produce\",\n" &
    "        m32PolicyProject.produce(\n" &
    "          visible = \"src/visible.txt\",\n" &
    "          hidden = \"src/hidden.txt\",\n" &
    "          output = \"build/generated.txt\",\n" &
    "          depfile = \"build/generated.d\",\n" &
    "          marker = \".repro/tool-runs.log\"),\n" &
    "        inputs = @[\"src/visible.txt\"],\n" &
    "        outputs = @[\"build/generated.txt\"],\n" &
    "        depfile = \"build/generated.d\",\n" &
    "        dependencyPolicy = " & policyText & ")\n")

proc writeDirectoryEnumerationProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import std/[algorithm, os]\n" &
    "import repro_project_dsl\n\n" &
    "package m40Project:\n" &
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
    "      let marker = \".repro/m40-tool-runs.log\"\n" &
    "      for sourcePath in sourceFiles:\n" &
    "        let name = splitPath(sourcePath).tail\n" &
    "        let actionId = \"copy-\" & name\n" &
    "        let output = \"dist/\" & name & \".out\"\n" &
    "        copyDeps.add(actionId)\n" &
    "        discard buildAction(actionId,\n" &
    "          m40Project.copy(input = sourcePath, output = output,\n" &
    "            marker = marker),\n" &
    "          inputs = @[sourcePath],\n" &
    "          outputs = @[output])\n" &
    "      discard buildAction(\"aggregate\",\n" &
    "        m40Project.copy(input = \"src/aggregate.txt\",\n" &
    "          output = \"dist/aggregate.stamp\", marker = marker),\n" &
    "        deps = copyDeps,\n" &
    "        inputs = @[\"src/aggregate.txt\"],\n" &
    "        outputs = @[\"dist/aggregate.stamp\"])\n")

proc writeM46FixtureTool(binDir: string) =
  writeExecutable(binDir / "m46-tool",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm46-tool 1.0.0'; exit 0; fi\n" &
    "if [ \"${1:-}\" = \"--global\" ]; then shift; fi\n" &
    "case \"${1:-}\" in\n" &
    "  produce)\n" &
    "    shift\n" &
    "    input= output= marker=\n" &
    "    while [ \"$#\" -gt 0 ]; do\n" &
    "      case \"$1\" in\n" &
    "        --input) input=$2; shift 2 ;;\n" &
    "        --output) output=$2; shift 2 ;;\n" &
    "        --marker) marker=$2; shift 2 ;;\n" &
    "        *) echo \"unknown produce arg $1\" >&2; exit 64 ;;\n" &
    "      esac\n" &
    "    done\n" &
    "    mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "    printf 'produced:%s' \"$(cat \"$input\")\" > \"$output\"\n" &
    "    printf 'produce\\n' >> \"$marker\"\n" &
    "    ;;\n" &
    "  consume)\n" &
    "    shift\n" &
    "    input= output= marker=\n" &
    "    while [ \"$#\" -gt 0 ]; do\n" &
    "      case \"$1\" in\n" &
    "        --input) input=$2; shift 2 ;;\n" &
    "        --output) output=$2; shift 2 ;;\n" &
    "        --marker) marker=$2; shift 2 ;;\n" &
    "        *) echo \"unknown consume arg $1\" >&2; exit 64 ;;\n" &
    "      esac\n" &
    "    done\n" &
    "    mkdir -p \"$(dirname \"$output\")\" \"$(dirname \"$marker\")\"\n" &
    "    printf 'consumed:%s' \"$(cat \"$input\")\" > \"$output\"\n" &
    "    printf 'consume\\n' >> \"$marker\"\n" &
    "    ;;\n" &
    "  direct)\n" &
    "    output=$2\n" &
    "    mkdir -p \"$(dirname \"$output\")\"\n" &
    "    printf 'direct\\n' > \"$output\"\n" &
    "    ;;\n" &
    "  *)\n" &
    "    echo \"unexpected first argv slot: '${1:-}'\" >&2\n" &
    "    exit 64\n" &
    "    ;;\n" &
    "esac\n")

proc writeM46ImportedPackageProject(path: string) =
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "src")
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m46_tool.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface m46Tool, \"m46-tool\":\n" &
    "  boolFlag global is bool, alias = \"--global\"\n" &
    "  call:\n" &
    "    pos args is seq[string], position = 0, required = false\n" &
    "  subcmd \"produce\":\n" &
    "    flag input is string, required = true, role = input\n" &
    "    flag output is string, required = true, role = output\n" &
    "    flag marker is string, required = true\n" &
    "  subcmd \"consume\":\n" &
    "    flag input is string, required = true, role = input\n" &
    "    flag output is string, required = true, role = output\n" &
    "    flag marker is string, required = true\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m46Project:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m46-tool >=1.0 <2.0\"\n" &
    "  build:\n" &
    "    let marker = \".repro/m46-tool-runs.log\"\n" &
    "    m46Tool.produce(actionId = \"produce\",\n" &
    "      global = true,\n" &
    "      input = \"src/input.txt\",\n" &
    "      output = \"build/generated.txt\", marker = marker)\n" &
    "    let consume = m46Tool.consume(actionId = \"consume\",\n" &
    "      input = \"build/generated.txt\",\n" &
    "      output = \"dist/final.txt\", marker = marker)\n" &
    "    m46Tool(actionId = \"direct\",\n" &
    "      args = @[\"direct\", \"dist/direct.txt\"],\n" &
    "      extraOutputs = @[\"dist/direct.txt\"])\n" &
    "    defaultBuildAction(consume)\n")

proc writeM46ProjectWithoutImportPath(path: string) =
  writeM46ImportedPackageProject(path)
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m46Project:\n" &
    "  uses:\n" &
    "    \"m46-tool >=1.0 <2.0\"\n" &
    "  build:\n" &
    "    m46Tool.produce(actionId = \"produce\",\n" &
    "      input = \"src/input.txt\",\n" &
    "      output = \"build/generated.txt\", marker = \".repro/runs.log\")\n")

proc writeM47GccFixtureTool(binDir: string) =
  writeExecutable(binDir / "m47-gcc",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm47-gcc 1.0.0'; exit 0; fi\n" &
    "pic=false debug3=false compile_only=false output= source= includes=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    -fPIC) pic=true; shift ;;\n" &
    "    -g3) debug3=true; shift ;;\n" &
    "    -c) compile_only=true; shift ;;\n" &
    "    -include) includes=\"${includes}${includes:+ }$2\"; shift 2 ;;\n" &
    "    -o) output=$2; shift 2 ;;\n" &
    "    -*) echo \"unknown gcc-style flag $1\" >&2; exit 64 ;;\n" &
    "    *) source=$1; shift ;;\n" &
    "  esac\n" &
    "done\n" &
    "test \"$pic\" = true\n" &
    "test \"$debug3\" = true\n" &
    "test \"$compile_only\" = true\n" &
    "test -n \"$output\"\n" &
    "test -n \"$source\"\n" &
    "mkdir -p \"$(dirname \"$output\")\"\n" &
    "{\n" &
    "  printf 'source=%s\\n' \"$source\"\n" &
    "  printf 'output=%s\\n' \"$output\"\n" &
    "  printf 'includes=%s\\n' \"$includes\"\n" &
    "  cat \"$source\"\n" &
    "  for include in $includes; do cat \"$include\"; done\n" &
    "} > \"$output\"\n")

proc writeM47TypedCommandProject(path: string) =
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "src")
  createDir(projectRoot / "include")
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m47_gcc.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface m47Gcc, \"m47-gcc\":\n" &
    "  template commonCompileFlags() =\n" &
    "    boolFlag pic is bool, alias = \"-fPIC\"\n" &
    "    boolFlag debug3 is bool, alias = \"-g3\"\n" &
    "    boolFlag compileOnly is bool, alias = \"-c\"\n" &
    "  call:\n" &
    "    commonCompileFlags()\n" &
    "    flag includes is seq[string], alias = \"-include\", role = input, repeated = true\n" &
    "    flag output is string, alias = \"-o\", role = output, required = true\n" &
    "    pos source is string, role = input, position = 0\n")
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m47Project:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m47-gcc >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    m47Gcc(\n" &
    "      actionId = \"compile-main\",\n" &
    "      source = \"src/main.c\",\n" &
    "      output = \"build/main.o\",\n" &
    "      pic = true,\n" &
    "      debug3 = true,\n" &
    "      compileOnly = true,\n" &
    "      includes = @[\"include/config.h\"])\n" &
    "    defaultBuildAction(\"compile-main\")\n")

proc writeM52StylusFixtureTool(binDir: string) =
  writeExecutable(binDir / "m52-stylus",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'm52-stylus 1.0.0'; exit 0; fi\n" &
    "output= source=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    -o) output=$2; shift 2 ;;\n" &
    "    -*) echo \"unknown stylus flag $1\" >&2; exit 64 ;;\n" &
    "    *) source=$1; shift ;;\n" &
    "  esac\n" &
    "done\n" &
    "test -n \"$output\"\n" &
    "test -n \"$source\"\n" &
    "mkdir -p \"$(dirname \"$output\")\"\n" &
    "{ printf '/* %s */\\n' \"$source\"; cat \"$source\"; } > \"$output\"\n")

proc writeM52ForeachStylusProject(path: string) =
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m52_stylus.nim",
    "import repro_project_dsl\n\n" &
    "defineCliInterface stylus, \"m52-stylus\":\n" &
    "  call:\n" &
    "    flag output is string, alias = \"-o\", role = output, required = true\n" &
    "    pos source is string, role = input, position = 0\n")
  writeFile(path,
    "import std/[os]\n" &
    "import repro_project_dsl\n\n" &
    "package m52Styles:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m52-stylus >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    foreach style in dirListing(\"styles\"):\n" &
    "      let name = splitFile(style).name\n" &
    "      stylus(actionId = \"style-\" & name,\n" &
    "        source = style,\n" &
    "        output = \"public/\" & name & \".css\")\n")

proc writeM52StdlibFixtureTools(binDir: string) =
  createDir(binDir)
  let sourcePath = binDir / "m52-stdlib-fixture.c"
  let toolPath = binDir / "m52-stdlib-fixture"
  writeFile(sourcePath, M52StdlibFixtureSource)
  discard requireSuccess(shellCommand(["cc", sourcePath, "-o", toolPath]))
  for name in ["nim", "gcc", "stylus"]:
    copyFile(toolPath, binDir / name)
    setFilePermissions(binDir / name, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeM52StdlibProject(path: string) =
  let projectRoot = path.splitPath.head
  createDir(projectRoot / "src")
  createDir(projectRoot / "styles")
  writeFile(path,
    "import repro_dsl_stdlib\n\n" &
    "package m52Stdlib:\n" &
    "  uses:\n" &
    "    \"nim >=1.6 <3.0\"\n" &
    "    \"gcc >=1\"\n" &
    "    \"stylus >=0\"\n\n" &
    "  build:\n" &
    "    let nimOut = nim.c(\n" &
    "      source = \"src/main.nim\",\n" &
    "      output = \"build/main\")\n" &
    "    let cOut = gcc(\n" &
    "      source = \"src/main.c\",\n" &
    "      output = \"build/main.o\",\n" &
    "      pic = true,\n" &
    "      compileOnly = true)\n" &
    "    let css = stylus(\n" &
    "      source = \"styles/main.styl\",\n" &
    "      output = \"public/main.css\")\n" &
    "    let summary = fs.stamp(\n" &
    "      actionId = \"summary\",\n" &
    "      output = \"dist/summary.txt\",\n" &
    "      title = \"m52 stdlib\",\n" &
    "      entries = @[\"build/main\", \"build/main.o\", \"public/main.css\"],\n" &
    "      inputs = @[\"build/main\", \"build/main.o\", \"public/main.css\"])\n" &
    "    defaultBuildAction(summary)\n")

when defined(macosx) or defined(linux):
  proc writeStylusImportMonitorFixture(binDir: string) =
    writeExecutable(binDir / "stylus",
      "#!/bin/sh\n" &
      "set -eu\n" &
      "if [ \"${1:-}\" = \"--version\" ]; then echo 'stylus fixture 1.0.0'; exit 0; fi\n" &
      "output= source=\n" &
      "while [ \"$#\" -gt 0 ]; do\n" &
      "  case \"$1\" in\n" &
      "    -o) output=$2; shift 2 ;;\n" &
      "    -*) shift ;;\n" &
      "    *) source=$1; shift ;;\n" &
      "  esac\n" &
      "done\n" &
      "test -n \"$output\"\n" &
      "test -n \"$source\"\n" &
      "src_dir=$(dirname \"$source\")\n" &
      "while IFS= read -r line; do\n" &
      "  case \"$line\" in\n" &
      "    '@import \"'*'\"')\n" &
      "      import_name=${line#'@import \"'}\n" &
      "      import_name=${import_name%'\"'}\n" &
      "      cat \"$src_dir/$import_name.styl\" >/dev/null\n" &
      "      ;;\n" &
      "  esac\n" &
      "done < \"$source\"\n" &
      "mkdir -p \"$(dirname \"$output\")\"\n" &
      "{ printf '/* stylus fixture */\\n'; cat \"$source\"; } > \"$output\"\n")

  proc realStylusPathDir(tempRoot: string): string =
    let existing = findExe("stylus")
    if existing.len > 0:
      return existing.splitPath.head
    let npm = findExe("npm")
    if npm.len == 0:
      result = tempRoot / "stylus-fixture-bin"
      createDir(result)
      writeStylusImportMonitorFixture(result)
      return
    let npmRoot = tempRoot / "npm-stylus"
    createDir(npmRoot)
    let res = execCmdEx(shellCommand([
      npm, "install", "--silent", "--no-audit", "--no-fund",
      "--prefix", npmRoot, "stylus@0.64.0"
    ]))
    if res.exitCode != 0:
      return ""
    let candidate = npmRoot / "node_modules" / ".bin" / "stylus"
    if fileExists(candidate):
      return candidate.splitPath.head
    else:
      result = tempRoot / "stylus-fixture-bin"
      createDir(result)
      writeStylusImportMonitorFixture(result)

  proc writeM52StylusMonitorProject(path: string) =
    writeFile(path,
      "import repro_dsl_stdlib\n\n" &
      "package m52StylusMonitor:\n" &
      "  uses:\n" &
      "    \"stylus >=0\"\n\n" &
      "  build:\n" &
      "    let css = stylus(\n" &
      "      actionId = \"style-main\",\n" &
      "      source = \"styles/main.styl\",\n" &
      "      output = \"public/main.css\")\n" &
      "    let aggregate = fs.stamp(\n" &
      "      actionId = \"style-aggregate\",\n" &
      "      output = \"dist/styles.txt\",\n" &
      "      title = \"styles\",\n" &
      "      entries = @[\"public/main.css\"],\n" &
      "      inputs = @[\"public/main.css\"])\n" &
      "    defaultBuildAction(aggregate)\n")

proc writeM53BuiltinFsProject(path: string) =
  createDir(path.splitPath.head)
  writeFile(path,
    "import repro_project_dsl\n\n" &
    "package m53Fs:\n" &
    "  build:\n" &
    "    fs.writeText(actionId = \"write-source\",\n" &
    "      output = \"src/input.txt\",\n" &
    "      text = \"generated input\\n\")\n" &
    "    let outDir = fs.ensureDir(actionId = \"ensure-out\", path = \"out\")\n" &
    "    fs.copyFile(actionId = \"copy-file\",\n" &
    "      source = \"src/input.txt\",\n" &
    "      output = \"out/copy.txt\",\n" &
    "      deps = @[outDir.id])\n" &
    "    let stamp = fs.stamp(actionId = \"stamp\",\n" &
    "      output = \"out/stamp.txt\",\n" &
    "      title = \"builtin fs aggregate\",\n" &
    "      entries = @[\"out/copy.txt\"],\n" &
    "      inputs = @[\"out/copy.txt\"])\n" &
    "    defaultBuildAction(stamp)\n")

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

proc evidenceFile(evidenceRoot, actionId: string): string =
  for kind, path in walkDir(evidenceRoot):
    if kind == pcFile:
      let parts = splitFile(path)
      if parts.ext == ".rbar" and parts.name.startsWith(actionId & "-"):
        return path
  ""

proc build(reproBin, target, repoRoot, pathValue: string;
           env: openArray[(string, string)] = [];
           extraArgs: openArray[string] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  var args = @[reproBin, "build", target, "--tool-provisioning=path"]
  addDefaultTestBuildLog(args, extraArgs)
  for arg in extraArgs:
    args.add(arg)
  requireSuccess(shellCommand(args, entries), repoRoot)

proc buildCurrentProject(reproBin, projectRoot, pathValue: string;
                         env: openArray[(string, string)] = [];
                         extraArgs: openArray[string] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  var args = @[reproBin, "build", "--tool-provisioning=path"]
  addDefaultTestBuildLog(args, extraArgs)
  for arg in extraArgs:
    args.add(arg)
  requireSuccess(shellCommand(args, entries), projectRoot)

proc compilePublicReproTestBin(repoRoot: string): string =
  result = repoRoot / "build" / "test-bin" / "repro"
  createDir(result.splitPath.head)
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" /
      "m35-relative-public-repro",
    "--out:" & result,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)

proc reportAction(report: JsonNode; id: string): JsonNode =
  for item in report{"actions"}:
    if item{"id"}.getStr() == id:
      return item
  newJNull()

proc resetTrace(path: string) =
  if fileExists(path):
    removeFile(path)

suite "e2e_local_reprobuild_project_build":
  when defined(macosx) or defined(linux):
    test "public CLI automatic monitor policy records hidden inputs and invalidates cache":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m32-local-monitor", "")
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
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")

      let binDir = tempRoot / "fixture-bin"
      writeMonitorFixtureTool(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "src")
      createDir(projectRoot / "build")
      writeFile(projectRoot / "src" / "visible.txt", "visible v1\n")
      writeFile(projectRoot / "src" / "hidden.txt", "hidden v1\n")
      writeMonitorProject(projectRoot / "reprobuild.nim")

      let first = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      check first.contains("scheduler: actions=1")
      check first.contains("action: produce status=asSucceeded launched=true")
      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      let firstAction = reportAction(firstReport, "produce")
      check firstAction{"dependencyPolicyKind"}.getStr() == "dgAutomaticMonitor"
      check firstAction{"evidence"}{"monitorReads"}.getElems().
        anyIt(it.getStr().endsWith("src/hidden.txt"))
      check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
        @["producer"]

      let outputV1 = readFile(projectRoot / "build" / "generated.txt")
      let second = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      check second.contains("action: produce status=asCacheHit launched=false")
      check readFile(projectRoot / "build" / "generated.txt") == outputV1
      check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
        @["producer"]

      writeFile(projectRoot / "src" / "hidden.txt", "hidden v2\n")
      let hiddenChanged = build(reproBin, projectRoot, repoRoot, pathValue,
        monitorEnv)
      check hiddenChanged.contains(
        "action: produce status=asSucceeded launched=true")
      check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
        @["producer", "producer"]
      check readFile(projectRoot / "build" / "generated.txt").contains(
        "hidden=hidden v2")

  else:
    test "automatic monitor project CLI E2E is skipped on this platform":
      echo "SKIP: automatic monitor dependency gathering requires preload hooks"

  test "public CLI lowers explicit make depfile policy and rejects incompatible monitor depfile":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m32-policy-lowering", "")
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

    let explicitRoot = tempRoot / "explicit"
    createDir(explicitRoot / "src")
    writeFile(explicitRoot / "src" / "visible.txt", "visible v1\n")
    writeFile(explicitRoot / "src" / "hidden.txt", "hidden v1\n")
    writePolicyProject(explicitRoot / "reprobuild.nim", "makeDepfilePolicy()")

    let explicit = build(reproBin, explicitRoot, repoRoot, pathValue)
    check explicit.contains("action: produce status=asSucceeded launched=true")
    let explicitReport = parseFile(valueAfter(explicit, "buildReport:"))
    let explicitAction = reportAction(explicitReport, "produce")
    check explicitAction{"dependencyPolicyKind"}.getStr() == "dgRecognizedFormat"
    check explicitAction{"evidence"}{"depfileInputs"}.getElems().
      anyIt(it.getStr().endsWith("src/hidden.txt"))

    let invalidRoot = tempRoot / "invalid"
    createDir(invalidRoot / "src")
    writeFile(invalidRoot / "src" / "visible.txt", "visible v1\n")
    writeFile(invalidRoot / "src" / "hidden.txt", "hidden v1\n")
    writePolicyProject(invalidRoot / "reprobuild.nim", "automaticMonitorPolicy()")

    let invalid = requireFailure(shellCommand([reproBin, "build", invalidRoot,
      "--tool-provisioning=path"], [("PATH", pathValue)]), repoRoot)
    check invalid.contains("supplies legacy depfile and automatic monitor")
    check invalid.contains("remove depfile or use makeDepfilePolicy")

  test "public CLI selects an in-place project action and builds only its dependency closure":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m30-local-target-selection", "")
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

    let selected = build(reproBin, projectRoot & "#consume", repoRoot, pathValue)
    check selected.contains("selectedTarget: consume")
    check selected.contains("scheduler: actions=2")
    check selected.contains("action: produce status=asSucceeded launched=true")
    check selected.contains("action: consume status=asSucceeded launched=true")
    check not selected.contains("action: unrelated")
    check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
      @["producer", "consumer"]
    check nonEmptyLines(projectRoot / ".repro" / "tool-runs-unrelated.log").len == 0
    check fileExists(projectRoot / "build" / "generated.txt")
    check fileExists(projectRoot / "dist" / "final.txt")
    check not fileExists(projectRoot / "dist" / "unrelated.txt")

    let selectedReport = parseFile(valueAfter(selected, "buildReport:"))
    check selectedReport{"actions"}.len == 2
    check reportAction(selectedReport, "produce"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(selectedReport, "consume"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(selectedReport, "unrelated").kind == JNull

    let unknown = requireFailure("PATH=" & q(pathValue) & " " &
      shellCommand([reproBin, "build", projectRoot & "#does-not-exist",
        "--tool-provisioning=path"]), repoRoot)
    check unknown.contains("unknown build target/action id: does-not-exist")
    check unknown.contains("available:")
    check unknown.contains("consume")

  test "public CLI no-target build uses current project default action":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m45-local-default-build", "")
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

    let selected = buildCurrentProject(reproBin, projectRoot, pathValue)
    check selected.contains("defaultTarget: consume")
    check selected.contains("selectedTarget: consume")
    check selected.contains("scheduler: actions=2")
    check selected.contains("action: produce status=asSucceeded launched=true")
    check selected.contains("action: consume status=asSucceeded launched=true")
    check not selected.contains("action: unrelated")
    check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
      @["producer", "consumer"]
    check nonEmptyLines(projectRoot / ".repro" / "tool-runs-unrelated.log").len == 0
    check fileExists(projectRoot / "build" / "generated.txt")
    check fileExists(projectRoot / "dist" / "final.txt")
    check not fileExists(projectRoot / "dist" / "unrelated.txt")

    let selectedReport = parseFile(valueAfter(selected, "buildReport:"))
    check selectedReport{"actions"}.len == 2
    check reportAction(selectedReport, "produce"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(selectedReport, "consume"){"status"}.getStr() ==
      "asSucceeded"
    check reportAction(selectedReport, "unrelated").kind == JNull

  test "uses import path exposes typed tool package and declared paths infer dependency closure":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m46-uses-import-path", "")
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
    writeM46FixtureTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    writeM46ImportedPackageProject(projectRoot / "reprobuild.nim")
    writeFile(projectRoot / "src" / "input.txt", "v1\n")

    let selected = build(reproBin, projectRoot & "#consume", repoRoot, pathValue)
    check selected.contains("selectedTarget: consume")
    check selected.contains("scheduler: actions=2")
    check selected.contains("action: produce status=asSucceeded launched=true")
    check selected.contains("action: consume status=asSucceeded launched=true")
    check not selected.contains("action: direct")
    check nonEmptyLines(projectRoot / ".repro" / "m46-tool-runs.log") ==
      @["produce", "consume"]
    check readFile(projectRoot / "dist" / "final.txt").contains("produced:v1")

    let report = parseFile(valueAfter(selected, "buildReport:"))
    check report{"actions"}.len == 2
    check reportAction(report, "produce"){"status"}.getStr() == "asSucceeded"
    check reportAction(report, "consume"){"status"}.getStr() == "asSucceeded"
    check reportAction(report, "direct").kind == JNull

    let direct = build(reproBin, projectRoot & "#direct", repoRoot, pathValue)
    check direct.contains("selectedTarget: direct")
    check direct.contains("scheduler: actions=1")
    check direct.contains("action: direct status=asSucceeded launched=true")
    check readFile(projectRoot / "dist" / "direct.txt") == "direct\n"

  test "uses import path is opt-in for imported package helpers":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m46-no-implicit-import", "")
    defer: removeDir(tempRoot)

    let projectRoot = tempRoot / "project"
    writeM46ProjectWithoutImportPath(projectRoot / "reprobuild.nim")
    writeFile(projectRoot / "src" / "input.txt", "v1\n")

    let output = requireFailure(shellCommand([
      "nim", "check", "--verbosity:0", "--hints:off",
      "--path:" & repoRoot / "libs" / "repro_project_dsl" / "src",
      projectRoot / "reprobuild.nim"
    ]), projectRoot)
    check output.contains("m46Tool")

  test "generated tool object records action and path roles without buildAction":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m47-typed-command-action", "")
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
    writeM47GccFixtureTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    writeM47TypedCommandProject(projectRoot / "reprobuild.nim")
    writeFile(projectRoot / "src" / "main.c", "int main(void) { return 0; }\n")
    writeFile(projectRoot / "include" / "config.h", "#define CONFIG_VALUE 1\n")

    let projectText = readFile(projectRoot / "reprobuild.nim")
    check not projectText.contains("buildAction")
    check not projectText.contains("inputs =")
    check not projectText.contains("outputs =")

    let output =
      when defined(macosx) or defined(linux):
        let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
        let monitorEnv = [
          ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
          ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
        ]
        buildCurrentProject(reproBin, projectRoot, pathValue, monitorEnv)
      else:
        buildCurrentProject(reproBin, projectRoot, pathValue)
    check output.contains("defaultTarget: compile-main")
    check output.contains("selectedTarget: compile-main")
    check output.contains("scheduler: actions=1")
    check output.contains("action: compile-main status=asSucceeded launched=true")
    check readFile(projectRoot / "build" / "main.o").contains(
      "includes=include/config.h")

    let report = parseFile(valueAfter(output, "buildReport:"))
    let action = reportAction(report, "compile-main")
    check action{"status"}.getStr() == "asSucceeded"
    check action{"evidence"}{"declaredInputs"}.getElems().
      anyIt(it.getStr().endsWith("src/main.c"))
    check action{"evidence"}{"declaredInputs"}.getElems().
      anyIt(it.getStr().endsWith("include/config.h"))
    check action{"evidence"}{"declaredOutputs"}.getElems().
      anyIt(it.getStr() == "build/main.o")

  test "m52_stdlib_package_import_e2e":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m52-stdlib-packages", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = compilePublicReproTestBin(repoRoot)
    when defined(macosx) or defined(linux):
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
    else:
      let monitorEnv: seq[(string, string)] = @[]
    let binDir = tempRoot / "bin"
    writeM52StdlibFixtureTools(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    writeM52StdlibProject(projectRoot / "reprobuild.nim")
    writeFile(projectRoot / "src" / "main.nim", "echo \"m52\"\n")
    writeFile(projectRoot / "src" / "main.c", "int main(void) { return 0; }\n")
    writeFile(projectRoot / "styles" / "main.styl", "body\n  color #123\n")

    let projectText = readFile(projectRoot / "reprobuild.nim")
    check not projectText.contains("usesImportPath")
    check not projectText.contains("defineCliInterface")
    check not dirExists(projectRoot / "reprobuild" / "packages")

    let output = buildCurrentProject(reproBin, projectRoot, pathValue,
      monitorEnv)
    check output.contains("defaultTarget: summary")
    check output.contains("scheduler: actions=4")
    check output.contains("action: summary status=asSucceeded launched=true")
    check readFile(projectRoot / "build" / "main").contains("nim:c:src/main.nim")
    check readFile(projectRoot / "build" / "main.o").contains(
      "gcc:src/main.c:yes:yes")
    check fileExists(projectRoot / "public" / "main.css")

    let identity = readPathOnlyBuildIdentity(valueAfter(output, "toolIdentity:"))
    check identity.profiles.len == 3
    check identity.profiles.anyIt(it.executableName == "nim")
    check identity.profiles.anyIt(it.executableName == "gcc")
    check identity.profiles.anyIt(it.executableName == "stylus")

    let report = parseFile(valueAfter(output, "buildReport:"))
    check reportAction(report, "summary"){"runQuotaBackend"}.getStr() == "builtin"
    let expectedStylusPolicy =
      when defined(macosx) or defined(linux) or defined(windows):
        "dgAutomaticMonitor"
      else:
        "dgDeclaredOnly"
    check report{"actions"}.getElems().anyIt(
      it{"id"}.getStr().startsWith("stylus-") and
      it{"dependencyPolicyKind"}.getStr() == expectedStylusPolicy)

  when defined(macosx) or defined(linux):
    test "m52_stylus_import_monitoring_e2e":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m52-stylus-monitor", "")
      defer: removeDir(tempRoot)

      let stylusDir = realStylusPathDir(tempRoot)
      check stylusDir.len > 0

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let reproBin = compilePublicReproTestBin(repoRoot)
      let monitorTools = prepareMonitorTools(repoRoot, tempRoot / "monitor")
      let monitorEnv = [
        ("REPRO_FS_SNOOP", monitorTools.fsSnoop),
        ("REPRO_MONITOR_SHIM_LIB", monitorTools.shim)
      ]
      let pathValue = stylusDir & $PathSep & getEnv("PATH")

      let projectRoot = tempRoot / "project"
      createDir(projectRoot / "styles")
      writeM52StylusMonitorProject(projectRoot / "reprobuild.nim")
      writeFile(projectRoot / "styles" / "palette.styl",
        "primary = #123456\n")
      writeFile(projectRoot / "styles" / "main.styl",
        "@import \"palette\"\nbody\n  color primary\n")

      let first = buildCurrentProject(reproBin, projectRoot, pathValue,
        monitorEnv)
      check first.contains("scheduler: actions=2")
      check first.contains("action: style-main status=asSucceeded launched=true")
      check first.contains(
        "action: style-aggregate status=asSucceeded launched=true")
      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      let styleMain = reportAction(firstReport, "style-main")
      check styleMain{"dependencyPolicyKind"}.getStr() == "dgAutomaticMonitor"
      check styleMain{"evidence"}{"monitorReads"}.getElems().
        anyIt(it.getStr().endsWith("styles/palette.styl"))

      let second = buildCurrentProject(reproBin, projectRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      check reportAction(secondReport, "style-main"){"status"}.getStr() ==
        "asCacheHit"
      check reportAction(secondReport, "style-aggregate"){"status"}.getStr() ==
        "asCacheHit"

      writeFile(projectRoot / "styles" / "palette.styl",
        "primary = #654321\n")
      let changed = buildCurrentProject(reproBin, projectRoot, pathValue,
        monitorEnv)
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      check reportAction(changedReport, "style-main"){"status"}.getStr() ==
        "asSucceeded"
      check reportAction(changedReport, "style-aggregate"){"status"}.getStr() ==
        "asSucceeded"

  test "standard filesystem operations lower to built-in build actions":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m53-builtin-fs", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let projectRoot = tempRoot / "project"
    writeM53BuiltinFsProject(projectRoot / "reprobuild.nim")
    let output = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"))
    check output.contains("defaultTarget: stamp")
    check output.contains(
      "providerCompileAction: __repro_provider_compile status=asSucceeded launched=true")
    check output.contains("scheduler: actions=4")
    check output.contains("action: write-source status=asSucceeded launched=true")
    check output.contains("action: ensure-out status=asSucceeded launched=true")
    check output.contains("action: copy-file status=asSucceeded launched=true")
    check output.contains("action: stamp status=asSucceeded launched=true")
    check readFile(projectRoot / "out" / "copy.txt") == "generated input\n"
    check readFile(projectRoot / "out" / "stamp.txt") ==
      "builtin fs aggregate\nout/copy.txt\n"

    let report = parseFile(valueAfter(output, "buildReport:"))
    check reportAction(report, "write-source"){"runQuotaBackend"}.getStr() ==
      "builtin"
    check reportAction(report, "copy-file"){"evidence"}{"declaredInputs"}.
      getElems().anyIt(it.getStr().endsWith("src/input.txt"))
    check reportAction(report, "stamp"){"evidence"}{"declaredOutputs"}.
      getElems().anyIt(it.getStr() == "out/stamp.txt")

    let progressOutput = buildCurrentProject(reproBin, projectRoot,
      getEnv("PATH"), extraArgs = ["--progress=bar-line"])
    check not progressOutput.contains(
      "providerCompileAction: __repro_provider_compile")
    check progressOutput.contains("repro check[")
    check progressOutput.contains("checked=4/4 100%")

    let quietOutput = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"),
      extraArgs = ["--progress=quiet", "--report=none"])
    check quietOutput.strip() == ""

    let diagnosticsPath = projectRoot / ".repro" / "progress-diagnostics.log"
    let quietDiagnosticsOutput = buildCurrentProject(reproBin, projectRoot,
      getEnv("PATH"), extraArgs = ["--progress=quiet", "--report=none",
        "--diagnostics=" & diagnosticsPath])
    check quietDiagnosticsOutput.strip() == ""
    let diagnostics = readFile(diagnosticsPath)
    check diagnostics.contains("scheduler: actions=4")
    check diagnostics.contains("action: stamp status=")

    let dotsOutput = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"),
      extraArgs = ["--progress=dots", "--log=quiet", "--report=none"])
    check dotsOutput.contains("....")

    let statsOutput = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"),
      extraArgs = ["--stats"])
    check statsOutput.contains("metric")
    check statsOutput.contains("count")
    check statsOutput.contains("avg (us)")
    check statsOutput.contains("total (ms)")
    check statsOutput.contains("repro build total")
    check statsOutput.contains("repro scheduler total")
    check not statsOutput.contains("repro runquota probe")
    let statsReport = parseFile(valueAfter(statsOutput, "buildReport:"))
    check statsReport{"stats"}{"metrics"}.getElems().anyIt(
      it{"name"}.getStr() == "repro build total")
    check statsReport{"stats"}{"metrics"}.getElems().anyIt(
      it{"name"}.getStr() == "repro scheduler total")
    check not statsReport{"stats"}{"metrics"}.getElems().anyIt(
      it{"name"}.getStr() == "repro runquota probe")
    let providerCompileActions = statsReport{"providerCompileActions"}.getElems()
    check providerCompileActions.len == 0

  test "provider compile fast path skips no-op and invalidates provider sources":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m55-provider-fast-path", "")
    defer: removeDir(tempRoot)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let projectRoot = tempRoot / "project"
    let modulePath = projectRoot / "reprobuild.nim"
    writeM53BuiltinFsProject(modulePath)

    let first = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"))
    check first.contains(
      "providerCompileAction: __repro_provider_compile status=asSucceeded launched=true")

    let second = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"))
    check not second.contains(
      "providerCompileAction: __repro_provider_compile")
    let secondReport = parseFile(valueAfter(second, "buildReport:"))
    check secondReport{"providerCompileActions"}.getElems().len == 0

    writeFile(modulePath, readFile(modulePath) &
      "\n# private provider implementation salt one\n")
    let changed = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"))
    check changed.contains(
      "providerCompileAction: __repro_provider_compile status=asSucceeded launched=true")

    writeFile(projectRoot / "provider_extra.nim",
      "const providerExtraSalt* = \"added-source\"\n")
    let added = buildCurrentProject(reproBin, projectRoot, getEnv("PATH"))
    check added.contains(
      "providerCompileAction: __repro_provider_compile status=asSucceeded launched=true")

  test "public CLI work root override isolates metadata by worktree":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m54-work-root", "")
    defer: removeDir(tempRoot)

    let reproBin = compilePublicReproTestBin(repoRoot)
    let sharedWorkRoot = tempRoot / "shared-work"
    let projectA = tempRoot / "a" / "project"
    let projectB = tempRoot / "b" / "project"
    writeM53BuiltinFsProject(projectA / "reprobuild.nim")
    writeM53BuiltinFsProject(projectB / "reprobuild.nim")

    let outputA = build(reproBin, projectA, repoRoot, getEnv("PATH"),
      extraArgs = ["--work-root=" & sharedWorkRoot])
    let outputB = build(reproBin, projectB, repoRoot, getEnv("PATH"),
      extraArgs = ["--work-root=" & sharedWorkRoot])

    let interfaceA = valueAfter(outputA, "interface:")
    let interfaceB = valueAfter(outputB, "interface:")
    check interfaceA.startsWith(sharedWorkRoot & DirSep)
    check interfaceB.startsWith(sharedWorkRoot & DirSep)
    check interfaceA != interfaceB
    check interfaceA.parentDir != interfaceB.parentDir
    check fileExists(interfaceA)
    check fileExists(interfaceB)
    check not dirExists(projectA / ".repro" / "build")
    check not dirExists(projectB / ".repro" / "build")

  test "relative public CLI keeps RunQuota helper path stable across project cwd":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m35-relative-public-cli", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    discard compilePublicReproTestBin(repoRoot)

    let binDir = tempRoot / "bin"
    writeFixtureTools(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src")
    writeFile(projectRoot / "src" / "visible.txt", "visible v1\n")
    writeFile(projectRoot / "src" / "hidden.txt", "hidden v1\n")
    writeFile(projectRoot / "src" / "unrelated.txt", "unrelated v1\n")
    writeProject(projectRoot / "reprobuild.nim")

    let selected = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", projectRoot & "#consume",
      "--tool-provisioning=path", "--log=actions"
    ], [("PATH", pathValue)]), repoRoot)
    check selected.contains("selectedTarget: consume")
    check selected.contains("scheduler: actions=2")
    check selected.contains("action: produce status=asSucceeded launched=true")
    check selected.contains("action: consume status=asSucceeded launched=true")
    check selected.contains("runquota=")
    check nonEmptyLines(projectRoot / ".repro" / "tool-runs.log") ==
      @["producer", "consumer"]
    let report = parseFile(valueAfter(selected, "buildReport:"))
    check reportAction(report, "produce"){"runQuotaBackend"}.getStr().len > 0
    check reportAction(report, "consume"){"runQuotaBackend"}.getStr().len > 0

  test "public CLI reruns provider root for DSL directory enumeration inputs":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m40-directory-dsl", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    discard compilePublicReproTestBin(repoRoot)

    let binDir = tempRoot / "bin"
    writeFixtureTools(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "src" / "resources")
    writeFile(projectRoot / "src" / "aggregate.txt", "aggregate\n")
    writeFile(projectRoot / "src" / "resources" / "alpha.txt", "alpha\n")
    writeFile(projectRoot / "src" / "resources" / "beta.txt", "beta\n")
    writeDirectoryEnumerationProject(projectRoot / "reprobuild.nim")

    let target = projectRoot & "#aggregate"
    let first = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], [("PATH", pathValue)]), repoRoot)
    check first.contains("selectedTarget: aggregate")
    check first.contains("providerInvocations: 1")
    check first.contains("scheduler: actions=3")
    check first.contains("action: copy-alpha.txt status=asSucceeded launched=true")
    check first.contains("action: copy-beta.txt status=asSucceeded launched=true")
    check fileExists(projectRoot / "dist" / "alpha.txt.out")
    check fileExists(projectRoot / "dist" / "beta.txt.out")
    check readFile(projectRoot / "dist" / "alpha.txt.out") == "alpha\n"

    writeFile(projectRoot / "src" / "resources" / "gamma.txt", "gamma\n")
    let added = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], [("PATH", pathValue)]), repoRoot)
    check added.contains("providerInvocations: 1")
    check added.contains("scheduler: actions=4")
    check added.contains("action: copy-gamma.txt status=asSucceeded launched=true")
    check fileExists(projectRoot / "dist" / "gamma.txt.out")
    check readFile(projectRoot / "dist" / "gamma.txt.out") == "gamma\n"

    removeFile(projectRoot / "src" / "resources" / "beta.txt")
    let removed = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], [("PATH", pathValue)]), repoRoot)
    check removed.contains("providerInvocations: 1")
    check removed.contains("scheduler: actions=3")
    check not removed.contains("action: copy-beta.txt")
    let removedReport = parseFile(valueAfter(removed, "buildReport:"))
    check removedReport{"actions"}.len == 3
    check reportAction(removedReport, "copy-alpha.txt").kind != JNull
    check reportAction(removedReport, "copy-gamma.txt").kind != JNull
    check reportAction(removedReport, "copy-beta.txt").kind == JNull

  test "provider foreach refreshes only changed directory members":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m52-provider-foreach", "")
    defer: removeDir(tempRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    discard compilePublicReproTestBin(repoRoot)

    let binDir = tempRoot / "bin"
    writeM52StylusFixtureTool(binDir)
    let pathValue = binDir & $PathSep & getEnv("PATH")

    let projectRoot = tempRoot / "project"
    createDir(projectRoot / "styles")
    writeFile(projectRoot / "styles" / "alpha.styl", "alpha-v1\n")
    writeFile(projectRoot / "styles" / "beta.styl", "beta-v1\n")
    writeM52ForeachStylusProject(projectRoot / "reprobuild.nim")
    let tracePath = tempRoot / "provider.trace"
    let target = projectRoot
    let traceEnv = [("PATH", pathValue), ("REPRO_PROVIDER_TRACE", tracePath)]

    let first = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], traceEnv), repoRoot)
    check first.contains("providerInvocations: 3")
    check first.contains("scheduler: actions=2")
    check first.contains("action: style-alpha status=asSucceeded launched=true")
    check first.contains("action: style-beta status=asSucceeded launched=true")
    let firstTrace = nonEmptyLines(tracePath)
    check firstTrace.anyIt(it.contains("prkGraphInvocation|m52Styles.root|"))
    check firstTrace.anyIt(it.contains("alpha.styl|girNoPriorFragment"))
    check firstTrace.anyIt(it.contains("beta.styl|girNoPriorFragment"))

    resetTrace(tracePath)
    let second = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], traceEnv), repoRoot)
    check second.contains("providerInvocations: 0")
    check second.contains("action: style-alpha status=asCacheHit launched=false")
    check second.contains("action: style-beta status=asCacheHit launched=false")
    check nonEmptyLines(tracePath).len == 0

    writeFile(projectRoot / "styles" / "alpha.styl", "alpha-v2\n")
    resetTrace(tracePath)
    let contentChanged = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], traceEnv), repoRoot)
    check contentChanged.contains("providerInvocations: 0")
    check contentChanged.contains(
      "action: style-alpha status=asSucceeded launched=true")
    check contentChanged.contains(
      "action: style-beta status=asCacheHit launched=false")
    check readFile(projectRoot / "public" / "alpha.css").contains("alpha-v2")
    check nonEmptyLines(tracePath).len == 0

    writeFile(projectRoot / "styles" / "gamma.styl", "gamma-v1\n")
    resetTrace(tracePath)
    let added = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], traceEnv), repoRoot)
    check added.contains("providerInvocations: 1")
    check added.contains("scheduler: actions=3")
    check added.contains("action: style-gamma status=asSucceeded launched=true")
    let addedTrace = nonEmptyLines(tracePath)
    check addedTrace.len == 1
    check addedTrace[0].contains("prkGraphInvocation|m52Styles.foreach.0.style|")
    check addedTrace[0].contains("gamma.styl|girDirectoryMembershipChanged")

    removeFile(projectRoot / "styles" / "beta.styl")
    resetTrace(tracePath)
    let removed = requireSuccess(shellCommand([
      "build/test-bin/repro", "build", target, "--tool-provisioning=path",
      "--log=actions"
    ], traceEnv), repoRoot)
    check removed.contains("providerInvocations: 0")
    check removed.contains("scheduler: actions=2")
    check not removed.contains("action: style-beta")
    let removedReport = parseFile(valueAfter(removed, "buildReport:"))
    check reportAction(removedReport, "style-alpha").kind != JNull
    check reportAction(removedReport, "style-gamma").kind != JNull
    check reportAction(removedReport, "style-beta").kind == JNull
    check nonEmptyLines(tracePath).len == 0

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
    let evidenceRoot = projectRoot / ".repro" / "build" / "reprobuild" /
      "build-engine-cache" / "dependency-evidence"
    for actionId in ["produce", "consume", "unrelated"]:
      let evidencePath = evidenceFile(evidenceRoot, actionId)
      check evidencePath.len > 0
      check fileExists(evidencePath)
      check readFile(evidencePath)[0 .. 3] == "RBAR"

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
