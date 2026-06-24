import std/[json, os, osproc, strutils, tempfiles, unittest]

import io_mon
from repro_test_support import requireBinary, monitorShimPath

when not (defined(macosx) or defined(linux)):
  {.warning[UnreachableCode]: off.}
  echo "[platform N/A] e2e_debug_fs_snoop_reads_monitor_depfile: " &
    "this gate requires the preload hooks backend"
  quit(0)

const FixtureSource = r"""
#include <dirent.h>
#include <errno.h>
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
  const char *input;
  const char *out_dir;
  int index;
};

static void read_file(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) exit(80);
  char buffer[64];
  if (read(fd, buffer, sizeof(buffer)) < 0) exit(81);
  close(fd);
}

static void write_file(const char *path, const char *message) {
  int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) exit(82);
  if (write(fd, message, strlen(message)) < 0) exit(83);
  close(fd);
}

static void require_missing_stat(const char *path, int use_lstat, int exit_code) {
  struct stat st;
  errno = 0;
  int status = use_lstat ? lstat(path, &st) : stat(path, &st);
  if (status != -1 || errno != ENOENT) exit(exit_code);
}

static void require_missing_open(const char *path, int exit_code) {
  errno = 0;
  int fd = open(path, O_RDONLY);
  if (fd >= 0) {
    close(fd);
    exit(exit_code);
  }
  if (errno != ENOENT) exit(exit_code);
}

static void *thread_main(void *raw) {
  struct thread_arg *arg = (struct thread_arg *)raw;
  char output_path[1024];
  char missing_path[1024];
  snprintf(output_path, sizeof(output_path), "%s/thread-%d.txt", arg->out_dir, arg->index);
  snprintf(missing_path, sizeof(missing_path), "%s/missing-thread-%d.txt", arg->out_dir, arg->index);
  read_file(arg->input);
  require_missing_stat(missing_path, 1, 84);
  write_file(output_path, "thread output\n");
  return NULL;
}

static int child_mode(const char *child_input) {
  if (getenv(REPRO_PRELOAD_ENV) == NULL) return 90;
  puts("fixture-child-stdout");
  fflush(stdout);
  fputs("fixture-child-stderr\n", stderr);
  read_file(child_input);
  require_missing_stat("missing-child-probe.txt", 1, 91);
  require_missing_open("missing-child-open.txt", 92);
  return 0;
}

static int fork_exec_child(const char *self, const char *child_input) {
  pid_t pid = fork();
  if (pid < 0) return 93;
  if (pid == 0) {
    execl(self, self, "--child", child_input, (char *)NULL);
    _exit(94);
  }
  int status = 0;
  if (waitpid(pid, &status, 0) < 0) return 95;
  if (!WIFEXITED(status)) return 96;
  return WEXITSTATUS(status);
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "--child") == 0) {
    if (argc != 3) return 64;
    return child_mode(argv[2]);
  }

  if (argc != 6 || strcmp(argv[1], "--mode") != 0 || strcmp(argv[2], "basic") != 0) {
    fputs("usage: fs-snoop-fixture --mode basic <input> <child-input> <out-dir>\n", stderr);
    return 65;
  }

  const char *input = argv[3];
  const char *child_input = argv[4];
  const char *out_dir = argv[5];

  puts("fixture-parent-stdout");
  fflush(stdout);
  fputs("fixture-parent-stderr\n", stderr);

  read_file(input);

  char missing_path[1024];
  snprintf(missing_path, sizeof(missing_path), "%s/missing-parent-probe.txt", out_dir);
  require_missing_stat(missing_path, 0, 68);
  require_missing_open(missing_path, 69);

  DIR *dir = opendir(out_dir);
  if (dir != NULL) {
    while (readdir(dir) != NULL) {}
    closedir(dir);
  }

  char output_path[1024];
  snprintf(output_path, sizeof(output_path), "%s/output.txt", out_dir);
  write_file(output_path, "parent output\n");

  pthread_t threads[2];
  struct thread_arg args[2];
  for (int i = 0; i < 2; i++) {
    args[i].input = input;
    args[i].out_dir = out_dir;
    args[i].index = i;
    pthread_create(&threads[i], NULL, thread_main, &args[i]);
  }
  for (int i = 0; i < 2; i++) {
    pthread_join(threads[i], NULL);
  }

  char *child_argv[] = {argv[0], "--child", (char *)child_input, NULL};
  pid_t pid = 0;
  int spawn_result = posix_spawn(&pid, argv[0], NULL, NULL, child_argv, environ);
  if (spawn_result != 0) return 66;
  int status = 0;
  waitpid(pid, &status, 0);
  if (!WIFEXITED(status)) return 67;
  int child_status = WEXITSTATUS(status);
  if (child_status != 0) return child_status;
  return fork_exec_child(argv[0], child_input);
}
"""

proc q(value: string): string =
  quoteShell(value)

proc runShell(command: string; cwd = getCurrentDir()): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  check res.code == 0
  if res.code != 0:
    checkpoint(res.output)
  res.output

