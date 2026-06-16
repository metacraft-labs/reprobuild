import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles
from repro_test_support import requireBinary, monitorShimPath

const GccProxySource = r"""
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *default_real_gcc = "@REAL_GCC_PATH@";

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
#if defined(__APPLE__)
  unsetenv("DYLD_INSERT_LIBRARIES");
  /* /usr/bin/gcc honours DEVELOPER_DIR and dispatches via xcrun, whose
     SDK bin lacks gcc and falls back to PATH — re-finding this proxy
     and looping until kern.maxprocperuid is exhausted. Strip the SDK
     pointers so the underlying gcc uses its built-in SDK lookup. */
  unsetenv("DEVELOPER_DIR");
  unsetenv("SDKROOT");
#elif defined(__linux__)
  unsetenv("LD_PRELOAD");
  unsetenv("REPRO_MONITOR_SHIM_LIB");
#endif
  char **next_argv = calloc((size_t)argc + 1, sizeof(char *));
  if (next_argv == NULL) return 126;
  next_argv[0] = (char *)default_real_gcc;
  for (int i = 1; i < argc; i++) next_argv[i] = argv[i];
  execv(default_real_gcc, next_argv);
  perror("execv real gcc");
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

const CodeTracerCommonDevToolExecutables: seq[string] = @[
  "bash",
  "cachix",
  "capnp",
  "cargo",
  "cargo-nextest",
  "clang",
  "create-dmg",
  "ctags",
  "curl",
  "electron",
  "emcc",
  "flake8",
  "nim",
  "nimble",
  "node",
  "npx",
  "gcc",
  "gh",
  "git",
  "just",
  "llvm-config",
  "mdbook",
  "nix",
  "openssl",
  "pcre-config",
  "pkg-config",
  "playwright",
  "python3",
  "rg",
  "ruby",
  "rust-analyzer",
  "rustc",
  "rustfmt",
  "rustup",
  "sh",
  "shellcheck",
  "sqlite3",
  "stylus",
  "tmux",
  "tree-sitter",
  "vim",
  "wasm-opt",
  "wasm-pack",
  "webpack-cli",
  "wget",
  "yarn",
  "zstd"
]

when not defined(macosx):
  const CodeTracerTupToolExecutables: seq[string] = @["tup"]
else:
  const CodeTracerTupToolExecutables: seq[string] = @[]

when defined(linux):
  const CodeTracerDevToolExecutables: seq[string] =
    CodeTracerCommonDevToolExecutables & CodeTracerTupToolExecutables & @[
    "bpftrace",
    "bpftool",
    "dpkg",
    "xdotool",
    "xvfb-run"
  ]
else:
  const CodeTracerDevToolExecutables: seq[string] =
    CodeTracerCommonDevToolExecutables & CodeTracerTupToolExecutables

const IsonimAsyncCompatFixtureSource = r"""
when defined(js):
  import std/asyncjs

  export asyncjs

  type PlatformFuture*[T] = Future[T]

  proc isSyncResolved*(future: PlatformFuture): bool =
    var resolved: bool
    {.emit: "`resolved` = (`future`.__syncResolved === true);".}
    resolved

  proc isSyncFailed*(future: PlatformFuture): bool =
    var failed: bool
    {.emit: "`failed` = (`future`.__syncFailed === true);".}
    failed

  proc getSyncValue*[T](future: PlatformFuture[T]): T =
    var value: T
    {.emit: "`value` = `future`.__syncValue;".}
    value

  proc getSyncError*(future: PlatformFuture): string =
    var message: string
    {.emit: "`message` = `future`.__syncError;".}
    message

  proc newCompletedFuture*[T](value: T): PlatformFuture[T] =
    result = newPromise(proc(resolve: proc(response: T)) =
      resolve(value))
    {.emit: "`result`.__syncResolved = true; `result`.__syncValue = `value`;".}

  proc newCompletedFuture*(): PlatformFuture[void] =
    result = newPromise(proc(resolve: proc()) =
      resolve())
    {.emit: "`result`.__syncResolved = true;".}

  proc newFailedFuture*[T](message: string): PlatformFuture[T] =
    result = newPromise proc(resolve: proc(value: T)) =
      raise newException(CatchableError, message)
    {.emit: "`result`.__syncFailed = true; `result`.__syncError = `message`; `result`.catch(function(){});".}

  proc attachPromiseHandlers[T](future: PlatformFuture[T];
      onSuccess: proc(value: T); onError: proc(message: cstring))
      {.importjs: "#.then(#).catch(function(err) { #(String(err && err.message || err)); })".}

  proc attachPromiseHandlers(future: PlatformFuture[void];
      onSuccess: proc(); onError: proc(message: cstring))
      {.importjs: "#.then(#).catch(function(err) { #(String(err && err.message || err)); })".}

  proc onComplete*[T](future: PlatformFuture[T]; onSuccess: proc(value: T);
                      onError: proc(message: string) = nil) =
    proc reject(message: cstring) =
      if onError != nil:
        onError($message)
    attachPromiseHandlers(future, onSuccess, reject)

  proc onComplete*(future: PlatformFuture[void]; onSuccess: proc();
                   onError: proc(message: string) = nil) =
    proc reject(message: cstring) =
      if onError != nil:
        onError($message)
    attachPromiseHandlers(future, onSuccess, reject)
