## A monitored root stays monitored when the monitoring process inherited
## another LD_PRELOAD hook library.
##
## WHAT THIS GUARDS. io-mon keeps a caller's preload and prepends its own shim
## (`fs_snoop.injectionValue`: "the injection never silently discards a
## caller's preload"), so a root launched by a `repro` that itself runs under
## an unrelated hook library starts with BOTH preloaded. Every agent session
## on the shared hosts runs that way: the agent harness preloads its
## command-trace shim into everything it starts. When io-mon's shim could not
## coexist with such a library, every monitored action an agent built lost
## its root, the capture graded as a loss, and the engine withheld every
## record (`cache-skip-monitor-loss`). reprobuild-pm issue
## `2026-11-01-monitored-root-reports-no-process-start-on-nixos-ci-bare-002`
## records it; the failing gates were the M17 peer-cache tests and
## `test_wrapped_monitor_evidence_ownership`.
##
## Two behaviours of that hook library broke io-mon's capture, each fixed in
## io-mon and consumed here through the `io-mon-src` pin:
##
## 1. It writes its trace through `syscall(SYS_write, ...)`, from its
##    constructor and while the program runs and exits. io-mon traps raw
##    `syscall()` calls and graded an unclassified number as
##    `event-loss ... libc raw syscall unsupported nr=1`, so the capture was
##    incomplete even though nothing was missed (io-mon fe50a98).
## 2. It defines `connect` -- a function io-mon also interposes -- and finds
##    the real one with `dlsym(RTLD_NEXT, "connect")`. io-mon exports `dlsym`
##    itself; when it answered RTLD_NEXT relative to the shim instead of the
##    caller, the hook library got its own `connect` back and recursed, so the
##    root hung or crashed (io-mon 23556a3, and 7a9b2f3 for RTLD_DEFAULT).
##
## WHY A STAND-IN LIBRARY (the mock this file uses, justified as the
## repository policy requires). The real library is agent-harbor's
## `libah_command_trace_shim.so`. Depending on it would make this gate pass
## or fail according to whether agent-harbor is installed on the host, and
## CI and a developer's shell do not have it. The defect is not about that
## library either: it is about io-mon meeting ANY preloaded hook library with
## those two properties. `HookLibrarySource` below is the smallest library
## that has exactly them -- a constructor and an exit handler that write
## through the raw syscall, and a `connect` interposer resolved through
## `dlsym(RTLD_NEXT)` and called from that constructor -- and nothing else. Everything else is
## real: the graph-built `repro` and monitor shim, the real dynamic loader,
## `/bin/sh` and `cat` as the monitored tree, and the on-disk capture.
##
## The library also proves it ran (the `stand-in-hook:` marker lines) so a
## pass cannot come from a library that silently failed to load, and it
## reports the case of `dlsym(RTLD_NEXT)` returning its own export instead of
## recursing into it, so that regression fails with a reason rather than a
## stack overflow. A hang of any other kind is turned into a failure by the
## `timeout` around the monitor.

import std/[os, osproc, strutils, tempfiles]

import std/unittest
import repro_test_support/reasoned_skip

import io_mon
from repro_test_support import requireBinary, monitorShimPath

const HostRunsGate = defined(linux)
  ## LD_PRELOAD composition and `dlsym(RTLD_NEXT)` are the ELF loader's
  ## semantics. macOS's interposition (`DYLD_INSERT_LIBRARIES`, `__interpose`)
  ## is a different mechanism with its own gates, and Windows has no preload.

const PlatformSkipReason =
  "[platform N/A] inherited_preload_hook_library_keeps_root_monitored: " &
    "LD_PRELOAD hook-library composition exists only on Linux"

const MonitorTimeoutSeconds = 120
  ## The monitored command is one `cat`; it finishes in well under a second.
  ## The limit exists only so that a root that never returns -- the recursion
  ## variant of this defect -- fails the case instead of blocking the suite.

const HookLibrarySource = r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

typedef int (*connect_fn)(int, const struct sockaddr *, socklen_t);

static connect_fn next_connect;

/* Write through glibc's syscall(3) rather than write(2), as the hook library
   this stands in for does. io-mon traps these raw calls and must classify
   SYS_write instead of grading it as unsupported. */
static void raw_note(const char *text) {
  syscall(SYS_write, 2, text, strlen(text));
}

/* A `connect` interposer, like every hook library that traces IPC. io-mon
   interposes `connect` too, so the next definition after this library is
   io-mon's (or libc's), never this one. The constructor calls
   `hook_connect` directly: a call to `connect` would bind to the first
   definition in global load order, which in the monitored root is io-mon's. */
static int hook_connect(int fd, const struct sockaddr *addr, socklen_t len);

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
  return hook_connect(fd, addr, len);
}

/* This library's own `connect`, bound locally (hidden), so the check below
   compares against this definition and not whichever one the loader puts
   first. */
extern int self_connect(int, const struct sockaddr *, socklen_t)
  __attribute__((alias("connect"), visibility("hidden")));