proc shellCommand(args: openArray[string]; env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc compileFixture(sourcePath, outputPath: string) =
  discard requireSuccess(shellCommand(["cc", "-pthread", sourcePath, "-o", outputPath]))

proc hasRecord(records: seq[MonitorRecord];
               predicate: proc(record: MonitorRecord): bool): bool =
  for record in records:
    if predicate(record):
      return true

proc countRecordEvents(eventStream: string): int =
  for line in eventStream.splitLines:
    if line.contains("\"record\""):
      inc result

suite "e2e_debug_fs_snoop_reads_monitor_depfile":
  test "standalone and debug CLI read finalized monitor depfiles":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m11-fs-snoop", "")
    defer: removeDir(tempRoot)

    let binDir = tempRoot / "bin"
    let outDir = tempRoot / "out"
    createDir(binDir)
    createDir(outDir)

    # Test-Fixtures-In-Build-Graph M2: assert the graph-built monitor shim
    # (edge ``reprobuild.test_fixtures.monitor_shim``) instead of compiling
    # one per test; ``prepareMonitorTools`` resolves the identical path.
    let shimDylib = requireBinary(monitorShimPath(repoRoot),
      "reprobuild.test_fixtures.monitor_shim")
    # Test-Fixtures-In-Build-Graph M3: the standalone fs-snoop driver and the
    # ``repro`` CLI are now the SAME graph-built ``build/bin/repro`` image
    # (Executable-Consolidation M1 folded fs-snoop into ``repro internal
    # fs-snoop``). Assert the graph artifact exists instead of compiling either
    # one at test runtime; the fs-snoop invocation prepends the ``internal
    # fs-snoop`` selector below.
    let reproBin = requireBinary(
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
      "reprobuild.apps.repro")
    let fsSnoopBin = reproBin
    let fixtureSource = tempRoot / "fs_snoop_fixture.c"
    let fixtureBin = binDir / "fs-snoop-fixture"
    let inputPath = tempRoot / "input.txt"
    let childInputPath = tempRoot / "child-input.txt"
    let depfile = tempRoot / "basic.rdep"
    let debugDepfile = tempRoot / "debug.rdep"
    let eventsPath = tempRoot / "events.jsonl"
    let debugEventsPath = tempRoot / "debug.events.txt"

    writeFile(fixtureSource, FixtureSource)
    writeFile(inputPath, "parent input\n")
    writeFile(childInputPath, "child input\n")

    compileFixture(fixtureSource, fixtureBin)

    let fsOutput = requireSuccess(shellCommand([
      fsSnoopBin, "internal", "fs-snoop",
      "--depfile", depfile,
      "--events", "jsonl",
      "--event-stream", eventsPath,
      "--",
      fixtureBin, "--mode", "basic", inputPath, childInputPath, outDir
    ], [("REPRO_MONITOR_SHIM_LIB", shimDylib)]), repoRoot)
    check fsOutput.contains("fixture-parent-stdout")
    check fsOutput.contains("fixture-parent-stderr")
    check fsOutput.contains("fixture-child-stdout")
    check fsOutput.contains("fixture-child-stderr")

    let dep = readMonitorDepFile(depfile)
    check readFile(depfile)[0 .. 3] == "RMDF"
    check dep.records.len > 0
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrFileRead and record.path == inputPath)
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrFileRead and record.path == childInputPath)
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrPathProbe and record.path.contains("missing-parent-probe"))
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrPathProbe and record.path.contains("missing-child-probe"))
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrDirectoryEnumerate and
        record.observationKind == moDirectoryEnumerate and
        record.path == outDir and record.detail == "readdir")
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrFileWrite and record.path.endsWith("output.txt"))
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrProcessSpawn and record.childOsPid != 0)

    let eventStream = readFile(eventsPath)
    check eventStream.contains("\"kind\":\"observation\"")
    check eventStream.contains("\"kind\":\"summary\"")
    check countRecordEvents(eventStream) == dep.records.len

    let inspectJsonText = requireSuccess(shellCommand([
      reproBin, "debug", "fs-snoop", "inspect", depfile, "--format", "json"
    ]), repoRoot)
    let inspection = parseJson(inspectJsonText)
    check inspection["summary"]["recordCount"].getInt() == dep.records.len
    check inspection["records"].len == dep.records.len
    check inspectJsonText.contains(inputPath)
    check inspectJsonText.contains(childInputPath)
    check inspectJsonText.contains("directory-enumerate")

    discard requireSuccess(shellCommand([
      reproBin,
      "debug", "fs-snoop",
      "--depfile", debugDepfile,
      "--events", "text",
      "--event-stream", debugEventsPath,
      "--",
      fixtureBin, "--mode", "basic", inputPath, childInputPath, outDir
    ], [("REPRO_MONITOR_SHIM_LIB", shimDylib)]), repoRoot)
    let debugDep = readMonitorDepFile(debugDepfile)
    check debugDep.records.len > 0
    check readFile(debugEventsPath).contains("summary records=")