else:
  import std/asyncdispatch

  export asyncdispatch

  type PlatformFuture*[T] = Future[T]

  proc newCompletedFuture*[T](value: T): PlatformFuture[T] =
    result = newFuture[T]("isonim.async_compat.newCompletedFuture")
    result.complete(value)

  proc newCompletedFuture*(): PlatformFuture[void] =
    result = newFuture[void]("isonim.async_compat.newCompletedFuture")
    result.complete()

  proc newFailedFuture*[T](message: string): PlatformFuture[T] =
    result = newFuture[T]("isonim.async_compat.newFailedFuture")
    result.fail(newException(CatchableError, message))

  proc onComplete*[T](future: PlatformFuture[T]; onSuccess: proc(value: T);
                      onError: proc(message: string) = nil) =
    future.callback = proc(completed: Future[T]) =
      if completed.failed:
        if onError != nil:
          onError(completed.error.msg)
      else:
        onSuccess(completed.read())

  proc onComplete*(future: PlatformFuture[void]; onSuccess: proc();
                   onError: proc(message: string) = nil) =
    future.callback = proc(completed: Future[void]) =
      if completed.failed:
        if onError != nil:
          onError(completed.error.msg)
      else:
        onSuccess()
"""

const IsonimHmrComponentFixtureSource = r"""
template uiComponent*() {.pragma.}
"""

const IsonimHmrFixtureSource = r"""
import isonim/web/dom_api

type HmrRenderFactory* = proc(): Node {.closure.}

proc mountUiHot*(container: Element; factory: HmrRenderFactory): Node =
  result = factory()
  if result != nil:
    discard appendChild(Node(container), result)

proc mountUiHot*(container: Node; factory: HmrRenderFactory): Node =
  result = factory()
  if result != nil:
    discard appendChild(container, result)

proc hmrRegisterFactory*[Slot, Hash, Factory](slot: Slot; hash: Hash;
    factory: Factory) =
  discard

proc bootstrapHmr*() =
  discard

proc registrySize*(): int = 0

proc currentGeneration*(): int = 0
"""

const IsonimHmrLiveReloadFixtureSource = r"""
type LiveReloadTransport* = ref object

proc installLiveReloadTransport*(url, bundleUrl: cstring): LiveReloadTransport =
  nil

proc disconnect*(transport: LiveReloadTransport) =
  discard
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