static int hook_connect(int fd, const struct sockaddr *addr, socklen_t len) {
  if (next_connect == NULL) {
    next_connect = (connect_fn)dlsym(RTLD_NEXT, "connect");
  }
  if (next_connect == NULL || next_connect == self_connect) {
    /* Calling it would recurse forever: report instead. */
    raw_note("stand-in-hook: dlsym(RTLD_NEXT, connect) did not return the next definition\n");
    errno = ENOSYS;
    return -1;
  }
  return next_connect(fd, addr, len);
}

/* Write an exit record through the raw syscall, as a command-trace library
   does. Registered from the constructor, so it runs inside exit() while every
   preloaded library -- the monitor shim included -- is still initialised and
   recording. A constructor-time write alone does not exercise the shim's
   raw-syscall classification (measured at io-mon ac06360d: no loss), which is
   why the gate needs this one. */
static void stand_in_hook_exit(void) {
  raw_note("stand-in-hook: exit\n");
}

__attribute__((constructor))
static void stand_in_hook_init(void) {
  raw_note("stand-in-hook: loaded\n");
  atexit(stand_in_hook_exit);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    raw_note("stand-in-hook: socket failed\n");
    return;
  }
  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, "/nonexistent/stand-in-hook-control.sock",
          sizeof(addr.sun_path) - 1);
  /* Nothing listens at that path, so ENOENT is the expected answer: what
     matters is that the call reached the next definition and returned. */
  if (hook_connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0 || errno != ENOENT) {
    raw_note("stand-in-hook: connect did not fail with ENOENT\n");
  } else {
    raw_note("stand-in-hook: connect reached the next definition\n");
  }
  close(fd);
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

proc hasRecord(records: seq[MonitorRecord];
               predicate: proc(record: MonitorRecord): bool): bool =
  for record in records:
    if predicate(record):
      return true

proc lossDetails(records: seq[MonitorRecord]): string =
  ## The event-loss records, for the failure message: they name the cause
  ## (an unclassified raw syscall, a spawn child missing its process-start).
  for record in records:
    if record.kind == mrEventLoss:
      result.add(record.detail & "\n")

template gatedTest(name: string; body: untyped) =
  ## Register the case on every host and skip it with a visible reason where
  ## the backend does not exist. A runtime `if` on a constant keeps the body
  ## type-checked everywhere.
  test name:
    if HostRunsGate:
      body
    else:
      skip(PlatformSkipReason)

suite "inherited_preload_hook_library_keeps_root_monitored":
  gatedTest "a root launched under an inherited hook-library preload is captured whole":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-inherited-preload", "")
    defer: removeDir(tempRoot)

    let shimLibrary = requireBinary(monitorShimPath(repoRoot),
      "reprobuild.test_fixtures.monitor_shim")
    let reproBin = requireBinary(
      repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
      "reprobuild.apps.repro")

    let hookSource = tempRoot / "stand_in_hook.c"
    let hookLibrary = tempRoot / "libstand_in_hook.so"
    let inputPath = tempRoot / "input.txt"
    let depfile = tempRoot / "root.iomon"
    writeFile(hookSource, HookLibrarySource)
    writeFile(inputPath, "read by the monitored root\n")

    let compile = execCmdEx(shellCommand(["cc", "-shared", "-fPIC", "-O1",
      "-o", hookLibrary, hookSource, "-ldl"]))
    checkpoint(compile.output)
    require compile.exitCode == 0

    # The monitoring `repro` itself runs with the hook library preloaded,
    # exactly as under the agent harness: io-mon then launches the root with
    # `LD_PRELOAD=<monitor shim>:<hook library>`.
    let monitor = execCmdEx(shellCommand([
      "timeout", "--kill-after=10", $MonitorTimeoutSeconds,
      reproBin, "internal", "io", "monitor",
      "--depfile", depfile,
      "--",
      "/bin/sh", "-c", "cat " & q(inputPath) & " >/dev/null"
    ], [("REPRO_MONITOR_SHIM_LIB", shimLibrary),
        ("LD_PRELOAD", hookLibrary)]), workingDir = repoRoot)
    checkpoint("monitor exit=" & $monitor.exitCode & "\n" & monitor.output)

    # 124/137 are `timeout`'s: the root never returned.
    check monitor.exitCode notin [124, 137]
    require monitor.exitCode == 0

    # Positive control: the stand-in loaded and its interposer chained on.
    # Without this a library that never loaded would pass every check below.
    check monitor.output.contains("stand-in-hook: loaded")
    check monitor.output.contains(
      "stand-in-hook: connect reached the next definition")
    check not monitor.output.contains("did not return the next definition")
    check monitor.output.contains("stand-in-hook: exit")

    let dep = readMonitorDepFile(depfile)
    checkpoint("event-loss records:\n" & lossDetails(dep.records))
    # The root and its `cat` each reported a process-start ...
    check dep.summary.processCount >= 2
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrProcessStart)
    # ... the read the root's tree performed was observed ...
    let canonicalInput = expandFilename(inputPath)
    check hasRecord(dep.records, proc(record: MonitorRecord): bool =
      record.kind == mrFileRead and record.path == canonicalInput)
    # ... and nothing was lost, so the engine may publish the capture.
    check dep.summary.eventLossCount == 0
    check dep.completeness == mcComplete
