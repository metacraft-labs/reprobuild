import std/[json, os, osproc, strutils, tempfiles, unittest]

import io_mon
from repro_test_support import requireBinary, monitorShimPath

when defined(macosx):
  const FixtureSource = r"""
#include <dirent.h>
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

static void write_create_truncate(const char *path, const char *message) {
  int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) exit(82);
  if (write(fd, message, strlen(message)) < 0) exit(83);
  close(fd);
}

static void write_append(const char *path, const char *message) {
  int fd = open(path, O_CREAT | O_APPEND | O_WRONLY, 0644);
  if (fd < 0) exit(84);
  if (write(fd, message, strlen(message)) < 0) exit(85);
  close(fd);
}

static void enumerate_dir(const char *path) {
  DIR *dir = opendir(path);
  if (dir == NULL) exit(86);
  while (readdir(dir) != NULL) {}
  closedir(dir);
}

static void *thread_main(void *raw) {
  struct thread_arg *arg = (struct thread_arg *)raw;
  char output_path[1024];
  char append_path[1024];
  char missing_path[1024];
  snprintf(output_path, sizeof(output_path), "%s/thread-%d.txt", arg->out_dir, arg->index);
  snprintf(append_path, sizeof(append_path), "%s/thread-append-%d.txt", arg->out_dir, arg->index);
  snprintf(missing_path, sizeof(missing_path), "%s/missing-thread-%d.txt", arg->out_dir, arg->index);
  read_file(arg->input);
  struct stat st;
  lstat(missing_path, &st);
  write_create_truncate(output_path, "thread truncate\n");
  write_append(append_path, "thread append\n");
  return NULL;
}

static int child_mode(const char *child_input, const char *out_dir) {
  if (getenv("DYLD_INSERT_LIBRARIES") == NULL) return 90;
  read_file(child_input);
  char missing_path[1024];
  char child_output[1024];
  snprintf(missing_path, sizeof(missing_path), "%s/missing-child-probe.txt", out_dir);
  snprintf(child_output, sizeof(child_output), "%s/child-output.txt", out_dir);
  struct stat st;
  lstat(missing_path, &st);
  write_create_truncate(child_output, "child output\n");
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "--child") == 0) {
    if (argc != 4) return 64;
    return child_mode(argv[2], argv[3]);
  }

  if (argc != 5) return 65;

  const char *input = argv[1];
  const char *child_input = argv[2];
  const char *out_dir = argv[3];
  const char *fixture_path = argv[4];

  read_file(input);

  char missing_path[1024];
  snprintf(missing_path, sizeof(missing_path), "%s/missing-parent-probe.txt", out_dir);
  struct stat st;
  stat(missing_path, &st);

  enumerate_dir(out_dir);

  char output_path[1024];
  char append_path[1024];
  char rename_path[1024];
  char symlink_path[1024];
  snprintf(output_path, sizeof(output_path), "%s/create-truncate.txt", out_dir);
  snprintf(append_path, sizeof(append_path), "%s/append.txt", out_dir);
  snprintf(rename_path, sizeof(rename_path), "%s/renamed-unsupported.txt", out_dir);
  snprintf(symlink_path, sizeof(symlink_path), "%s/symlink-unsupported.txt", out_dir);
  write_create_truncate(output_path, "parent create truncate\n");
  write_append(append_path, "parent append\n");

  pthread_t threads[5];
  struct thread_arg args[5];
  for (int i = 0; i < 5; i++) {
    args[i].input = input;
    args[i].out_dir = out_dir;
    args[i].index = i;
    pthread_create(&threads[i], NULL, thread_main, &args[i]);
  }
  for (int i = 0; i < 5; i++) {
    pthread_join(threads[i], NULL);
  }

  rename(output_path, rename_path);
  symlink(input, symlink_path);

  char *child_argv[] = {(char *)fixture_path, "--child", (char *)child_input, (char *)out_dir, NULL};
  pid_t pid = 0;
  int spawn_result = posix_spawn(&pid, fixture_path, NULL, NULL, child_argv, environ);
  if (spawn_result != 0) return 66;
  int status = 0;
  waitpid(pid, &status, 0);
  if (!WIFEXITED(status)) return 67;
  return WEXITSTATUS(status);
}
"""

  const
    OCreate = 0x0200'u32
    OTrunc = 0x0400'u32
    OAppend = 0x0008'u32

  proc q(value: string): string =
    quoteShell(value)

  proc runShell(command: string; cwd = getCurrentDir()):
      tuple[code: int; output: string] =
    let res = execCmdEx(command, workingDir = cwd)
    (code: res.exitCode, output: res.output)

  proc requireSuccess(command: string; cwd = getCurrentDir()): string =
    let res = runShell(command, cwd)
    check res.code == 0
    if res.code != 0:
      checkpoint(res.output)
    res.output

  proc shellCommand(args: openArray[string];
                    env: openArray[(string, string)] = []): string =
    var parts: seq[string] = @[]
    for (name, value) in env:
      parts.add(name & "=" & q(value))
    for arg in args:
      parts.add(q(arg))
    parts.join(" ")

  proc compileFixture(sourcePath, outputPath: string) =
    discard requireSuccess(shellCommand([
      "cc", "-pthread", sourcePath, "-o", outputPath
    ]))

  proc hasRecord(records: seq[MonitorRecord];
                 predicate: proc(record: MonitorRecord): bool): bool =
    for record in records:
      if predicate(record):
        return true

  proc countRecords(records: seq[MonitorRecord];
                    predicate: proc(record: MonitorRecord): bool): int =
    for record in records:
      if predicate(record):
        inc result

  proc hasGap(profile: MonitorBackendProfile; capability: MonitorCapability;
              required: bool): bool =
    for gap in profile.gaps:
      if gap.capability == capability and gap.required == required and
          gap.reason.len > 0:
        return true

  suite "e2e_macos_monitor_shim_event_taxonomy":
    test "real macOS shim records supported taxonomy and structured gaps":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m14-macos-monitor", "")
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
      # Test-Fixtures-In-Build-Graph M3: the standalone io-monitor driver is now
      # the graph-built ``build/bin/repro`` reached via ``internal io monitor``
      # (Executable-Consolidation M1). Assert the artifact exists instead of
      # compiling a wrapper; the invocation prepends ``internal io monitor``.
      let ioMonitorBin = requireBinary(
        repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
        "reprobuild.apps.repro")
      let fixtureSource = tempRoot / "macos_monitor_fixture.c"
      let fixtureBin = binDir / "macos-monitor-fixture"
      let inputPath = tempRoot / "input.txt"
      let childInputPath = tempRoot / "child-input.txt"
      let depfile = tempRoot / "taxonomy.rdep"
      let eventsPath = tempRoot / "taxonomy.events.jsonl"

      writeFile(fixtureSource, FixtureSource)
      writeFile(inputPath, "parent input\n")
      writeFile(childInputPath, "child input\n")

      compileFixture(fixtureSource, fixtureBin)

      discard requireSuccess(shellCommand([
        ioMonitorBin, "internal", "io", "monitor",
        "--depfile", depfile,
        "--events", "jsonl",
        "--event-stream", eventsPath,
        "--",
        fixtureBin, inputPath, childInputPath, outDir, fixtureBin
      ], [("REPRO_MONITOR_SHIM_LIB", shimDylib)]), repoRoot)

      check readFile(depfile)[0 .. 3] == "RMDF"
      let dep = readMonitorDepFile(depfile)
      let records = dep.records
      check dep.completeness == mcComplete
      check dep.backendFamily == mbfMacosHooks
      check records.len > 0

      let supportProfile = evaluateMonitorEvidence(dep,
        MacosMonitorShimTaxonomyCapabilities)
      check supportProfile.backendFamily == mbfMacosHooks
      check supportProfile.evidenceComplete
      check mcapEndpointSecurity notin supportProfile.supportedCapabilities
      check mcapHybrid notin supportProfile.supportedCapabilities
      check hasGap(supportProfile, mcapEndpointSecurity, false)
      check hasGap(supportProfile, mcapHybrid, false)
      check hasGap(supportProfile, mcapLibraryLoad, false)
      check hasGap(supportProfile, mcapAuthorizationEnforcement, false)

      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrBackendProfile and
          record.detail.contains("macos-interpose-hooks"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrCapabilityGap and record.path == "endpoint-security")

      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileRead and record.path == inputPath)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileRead and record.path == childInputPath)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrPathProbe and
          record.probeResult == prAbsent and
          record.path.endsWith("missing-parent-probe.txt"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrPathProbe and
          record.probeResult == prAbsent and
          record.path.endsWith("missing-child-probe.txt"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrDirectoryEnumerate and
          record.observationKind == moDirectoryEnumerate and
          record.path == outDir)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileOpen and
          record.observationKind == moFileWrite and
          record.path.endsWith("create-truncate.txt") and
          (record.flags and OCreate) != 0 and
          (record.flags and OTrunc) != 0)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileOpen and
          record.observationKind == moFileWrite and
          record.path.endsWith("append.txt") and
          (record.flags and OAppend) != 0)
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileWrite and record.path.endsWith("append.txt"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileWrite and record.path.endsWith("child-output.txt"))
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrProcessSpawn and
          record.observationKind == moExecute and
          record.path == fixtureBin and
          record.childOsPid != 0)
      check countRecords(records, proc(record: MonitorRecord): bool =
        record.kind == mrProcessStart) >= 2

      var seenSeq: seq[uint64] = @[]
      var threadedWrites = 0
      for record in records:
        check record.seq notin seenSeq
        seenSeq.add record.seq
        if record.kind == mrFileWrite and record.path.contains("thread-") and
            record.threadId != 0:
          inc threadedWrites
      check threadedWrites >= 5
      check dep.summary.eventLossCount == 0

      # rename/renameat is now a SUPPORTED macOS capability: io-mon fix
      # 60a72b6 added rename hooking on both the interpose and body-patch
      # backends, recording the move as an output write on the destination
      # path (the gnulib/autotools ``mv $@t $@`` atomic-write idiom). It is
      # accordingly part of ``MacosMonitorShimTaxonomyCapabilities`` and of the
      # macOS supported set in io-mon's ``capabilities.nim``. Requiring
      # ``mcapRename`` must therefore leave the evidence COMPLETE with no
      # capability gap (it used to be asserted as an unsupported gap before the
      # hook landed).
      check mcapRename in MacosMonitorShimTaxonomyCapabilities
      var renameRequired = MacosMonitorShimTaxonomyCapabilities
      renameRequired.incl mcapRename
      let renameRequiredProfile = evaluateMonitorEvidence(dep, renameRequired)
      check renameRequiredProfile.evidenceComplete
      check mcapRename in renameRequiredProfile.supportedCapabilities
      check not hasGap(renameRequiredProfile, mcapRename, true)
      # The fixture's ``rename(create-truncate.txt -> renamed-unsupported.txt)``
      # must surface as the captured destination output write, with the source
      # temp preserved in ``detail`` for provenance.
      check hasRecord(records, proc(record: MonitorRecord): bool =
        record.kind == mrFileWrite and
          record.observationKind == moFileWrite and
          record.path.endsWith("renamed-unsupported.txt") and
          record.detail.contains("from=") and
          record.detail.contains("create-truncate.txt"))

      let eventStream = readFile(eventsPath)
      check eventStream.contains("\"kind\":\"observation\"")
      check eventStream.contains("\"recordKind\":\"backend-profile\"")
      check eventStream.contains("\"recordKind\":\"capability-gap\"")

      let rendered = parseJson(renderMonitorDepFileJson(dep))
      check rendered["format"].getStr() == "RMDF"
      check rendered["backendFamily"].getStr() == "macos-interpose-hooks"
      check rendered["backendProfile"]["evidenceComplete"].getBool()
      check rendered["capabilityGaps"].len >= 4

when not defined(macosx):
  suite "e2e_macos_monitor_shim_event_taxonomy":
    test "macOS monitor shim event taxonomy is unsupported on non-macOS":
      skip()