# Test-Fixtures-In-Build-Graph M1/M3: ``repro`` is a graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``); the same consolidated image
# also serves the fs-snoop role (``repro internal fs-snoop``). Assert the graph
# artifact exists instead of recompiling ``apps/repro/repro.nim`` at test
# runtime.
proc compilePublicReproTestBin(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

when defined(macosx) or defined(linux):
  proc prepareMonitorTools(repoRoot, tempRoot: string): tuple[fsSnoop: string;
      shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    # Test-Fixtures-In-Build-Graph M3: the fs-snoop driver is the graph-built
    # ``build/bin/repro`` (reached via ``repro internal fs-snoop``); ``repro``
    # honors ``REPRO_FS_SNOOP`` pointing at this consolidated image. Assert it
    # exists instead of compiling a standalone wrapper at test runtime.
    result.fsSnoop = requireBinary(
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
      "reprobuild.apps.repro")
    # Test-Fixtures-In-Build-Graph M2: assert the graph-built monitor shim
    # (edge ``reprobuild.test_fixtures.monitor_shim``) instead of compiling one
    # per test. The host-native single-arch shim is correct: the test process is
    # host-arch, so the former universal (lipo) build is unnecessary.
    result.shim = requireBinary(monitorShimPath(repoRoot),
      "reprobuild.test_fixtures.monitor_shim")

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
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

proc prepareIsonimFixture(sourcePath, destPath: string) =
  createDir(destPath)
  if dirExists(sourcePath / "src"):
    copyTree(sourcePath / "src", destPath / "src")
  for fileName in ["isonim.nimble", "nim.cfg"]:
    let sourceFile = sourcePath / fileName
    if fileExists(sourceFile):
      copyFile(sourceFile, destPath / fileName)
  createDir(destPath / "src" / "isonim" / "core")
  writeFile(destPath / "src" / "isonim" / "core" / "async_compat.nim",
    IsonimAsyncCompatFixtureSource)
  createDir(destPath / "src" / "isonim" / "web")
  writeFile(destPath / "src" / "isonim" / "web" / "hmr_component.nim",
    IsonimHmrComponentFixtureSource)
  writeFile(destPath / "src" / "isonim" / "web" / "hmr.nim",
    IsonimHmrFixtureSource)
  writeFile(destPath / "src" / "isonim" / "web" / "hmr_livereload.nim",
    IsonimHmrLiveReloadFixtureSource)
  let uiDslPath = destPath / "src" / "isonim" / "dsl" / "ui.nim"
  if fileExists(uiDslPath):
    let original = "  else:\n    result = node.strVal\n"
    let replacement =
      "  of nnkIdent, nnkSym:\n" &
      "    result = node.strVal\n" &
      "  else:\n" &
      "    result = node.repr\n"
    let accQuotedOriginal =
      "  of nnkAccQuoted:\n" &
      "    result = \"\"\n" &
      "    for child in node:\n" &
      "      result.add child.strVal\n"
    let accQuotedReplacement =
      "  of nnkAccQuoted:\n" &
      "    result = \"\"\n" &
      "    for child in node:\n" &
      "      case child.kind\n" &
      "      of nnkIdent, nnkSym:\n" &
      "        result.add child.strVal\n" &
      "      else:\n" &
      "        result.add child.repr\n"
    let refOriginal =
      "        if isEventHandler(attrName):\n" &
      "          # Event handler: onclick = proc() = ...\n"
    let refReplacement =
      "        if attrName == \"ref\":\n" &
      "          stmts.add(newAssignment(attrVal, elSym))\n" &
      "        elif isEventHandler(attrName):\n" &
      "          # Event handler: onclick = proc() = ...\n"
    writeFile(uiDslPath, readFile(uiDslPath).
      replace(accQuotedOriginal, accQuotedReplacement).
      replace(original, replacement).
      replace(refOriginal, refReplacement))
  let mockDomPath = destPath / "src" / "isonim" / "testing" / "mock_dom.nim"
  if fileExists(mockDomPath):
    let mockDomText = readFile(mockDomPath)
    if not mockDomText.contains("proc inputValue*"):
      writeFile(mockDomPath, mockDomText &
        "\nproc inputValue*(r: MockRenderer; node: MockNode): string =\n" &
        "  if node != nil and \"value\" in node.attributes:\n" &
        "    node.attributes[\"value\"]\n" &
        "  else:\n" &
        "    \"\"\n")
  createDir(destPath / "build")
  let tailwindStyles = destPath / "build" / "tailwind-styles.json"
  if not fileExists(tailwindStyles):
    writeFile(tailwindStyles, "{}\n")

proc linkCodeTracerSiblingDeps(codeTracerRoot, projectRoot: string) =
  for dep in ["isonim", "nim-everywhere"]:
    let sourcePath = codeTracerRoot.parentDir / dep
    let destPath = projectRoot.parentDir / dep
    if dirExists(sourcePath) and not pathExists(destPath):
      if dep == "isonim":
        prepareIsonimFixture(sourcePath, destPath)
      else:
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
  createDir(projectRoot / "src")
  copyFile(codeTracerRoot / "src" / "helpers.js", projectRoot / "helpers.js")
  copyFile(codeTracerRoot / "src" / "helpers.js",
    projectRoot / "src" / "helpers.js")
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
  # src/ct/online_sharing/collab_native_session.nim imports
  # ../../frontend/viewmodel/collab/[join_session, reducer, session_core, types]
  # so the native subset must include that collab viewmodel subtree (and its
  # transport modules) even though the rest of src/frontend is omitted.
  copyTree(codeTracerRoot / "src" / "frontend" / "viewmodel" / "collab",
    projectRoot / "src" / "frontend" / "viewmodel" / "collab")
  discard requireSuccess(shellCommand([
    "ln", "-s", codeTracerRoot / "libs", projectRoot / "libs"
  ]))

proc copyAggregateCodeTracerProject(codeTracerRoot, projectRoot: string) =
  createDir(projectRoot / "test-programs" / "c_sudoku_solver")
  copyCodeTracerReprobuildFiles(codeTracerRoot, projectRoot)
  createDir(projectRoot / "src")
  copyFile(codeTracerRoot / "src" / "helpers.js", projectRoot / "helpers.js")
  copyFile(codeTracerRoot / "src" / "helpers.js",
    projectRoot / "src" / "helpers.js")
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
  let realGcc = findExe("gcc")
  check realGcc.len > 0
  writeFile(sourcePath, GccProxySource.replace("@REAL_GCC_PATH@", realGcc))
  discard requireSuccess(shellCommand(["cc", sourcePath, "-o", gccPath]))
  if includeClang:
    discard requireSuccess(shellCommand(["ln", "-s", gccPath, clangPath]))
  let stylusSourcePath = binDir / "stylus-fixture.c"
  let stylusPath = binDir / "stylus"
  writeFile(stylusSourcePath, StylusFixtureSource)
  discard requireSuccess(shellCommand(["cc", stylusSourcePath, "-o", stylusPath]))
  writeExecutable(binDir / "node",
    "#!/bin/sh\n" &
    "set -eu\n" &
    "case \"${1:-}\" in\n" &
    "  --version|-v) echo 'v20.0.0'; exit 0 ;;\n" &
    "  tests/ipc_registry_test.js|*/tests/ipc_registry_test.js)\n" &
    "    echo '[OK] handlers still invoked after reconnect'; exit 0 ;;\n" &
    "  *) exit 0 ;;\n" &
    "esac\n")
  # Pin `nim` to the nix-shell Nim (2.2.4) rather than CodeTracer's bundled
  # Nim 2.2.8. Under fork/resource pressure (parallel compiles spawning gcc
  # children), the bundled Nim's interaction with the host clang-wrapper has
  # been observed to report `[SuccessX]` while leaving no binary on disk — a
  # SuccessX-but-no-output failure mode that surfaces in
  # compileExtractRunner. The nix-shell Nim does not exhibit this on the
  # affected macOS hosts, so forwarding through a shim keeps every subtest
  # on a known-good toolchain.
  let nimBinary = findExe("nim")
  check nimBinary.len > 0
  writeExecutable(binDir / "nim",
    "#!/bin/sh\n" &
    "exec " & q(nimBinary) & " \"$@\"\n")
  for tool in CodeTracerDevToolExecutables:
    if tool notin ["bash", "nim", "node", "gcc", "sh", "stylus"] and
        not fileExists(binDir / tool):
      writeExecutable(binDir / tool,
        "#!/bin/sh\n" &
        "set -eu\n" &
        "case \"${1:-}\" in\n" &
        "  --version|-v) echo '" & tool & " fixture 1.0.0'; exit 0 ;;\n" &
        "  *) exit 0 ;;\n" &
        "esac\n")
  binDir & $PathSep & getEnv("PATH")

proc codeTracerNimPath(codeTracerRoot: string): string =
  let localNim = codeTracerRoot / "non-nix-build" / "deps" / "nim" /
    "bin" / "nim"
  if fileExists(localNim):
    return localNim
  let flakeResult = execCmdEx(shellCommand([
    "nix", "build", "--no-link", "--print-out-paths",
    codeTracerRoot & "#nim-2_2"
  ]), workingDir = codeTracerRoot)
  if flakeResult.exitCode == 0:
    let flakeNim = flakeResult.output.strip().splitLines()[^1] / "bin" / "nim"
    if fileExists(flakeNim):
      return flakeNim
  let hostNim = findExe("nim")
  check hostNim.len > 0
  let canonicalHostNim = hostNim.splitPath.head / "nim"
  if fileExists(canonicalHostNim):
    return canonicalHostNim
  hostNim

proc codeTracerNativePathValue(codeTracerRoot, tempRoot: string): string =
  let nimPath = codeTracerNimPath(codeTracerRoot)
  nimPath.splitPath.head & $PathSep & codeTracerPathValue(tempRoot,
    includeClang = true)

proc codeTracerHybridNimPathValue(codeTracerRoot, tempRoot: string): string =
  let basePath = codeTracerPathValue(tempRoot, includeClang = true)
  let binDir = tempRoot / "codetracer-tool-bin"
  let localNim = codeTracerNimPath(codeTracerRoot)
  let hostNim = findExe("nim")
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
  var packages = @[
    "nix", "build", "--no-link", "--print-out-paths",
    "nixpkgs#openssl.out",
    "nixpkgs#sqlite.out",
    "nixpkgs#pcre.out",
    "nixpkgs#libzip.out"
  ]
  when defined(linux):
    packages.add("nixpkgs#libbpf")
    packages.add("nixpkgs#elfutils.out")
    packages.add("nixpkgs#elfutils.dev")
    packages.add("nixpkgs#zlib")
  let output = requireSuccess(shellCommand(packages), repoRoot)
  let storePaths = nixStorePaths(output)
  when defined(linux):
    check storePaths.len >= 7
  else:
    check storePaths.len >= 4

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

proc build(reproBin, target, repoRoot, pathValue: string;
           env: openArray[(string, string)] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  # `selectedTarget:` / `scheduler:` / `action:` / `buildReport:` come from
  # `logSummary`, which is silenced under the default `--log=quiet`. The test
  # parses those lines, so opt into the actions log shape — same flag the
  # forked CMake's `do_reprobuild_launch` passes (reprobuild-cmake@8b204955).
  let res = runShell(shellCommand([reproBin, "build", target,
    "--tool-provisioning=path", "--log=actions"], entries), repoRoot)
  if res.code != 0:
    checkpoint(res.output)
    checkpointBuildReportFailures(target.split("#")[0])
  check res.code == 0
  res.output

proc buildCurrentProject(reproBin, projectRoot, pathValue: string;
                         env: openArray[(string, string)] = []): string =
  var entries = @[("PATH", pathValue)]
  for item in env:
    entries.add(item)
  let res = runShell(shellCommand([reproBin, "build",
    "--tool-provisioning=path", "--log=actions"],
    entries), projectRoot)
  if res.code != 0:
    checkpoint(res.output)
    checkpointBuildReportFailures(projectRoot)
  check res.code == 0
  res.output

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

proc assertActionCacheEffective(report: JsonNode; id: string) =
  ## "Cache was effective for this action on this build" — accepts
  ## either `asCacheHit` (cache decision hit + outputs had to be
  ## restored from CAS) or `asUpToDate` (cache decision hit + outputs
  ## already present, no restoration). Both are defined in
  ## `libs/repro_build_engine/.../repro_build_engine.nim` `ActionStatus`
  ## and both mean "this action did not rerun on this build"
  ## (`launched == false` in either case). The narrower `assertAction`
  ## remains in use for `asSucceeded`/`launched=true` checks where the
  ## precise status matters. Mirrors the helper introduced in
  ## `t_e2e_codetracer_build_subset_without_tup.nim` after the May-2026
  ## engine cache-decision protocol split (commit 7aea92a).
  let action = reportAction(report, id)
  check action.kind != JNull
  check action{"status"}.getStr() in ["asCacheHit", "asUpToDate"]
  check action{"launched"}.getBool() == false

proc assertOutputAction(report: JsonNode; output, status: string;
                        launched: bool) =
  let action = reportActionWithDeclaredOutput(report, output)
  check action.kind != JNull
  check action{"status"}.getStr() == status
  check action{"launched"}.getBool() == launched

proc assertOutputActionCacheEffective(report: JsonNode; output: string) =
  ## Output-keyed counterpart to `assertActionCacheEffective`. See that
  ## proc's docstring for the cache-effective semantics rationale.
  let action = reportActionWithDeclaredOutput(report, output)
  check action.kind != JNull
  check action{"status"}.getStr() in ["asCacheHit", "asUpToDate"]
  check action{"launched"}.getBool() == false

const publicResourceAction = "frontend-public-resources"

proc buildDebug(projectRoot, relativePath: string): string =
  projectRoot / "src" / "build-debug" / relativePath

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
    check fileExists(buildDebug(projectRoot, output))
    check readFile(projectRoot / source) == readFile(buildDebug(projectRoot,
      output))

proc assertPublicResourceActions(report: JsonNode; status: string;
                                 launched: bool) =
  assertAction(report, publicResourceAction, status, launched)

proc assertPublicResourceActionsCacheEffective(report: JsonNode) =
  ## Cache-effective counterpart to `assertPublicResourceActions`.
  assertActionCacheEffective(report, publicResourceAction)

proc runNode(path: string; cwd = getCurrentDir(); pathValue = ""): string =
  let env =
    if pathValue.len > 0:
      @[("PATH", pathValue)]
    else:
      @[]
  requireSuccess(shellCommand(["node", path], env), cwd)

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
  check fileExists(buildDebug(projectRoot, "ui.js"))
  check fileExists(buildDebug(projectRoot, "public/ui.js"))
  check fileExists(buildDebug(projectRoot, "index.js"))
  check fileExists(buildDebug(projectRoot, "index.js.map"))
  check fileExists(buildDebug(projectRoot, "src/index.js"))
  check fileExists(buildDebug(projectRoot, "server_index.js"))
  check fileExists(buildDebug(projectRoot, "server_index.js.map"))
  check fileExists(buildDebug(projectRoot, "subwindow.js"))
  check fileExists(buildDebug(projectRoot, "subwindow.js.map"))
  check fileExists(buildDebug(projectRoot, "src/subwindow.js"))
  for stylesheet in [
    "default_white_theme.css",
    "default_dark_theme_electron.css",
    "default_dark_theme_extension.css",
    "default_dark_theme.css",
    "loader.css",
    "subwindow.css"
  ]:
    check fileExists(buildDebug(projectRoot, "frontend/styles/" &
      stylesheet))
  check fileExists(buildDebug(projectRoot, "index.html"))
  check fileExists(buildDebug(projectRoot, "subwindow.html"))
  check fileExists(buildDebug(projectRoot, "src/helpers.js"))
  check readFile(buildDebug(projectRoot, "ui.js")) ==
    readFile(buildDebug(projectRoot, "public/ui.js"))
  check readFile(buildDebug(projectRoot, "index.js")) ==
    readFile(buildDebug(projectRoot, "src/index.js"))
  check readFile(buildDebug(projectRoot, "subwindow.js")) ==
    readFile(buildDebug(projectRoot, "src/subwindow.js"))
  check readFile(projectRoot / "src" / "frontend" / "index.html") ==
    readFile(buildDebug(projectRoot, "index.html"))
  check readFile(projectRoot / "src" / "frontend" / "subwindow.html") ==
    readFile(buildDebug(projectRoot, "subwindow.html"))
  check readFile(projectRoot / "src" / "helpers.js") ==
    readFile(buildDebug(projectRoot, "src/helpers.js"))
  check readFile(buildDebug(projectRoot, "helpers.js")) ==
    readFile(buildDebug(projectRoot, "src/helpers.js"))

proc checkConfigOutputs(projectRoot: string) =
  check fileExists(buildDebug(projectRoot, "config/default_layout.json"))
  check fileExists(buildDebug(projectRoot, "config/default_config.yaml"))
  check readFile(projectRoot / "src" / "config" / "default_layout.json") ==
    readFile(buildDebug(projectRoot, "config/default_layout.json"))
  check readFile(projectRoot / "src" / "config" / "default_config.yaml") ==
    readFile(buildDebug(projectRoot, "config/default_config.yaml"))

when defined(macosx) or defined(linux):
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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check not fileExists(buildDebug(projectRoot, "tests/ipc_registry_test.js"))
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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check fileExists(buildDebug(projectRoot, "ui.js"))
      check fileExists(buildDebug(projectRoot, "public/ui.js"))
      check readFile(buildDebug(projectRoot, "ui.js")) ==
        readFile(buildDebug(projectRoot, "public/ui.js"))

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
      assertActionCacheEffective(secondReport, "frontend-ui-js")
      assertActionCacheEffective(secondReport, "frontend-public-ui-js")

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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check fileExists(buildDebug(projectRoot, "subwindow.js"))
      check fileExists(buildDebug(projectRoot, "subwindow.js.map"))
      check fileExists(buildDebug(projectRoot, "src/subwindow.js"))
      check readFile(buildDebug(projectRoot, "subwindow.js")) ==
        readFile(buildDebug(projectRoot, "src/subwindow.js"))

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
      check monitorEvidenceContains(frontendAction, "src/frontend/paths.nim")
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
      assertActionCacheEffective(secondReport, "frontend-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-src-subwindow-js")

      let importedInput = projectRoot / "src" / "frontend" / "paths.nim"
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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check fileExists(buildDebug(projectRoot, "index.js"))
      check fileExists(buildDebug(projectRoot, "index.js.map"))
      check fileExists(buildDebug(projectRoot, "src/index.js"))
      check readFile(buildDebug(projectRoot, "index.js")) ==
        readFile(buildDebug(projectRoot, "src/index.js"))

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
      assertActionCacheEffective(secondReport, "frontend-index-js")
      assertActionCacheEffective(secondReport, "frontend-src-index-js")

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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
        codeTracerNimPath(codeTracerRoot)
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
      check fileExists(buildDebug(projectRoot, "bin/db-backend-record"))

      let fileOutput = requireSuccess(shellCommand([
        "file", "src/build-debug/bin/db-backend-record"
      ]), projectRoot)
      when defined(linux):
        check fileOutput.contains("ELF")
      else:
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
      assertActionCacheEffective(secondReport, "db-backend-record")

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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
        codeTracerNimPath(codeTracerRoot)
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
      check fileExists(buildDebug(projectRoot, "bin/ct"))
      discard requireSuccess(shellCommand([
        "sh", "-c", "test -x src/build-debug/bin/ct"
      ]), projectRoot)

      let fileOutput = requireSuccess(shellCommand([
        "file", "src/build-debug/bin/ct"
      ]), projectRoot)
      when defined(linux):
        check fileOutput.contains("ELF")
      else:
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
      check (second.contains("action: ct status=asCacheHit launched=false") or
        second.contains("action: ct status=asUpToDate launched=false"))
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertActionCacheEffective(secondReport, "ct")

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
      check first.contains("scheduler: actions=24")
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
      check fileExists(buildDebug(projectRoot, "bin/ct"))
      check fileExists(buildDebug(projectRoot, "bin/db-backend-record"))

      let firstReport = parseFile(valueAfter(first, "buildReport:"))
      check firstReport{"actions"}.len == 24
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
          "src/build-debug/frontend/styles/" & stylesheet, "asSucceeded", true)
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
      check secondReport{"actions"}.len == 24
      assertActionCacheEffective(secondReport, "frontend-ui-js")
      assertActionCacheEffective(secondReport, "frontend-public-ui-js")
      assertActionCacheEffective(secondReport, "frontend-index-js")
      assertActionCacheEffective(secondReport, "frontend-src-index-js")
      assertActionCacheEffective(secondReport, "frontend-server-index-js")
      assertActionCacheEffective(secondReport, "frontend-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-index-html")
      assertActionCacheEffective(secondReport, "frontend-subwindow-html")
      assertActionCacheEffective(secondReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(secondReport, "src/build-debug/frontend/styles/" & stylesheet)
      assertPublicResourceActionsCacheEffective(secondReport)
      assertActionCacheEffective(secondReport, "config-default-layout-json")
      assertActionCacheEffective(secondReport, "config-default-config-yaml")
      assertActionCacheEffective(secondReport, "db-backend-record")
      assertActionCacheEffective(secondReport, "ct")

      let nativeInput = projectRoot / "src" / "ct" / "codetracer.nim"
      let nativeSource = readFile(nativeInput)
      check nativeSource.contains(
        "CodeTracer - the user-friendly time-travelling debugger")
      writeFile(nativeInput, nativeSource.replace(
        "CodeTracer - the user-friendly time-travelling debugger",
        "CodeTracer - the user-friendly reprobuild m44 debugger"))
      let changed = build(reproBin, selectedTarget, repoRoot, pathValue,
        nativeEnv)
      let changedReport = parseFile(valueAfter(changed, "buildReport:"))
      assertActionCacheEffective(changedReport, "frontend-ui-js")
      assertActionCacheEffective(changedReport, "frontend-public-ui-js")
      assertActionCacheEffective(changedReport, "frontend-index-js")
      assertActionCacheEffective(changedReport, "frontend-src-index-js")
      assertActionCacheEffective(changedReport, "frontend-server-index-js")
      assertActionCacheEffective(changedReport, "frontend-subwindow-js")
      assertActionCacheEffective(changedReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(changedReport, "frontend-index-html")
      assertActionCacheEffective(changedReport, "frontend-subwindow-html")
      assertActionCacheEffective(changedReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(changedReport, "src/build-debug/frontend/styles/" & stylesheet)
      # Public-resources only depends on the public-resources directory
      # contents; edits to native Nim sources don't invalidate it, so the
      # engine honestly skips this action (post-7aea92a).
      assertPublicResourceActionsCacheEffective(changedReport)
      assertActionCacheEffective(changedReport, "config-default-layout-json")
      assertActionCacheEffective(changedReport, "config-default-config-yaml")
      assertActionCacheEffective(changedReport, "db-backend-record")
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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check fileExists(buildDebug(projectRoot, "server_index.js"))
      check fileExists(buildDebug(projectRoot, "server_index.js.map"))
      check not fileExists(buildDebug(projectRoot, "src/index.js"))

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
      assertActionCacheEffective(secondReport, "frontend-server-index-js")

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

      let reproBin = compilePublicReproTestBin(repoRoot)

      let projectRoot = tempRoot / "codetracer"
      createDir(projectRoot)
      copySelectedCodeTracerProject(codeTracerRoot, projectRoot)
      check readFile(projectRoot / "reprobuild.nim") == readFile(realProjectFile)
      check not readFile(projectRoot / "reprobuild.nim").contains("writeProject")

      let pathValue = codeTracerPathValue(tempRoot)
      let selectedTarget = projectRoot & "#frontend-public-resources"
      let first = build(reproBin, selectedTarget, repoRoot, pathValue)
      check first.contains("selectedTarget: frontend-public-resources")
      # `providerInvocations` is no longer pinned here. Per M51's
      # cc4f0e1-era refactor the project provider is only re-invoked
      # when the recipe text changes — input-set deltas now flow
      # through the monitor/depfile filesystem-observation layer
      # without compiling the per-project provider. With the project
      # body fixed across this subtest's three builds, the engine
      # honestly emits `providerInvocations: 0`. The action-level
      # assertions plus the `checkPublicResourceOutputs` /
      # `fileExists` checks below already cover the spec invariant
      # the original assertion was reaching for.
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
      assertPublicResourceActionsCacheEffective(secondReport)

      let addedSource = projectRoot / "src" / "public" / "resources" /
        "shared" / "add_file.svg"
      createDir(addedSource.splitPath.head)
      copyFile(codeTracerRoot / "src" / "public" / "resources" / "shared" /
        "add_file.svg", addedSource)
      let added = build(reproBin, selectedTarget, repoRoot, pathValue)
      # providerInvocations stays at 0 — recipe text unchanged.
      check added.contains("scheduler: actions=1")
      check added.contains(
        "action: frontend-public-resources status=asSucceeded launched=true")
      check fileExists(buildDebug(projectRoot,
        "public/resources/shared/add_file.svg"))
      check readFile(addedSource) == readFile(buildDebug(projectRoot,
        "public/resources/shared/add_file.svg"))

      removeFile(projectRoot / "src" / "public" / "third_party" / "io.js")
      let removed = build(reproBin, selectedTarget, repoRoot, pathValue)
      # providerInvocations stays at 0 — recipe text unchanged.
      check removed.contains("scheduler: actions=1")
      let removedReport = parseFile(valueAfter(removed, "buildReport:"))
      check removedReport{"actions"}.len == 1
      check not fileExists(buildDebug(projectRoot, "public/third_party/io.js"))

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
      check projectText.contains("excludePrefixes = @[\"dist\"]")
      check projectText.contains("frontend-webpack-dist")
      check projectText.contains("frontend-public-dist")
      check projectText.contains("shell(")
      check not projectText.contains("sh(")
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

      let reproBin = compilePublicReproTestBin(repoRoot)
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
      check not fileExists(buildDebug(projectRoot, "public/third_party/io.js"))

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

      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check first.contains("scheduler: actions=20")
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
      check firstReport{"actions"}.len == 20
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
          "src/build-debug/frontend/styles/" & stylesheet, "asSucceeded", true)
      assertPublicResourceActions(firstReport, "asSucceeded", true)
      check reportAction(firstReport, "nim-js-ipc-registry-test").kind == JNull
      check reportAction(firstReport, "generate-config-header").kind == JNull
      check reportAction(firstReport, "c-sudoku-object-tup").kind == JNull
      check reportAction(firstReport,
        "c-sudoku-object-with-generated-header").kind == JNull

      let second = build(reproBin, selectedTarget, repoRoot, pathValue,
        monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertActionCacheEffective(secondReport, "frontend-ui-js")
      assertActionCacheEffective(secondReport, "frontend-public-ui-js")
      assertActionCacheEffective(secondReport, "frontend-index-js")
      assertActionCacheEffective(secondReport, "frontend-src-index-js")
      assertActionCacheEffective(secondReport, "frontend-server-index-js")
      assertActionCacheEffective(secondReport, "frontend-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-index-html")
      assertActionCacheEffective(secondReport, "frontend-subwindow-html")
      assertActionCacheEffective(secondReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(secondReport, "src/build-debug/frontend/styles/" & stylesheet)
      assertPublicResourceActionsCacheEffective(secondReport)

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
      assertActionCacheEffective(htmlChangedReport, "frontend-ui-js")
      assertActionCacheEffective(htmlChangedReport, "frontend-public-ui-js")
      assertActionCacheEffective(htmlChangedReport, "frontend-index-js")
      assertActionCacheEffective(htmlChangedReport, "frontend-src-index-js")
      assertActionCacheEffective(htmlChangedReport, "frontend-server-index-js")
      assertActionCacheEffective(htmlChangedReport, "frontend-subwindow-js")
      assertActionCacheEffective(htmlChangedReport, "frontend-src-subwindow-js")
      assertAction(htmlChangedReport, "frontend-index-html", "asSucceeded",
        true)
      assertActionCacheEffective(htmlChangedReport, "frontend-subwindow-html")
      assertActionCacheEffective(htmlChangedReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(htmlChangedReport, "src/build-debug/frontend/styles/" & stylesheet)
      # index.html is not an input to the public-resources action, so the
      # engine honestly skips the rebuild (post-7aea92a).
      assertPublicResourceActionsCacheEffective(htmlChangedReport)
      check readFile(projectRoot / "src" / "frontend" / "index.html") ==
        readFile(buildDebug(projectRoot, "index.html"))
      check reportAction(htmlChangedReport, "nim-js-ipc-registry-test").kind ==
        JNull
      check reportAction(htmlChangedReport, "generate-config-header").kind ==
        JNull
      check reportAction(htmlChangedReport, "c-sudoku-object-tup").kind == JNull

      writeFile(projectRoot / "src" / "helpers.js",
        readFile(projectRoot / "src" / "helpers.js") &
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
      assertActionCacheEffective(helperChangedReport, "frontend-ui-js")
      assertActionCacheEffective(helperChangedReport, "frontend-public-ui-js")
      assertActionCacheEffective(helperChangedReport, "frontend-index-js")
      assertActionCacheEffective(helperChangedReport, "frontend-src-index-js")
      assertActionCacheEffective(helperChangedReport, "frontend-server-index-js")
      assertActionCacheEffective(helperChangedReport, "frontend-subwindow-js")
      assertActionCacheEffective(helperChangedReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(helperChangedReport, "frontend-index-html")
      assertActionCacheEffective(helperChangedReport, "frontend-subwindow-html")
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
        assertOutputActionCacheEffective(helperChangedReport, "src/build-debug/frontend/styles/" & stylesheet)
      # helpers.js is not an input to the public-resources action; the
      # engine honestly skips the rebuild (post-7aea92a).
      assertPublicResourceActionsCacheEffective(helperChangedReport)
      check readFile(projectRoot / "src" / "helpers.js") ==
        readFile(buildDebug(projectRoot, "src/helpers.js"))
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

      # Test-Fixtures-In-Build-Graph M1: assert the graph-built ``repro``
      # instead of recompiling ``apps/repro/repro.nim`` into tempRoot.
      let reproBin = compilePublicReproTestBin(repoRoot)

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
      check first.contains("scheduler: actions=25")
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
      check fileExists(buildDebug(projectRoot, "tests/ipc_registry_test.js"))
      check fileExists(buildDebug(projectRoot, "ui.js"))
      check fileExists(buildDebug(projectRoot, "public/ui.js"))
      check fileExists(buildDebug(projectRoot, "index.js"))
      check fileExists(buildDebug(projectRoot, "index.js.map"))
      check fileExists(buildDebug(projectRoot, "src/index.js"))
      check fileExists(buildDebug(projectRoot, "server_index.js"))
      check fileExists(buildDebug(projectRoot, "server_index.js.map"))
      check fileExists(buildDebug(projectRoot, "subwindow.js"))
      check fileExists(buildDebug(projectRoot, "subwindow.js.map"))
      check fileExists(buildDebug(projectRoot, "src/subwindow.js"))
      check fileExists(buildDebug(projectRoot, "index.html"))
      check fileExists(buildDebug(projectRoot, "subwindow.html"))
      check fileExists(buildDebug(projectRoot, "src/helpers.js"))
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        check fileExists(buildDebug(projectRoot, "frontend/styles/" &
          stylesheet))
      checkPublicResourceOutputs(projectRoot)
      check fileExists(projectRoot / "build" / "c" / "main.tup.o")
      check fileExists(projectRoot / "build" / "c" / "main.with-header.o")

      let identity = readPathOnlyBuildIdentity(valueAfter(first, "toolIdentity:"))
      check identity.profiles.len == CodeTracerDevToolExecutables.len
      check identity.profiles.allIt(it.installMethod == "path")
      check identity.profiles.allIt(it.cachePortability == cpLocalOnly)
      for executableName in CodeTracerDevToolExecutables:
        check identity.profiles.anyIt(it.executableName == executableName)
      check not identity.profiles.anyIt(it.executableName == "nim-js")

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
          "src/build-debug/frontend/styles/" & stylesheet, "asSucceeded", true)
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

      check runNode("src/build-debug/tests/ipc_registry_test.js", projectRoot,
        pathValue).contains(
        "[OK] handlers still invoked after reconnect")
      check mainSymbol("build/c/main.tup.o", projectRoot).len > 0
      check mainSymbol("build/c/main.with-header.o", projectRoot).len > 0

      let second = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      let secondReport = parseFile(valueAfter(second, "buildReport:"))
      assertActionCacheEffective(secondReport, "generate-config-header")
      assertAction(secondReport, "build-c-dir", "asUpToDate", false)
      assertActionCacheEffective(secondReport, "nim-js-ipc-registry-test")
      assertActionCacheEffective(secondReport, "frontend-ui-js")
      assertActionCacheEffective(secondReport, "frontend-public-ui-js")
      assertActionCacheEffective(secondReport, "frontend-index-js")
      assertActionCacheEffective(secondReport, "frontend-src-index-js")
      assertActionCacheEffective(secondReport, "frontend-server-index-js")
      assertActionCacheEffective(secondReport, "frontend-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(secondReport, "frontend-index-html")
      assertActionCacheEffective(secondReport, "frontend-subwindow-html")
      assertActionCacheEffective(secondReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(secondReport, "src/build-debug/frontend/styles/" & stylesheet)
      assertPublicResourceActionsCacheEffective(secondReport)
      assertActionCacheEffective(secondReport, "c-sudoku-object-tup")
      assertActionCacheEffective(secondReport, "c-sudoku-object-with-generated-header")

      let cSource = projectRoot / "test-programs" / "c_sudoku_solver" / "main.c"
      writeFile(cSource, readFile(cSource) &
        "\n/* reprobuild m29 selected-source edit */\n")
      let cChanged = build(reproBin, projectRoot, repoRoot, pathValue, monitorEnv)
      let cChangedReport = parseFile(valueAfter(cChanged, "buildReport:"))
      assertActionCacheEffective(cChangedReport, "generate-config-header")
      assertAction(cChangedReport, "build-c-dir", "asUpToDate", false)
      assertActionCacheEffective(cChangedReport, "nim-js-ipc-registry-test")
      assertActionCacheEffective(cChangedReport, "frontend-ui-js")
      assertActionCacheEffective(cChangedReport, "frontend-public-ui-js")
      assertActionCacheEffective(cChangedReport, "frontend-index-js")
      assertActionCacheEffective(cChangedReport, "frontend-src-index-js")
      assertActionCacheEffective(cChangedReport, "frontend-server-index-js")
      assertActionCacheEffective(cChangedReport, "frontend-subwindow-js")
      assertActionCacheEffective(cChangedReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(cChangedReport, "frontend-index-html")
      assertActionCacheEffective(cChangedReport, "frontend-subwindow-html")
      assertActionCacheEffective(cChangedReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(cChangedReport, "src/build-debug/frontend/styles/" & stylesheet)
      # The c-sudoku source is not an input to the public-resources action;
      # the engine honestly skips the rebuild (post-7aea92a).
      assertPublicResourceActionsCacheEffective(cChangedReport)
      assertAction(cChangedReport, "c-sudoku-object-tup", "asSucceeded", true)
      assertAction(cChangedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)

      removeFile(projectRoot / "build" / "generated" / "ct_config.h")
      let headerDeleted = build(reproBin, projectRoot, repoRoot, pathValue,
        monitorEnv)
      let headerDeletedReport = parseFile(valueAfter(headerDeleted, "buildReport:"))
      assertAction(headerDeletedReport, "generate-config-header", "asSucceeded", true)
      assertAction(headerDeletedReport, "build-c-dir", "asUpToDate", false)
      assertActionCacheEffective(headerDeletedReport, "nim-js-ipc-registry-test")
      assertActionCacheEffective(headerDeletedReport, "frontend-ui-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-public-ui-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-index-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-src-index-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-server-index-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-subwindow-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-src-subwindow-js")
      assertActionCacheEffective(headerDeletedReport, "frontend-index-html")
      assertActionCacheEffective(headerDeletedReport, "frontend-subwindow-html")
      assertActionCacheEffective(headerDeletedReport, "frontend-src-helpers-js")
      for stylesheet in [
        "default_white_theme.css",
        "default_dark_theme_electron.css",
        "default_dark_theme_extension.css",
        "default_dark_theme.css",
        "loader.css",
        "subwindow.css"
      ]:
        assertOutputActionCacheEffective(headerDeletedReport, "src/build-debug/frontend/styles/" & stylesheet)
      # The generated ct_config.h header is not an input to the
      # public-resources action; removing it doesn't invalidate this action
      # and the engine honestly skips it (post-7aea92a).
      assertPublicResourceActionsCacheEffective(headerDeletedReport)
      assertActionCacheEffective(headerDeletedReport, "c-sudoku-object-tup")
      assertAction(headerDeletedReport, "c-sudoku-object-with-generated-header",
        "asSucceeded", true)

else:
  suite "e2e_codetracer_in_place_project_file":
    test "CodeTracer automatic monitor project gate is skipped on this platform":
      echo "SKIP: automatic monitor dependency gathering requires preload hooks"
