import std/[algorithm, os, osproc, streams, strutils, tables, tempfiles, unittest]

import repro_monitor_hooks
import repro_monitor_depfile

when defined(macosx) or defined(linux):
  const ParentSource = r"""
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#if defined(__APPLE__)
#define REPRO_PRELOAD_ENV "DYLD_INSERT_LIBRARIES"
#else
#define REPRO_PRELOAD_ENV "LD_PRELOAD"
#endif

struct thread_arg {
  const char *out_dir;
  int index;
};

static void *thread_main(void *raw) {
  struct thread_arg *arg = (struct thread_arg *)raw;
  char path[1024];
  snprintf(path, sizeof(path), "%s/parent-thread-%d.txt", arg->out_dir, arg->index);
  int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) return NULL;
  const char *msg = "parent-thread-write\n";
  write(fd, msg, strlen(msg));
  close(fd);
  return NULL;
}

static int child_work(const char *child_input, const char *out_dir) {
  int fd = open(child_input, O_RDONLY);
  if (fd < 0) return 75;
  char buf[64];
  if (read(fd, buf, sizeof(buf)) < 0) return 76;
  close(fd);

  struct stat st;
  lstat("missing-child-probe.txt", &st);

  pthread_t threads[3];
  struct thread_arg args[3];
  for (int i = 0; i < 3; i++) {
    args[i].out_dir = out_dir;
    args[i].index = i + 100;
    pthread_create(&threads[i], NULL, thread_main, &args[i]);
  }
  for (int i = 0; i < 3; i++) {
    pthread_join(threads[i], NULL);
  }
  return 0;
}

static int is_preload_env(const char *entry) {
  const char *name = REPRO_PRELOAD_ENV "=";
  return strncmp(entry, name, strlen(name)) == 0;
}

static char **child_env_without_preload(void) {
  int count = 0;
  for (char **env = environ; *env != NULL; env++) {
    if (!is_preload_env(*env)) count++;
  }
  char **result = calloc((size_t)count + 1, sizeof(char *));
  if (result == NULL) return environ;
  int index = 0;
  for (char **env = environ; *env != NULL; env++) {
    if (!is_preload_env(*env)) result[index++] = *env;
  }
  result[index] = NULL;
  return result;
}

int main(int argc, char **argv) {
  if (argc != 5) return 64;
  const char *child = argv[1];
  const char *parent_input = argv[2];
  const char *child_input = argv[3];
  const char *out_dir = argv[4];

  int fd = open(parent_input, O_RDONLY);
  if (fd < 0) return 65;
  char buf[64];
  if (read(fd, buf, sizeof(buf)) < 0) return 66;
  close(fd);

  struct stat st;
  stat("missing-parent-probe.txt", &st);

  pthread_t threads[4];
  struct thread_arg args[4];
  for (int i = 0; i < 4; i++) {
    args[i].out_dir = out_dir;
    args[i].index = i;
    pthread_create(&threads[i], NULL, thread_main, &args[i]);
  }
  for (int i = 0; i < 4; i++) {
    pthread_join(threads[i], NULL);
  }

  char *child_argv[] = {(char *)child, (char *)child_input, (char *)out_dir, NULL};
  char **child_env = child_env_without_preload();
  pid_t pid = 0;
  int spawn_result = posix_spawn(&pid, child, NULL, NULL, child_argv, child_env);
  if (spawn_result != 0) return 67;

  int status = 0;
  waitpid(pid, &status, 0);
  if (!WIFEXITED(status)) return 68;
  return WEXITSTATUS(status);
}
"""

  const ChildSource = r"""
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct thread_arg {
  const char *out_dir;
  int index;
};

#if defined(__APPLE__)
#define REPRO_PRELOAD_ENV "DYLD_INSERT_LIBRARIES"
#else
#define REPRO_PRELOAD_ENV "LD_PRELOAD"
#endif

static void *thread_main(void *raw) {
  struct thread_arg *arg = (struct thread_arg *)raw;
  char path[1024];
  snprintf(path, sizeof(path), "%s/child-thread-%d.txt", arg->out_dir, arg->index);
  int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) return NULL;
  const char *msg = "child-thread-write\n";
  write(fd, msg, strlen(msg));
  close(fd);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc != 3) return 74;
  if (getenv(REPRO_PRELOAD_ENV) == NULL) return 77;
  const char *child_input = argv[1];
  const char *out_dir = argv[2];

  int fd = open(child_input, O_RDONLY);
  if (fd < 0) return 75;
  char buf[64];
  if (read(fd, buf, sizeof(buf)) < 0) return 76;
  close(fd);

  struct stat st;
  lstat("missing-child-probe.txt", &st);

  pthread_t threads[3];
  struct thread_arg args[3];
  for (int i = 0; i < 3; i++) {
    args[i].out_dir = out_dir;
    args[i].index = i;
    pthread_create(&threads[i], NULL, thread_main, &args[i]);
  }
  for (int i = 0; i < 3; i++) {
    pthread_join(threads[i], NULL);
  }
  return 0;
}
"""

  when defined(linux):
    const StackableShimSource = r"""
import std/[os, strutils]

import repro_monitor_hooks/linux_preload_runtime

proc appendLine(line: string) {.raises: [].} =
  try:
    let logPath = getEnv("REPRO_STACKABLE_HOOK_LOG")
    if logPath.len == 0:
      return
    var file = open(logPath, fmAppend)
    try:
      file.writeLine(line)
    finally:
      close(file)
  except CatchableError:
    discard

proc isTarget(path: cstring): bool {.raises: [].} =
  path != nil and ($path).contains("stack-target.txt")

proc firstOpen(ctx: var OpenContext) {.raises: [].} =
  let target = isTarget(ctx.path)
  if target:
    appendLine("first-before")
  callNext(ctx)
  if target:
    appendLine("first-after")

proc secondOpen(ctx: var OpenContext) {.raises: [].} =
  let target = isTarget(ctx.path)
  if target:
    appendLine("second-before")
  callNext(ctx)
  if target:
    appendLine("second-after")

registerOpenHook(firstOpen, priority = 10)
registerOpenHook(secondOpen, priority = 20)
registerOpen64Hook(firstOpen, priority = 10)
registerOpen64Hook(secondOpen, priority = 20)
"""

    const StackableFixtureSource = r"""
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 2) return 64;
  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) return 65;
  char buffer[16];
  if (read(fd, buffer, sizeof(buffer)) < 0) return 66;
  close(fd);
  return 0;
}
"""

  proc runCommand(command: string) =
    let result = execCmdEx(command)
    check result.exitCode == 0
    if result.exitCode != 0:
      echo result.output

  proc compileShim(root, outPath: string) =
    var command =
      "nim c --app:lib --threads:on " &
      "--path:" & quoteShell(root / "libs/repro_monitor_shim/src") & " "
    when defined(macosx):
      command.add("--path:" & quoteShell("/Users/zahary/metacraft/ct_interpose/src") & " ")
    command.add(
      "--nimcache:" & quoteShell(root / "build/nimcache/integration-repro-monitor-shim") & " " &
      "--out:" & quoteShell(outPath) & " ")
    when defined(macosx):
      command.add(quoteShell(root / "libs/repro_monitor_shim/src/repro_monitor_shim/macos_interpose.nim"))
    else:
      command.add(quoteShell(root / "libs/repro_monitor_shim/src/repro_monitor_shim/linux_preload.nim"))
    runCommand(command)

  when defined(linux):
    proc compileStackableShim(root, sourcePath, outPath: string) =
      let command =
        "nim c --app:lib --threads:on " &
        "--path:" & quoteShell(root / "libs/repro_monitor_hooks/src") & " " &
        "--nimcache:" & quoteShell(root / "build/nimcache/integration-linux-stackable-runtime") & " " &
        "--out:" & quoteShell(outPath) & " " &
        quoteShell(sourcePath)
      runCommand(command)

  proc compileFixture(sourcePath, outputPath: string) =
    runCommand("cc -pthread " & quoteShell(sourcePath) & " -o " & quoteShell(outputPath))

  proc hasRecord(records: seq[MonitorRecord]; predicate: proc(record: MonitorRecord): bool): bool =
    for record in records:
      if predicate(record):
        return true

  proc setEnvVar(name, value: string; oldValues: var seq[(string, string, bool)]) =
    oldValues.add((name, getEnv(name), existsEnv(name)))
    putEnv(name, value)

  proc restoreEnv(oldValues: seq[(string, string, bool)]) =
    for i in countdown(oldValues.high, 0):
      let (name, value, existed) = oldValues[i]
      if existed:
        putEnv(name, value)
      else:
        delEnv(name)

  suite "integration_stackable_hooks_extracted_process_tree":
    test "preload shim records process tree and threaded file evidence":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-monitor-m10", "")
      defer: removeDir(tempRoot)

      let buildDir = tempRoot / "build"
      let fragmentDir = tempRoot / "fragments"
      let outputDir = tempRoot / "outputs"
      createDir(buildDir)
      createDir(fragmentDir)
      createDir(outputDir)

      let parentSource = buildDir / "fixture_parent.c"
      let childSource = buildDir / "fixture_child.c"
      let parentExe = buildDir / "fixture_parent"
      let childExe = buildDir / "fixture_child"
      let shimDylib =
        when defined(linux):
          buildDir / "librepro_monitor_shim.so"
        else:
          buildDir / "librepro_monitor_shim.dylib"
      let depfile = tempRoot / "evidence.rdep"
      let parentInput = tempRoot / "parent-input.txt"
      let childInput = tempRoot / "child-input.txt"

      writeFile(parentSource, ParentSource)
      writeFile(childSource, ChildSource)
      writeFile(parentInput, "parent input\n")
      writeFile(childInput, "child input\n")

      compileShim(repoRoot, shimDylib)
      compileFixture(parentSource, parentExe)
      compileFixture(childSource, childExe)

      var oldEnv: seq[(string, string, bool)] = @[]
      when defined(linux):
        setEnvVar("LD_PRELOAD", shimDylib, oldEnv)
        setEnvVar("REPRO_MONITOR_SHIM_LIB", shimDylib, oldEnv)
      else:
        setEnvVar("DYLD_INSERT_LIBRARIES", shimDylib, oldEnv)
      setEnvVar("REPRO_MONITOR_FRAGMENT_DIR", fragmentDir, oldEnv)
      setEnvVar("REPRO_MONITOR_SESSION", "m10-test-session", oldEnv)
      defer: restoreEnv(oldEnv)

      let process = startProcess(parentExe,
        args = [childExe, parentInput, childInput, outputDir],
        env = nil,
        options = {poStdErrToStdOut})
      let processOutput = process.outputStream.readAll()
      let exitCode = waitForExit(process)
      close(process)
      if exitCode != 0:
        echo processOutput
      check exitCode == 0

      discard finalizeMonitorFragments(fragmentDir, depfile)
      let dep = readMonitorDepFile(depfile)
      let records = dep.records

      check readFile(depfile)[0 .. 3] == "RMDF"
      check records.len > 0
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrProcessStart)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrProcessSpawn and record.childOsPid != 0)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileRead and record.path == parentInput)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileRead and record.path == childInput)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrPathProbe and record.path.contains("missing-parent-probe"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrPathProbe and record.path.contains("missing-child-probe"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileWrite and record.path.contains("parent-thread-"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileWrite and record.path.contains("child-thread-"))

      var threadIds: seq[uint64] = @[]
      var seenSeq = initTable[uint64, bool]()
      for record in records:
        check not seenSeq.hasKey(record.seq)
        seenSeq[record.seq] = true
        if record.kind in {mrFileRead, mrFileWrite} and record.threadId != 0:
          threadIds.add(record.threadId)
      threadIds.sort()
      var uniqueThreadCount = 0
      var lastThreadId = 0'u64
      for id in threadIds:
        if uniqueThreadCount == 0 or id != lastThreadId:
          inc uniqueThreadCount
          lastThreadId = id
      check uniqueThreadCount >= 2

    when defined(linux):
      test "linux preload runtime dispatches registered hooks in priority order":
        let repoRoot = getCurrentDir()
        let tempRoot = createTempDir("repro-linux-stackable-hooks", "")
        defer: removeDir(tempRoot)

        let buildDir = tempRoot / "build"
        createDir(buildDir)
        let shimSource = buildDir / "stackable_shim.nim"
        let fixtureSource = buildDir / "stackable_fixture.c"
        let shimSo = buildDir / "libstackable_shim.so"
        let fixtureExe = buildDir / "stackable_fixture"
        let targetPath = tempRoot / "stack-target.txt"
        let logPath = tempRoot / "hook-order.log"

        writeFile(shimSource, StackableShimSource)
        writeFile(fixtureSource, StackableFixtureSource)
        writeFile(targetPath, "target\n")
        writeFile(logPath, "")

        compileStackableShim(repoRoot, shimSource, shimSo)
        compileFixture(fixtureSource, fixtureExe)

        var oldEnv: seq[(string, string, bool)] = @[]
        setEnvVar("LD_PRELOAD", shimSo, oldEnv)
        setEnvVar("REPRO_STACKABLE_HOOK_LOG", logPath, oldEnv)
        defer: restoreEnv(oldEnv)

        let process = startProcess(fixtureExe,
          args = [targetPath],
          env = nil,
          options = {poStdErrToStdOut})
        let processOutput = process.outputStream.readAll()
        let exitCode = waitForExit(process)
        close(process)
        if exitCode != 0:
          echo processOutput
        check exitCode == 0

        check readFile(logPath).strip.splitLines == @[
          "first-before",
          "second-before",
          "second-after",
          "first-after"]

when not (defined(macosx) or defined(linux)):
  suite "integration_stackable_hooks_extracted_process_tree":
    test "preload hook gate is skipped on this platform":
      check true
