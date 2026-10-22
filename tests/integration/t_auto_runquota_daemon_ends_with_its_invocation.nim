## A `runquotad` that `repro` starts for its own invocation does not outlive
## that invocation, however it ends, and holds none of its descriptors above 2.
##
## THE DEFECT THIS EXISTS FOR (reprobuild-pm issue
## `2026-09-28-auto-started-runquotad-outlives-a-terminated-repro-and-holds-its-callers-pipe`).
## `e2e_repro_dev_watch_and_service_events` started `repro dev` through
## `startProcess` with its default pipes, gave up waiting for it, and
## `terminate()`d it. The `runquotad` that `repro dev` had auto-started
## survived the SIGTERM -- `releaseAutoRunQuotaProcess` runs from `defer`
## blocks, which a signal does not run -- and it was still holding inherited
## copies of `repro dev`'s stdout pipe (Nim's POSIX `osproc` creates its pipes
## without `O_CLOEXEC`, so the spawned process keeps the original pipe ends at
## descriptors above 2 after `dup2`ing them onto 0/1/2, and `runquotad`
## inherited them in turn). The test's `readAll()` then waited 30 minutes for
## an end of file that could only come when the orphan died.
##
## THE DECIDED BEHAVIOUR is reprobuild-pm `spec/RunQuota-Host-Configuration.md`,
## subsection "\"Terminated when the top-level build ends\" means however it
## ends": `repro` forwards SIGTERM/SIGINT/SIGHUP/SIGQUIT to the daemon it owns
## and then lets the signal take its previous course; the daemon is started
## with `RUNQUOTA_EXIT_WITH_PARENT=1` and stops when it is re-parented (the
## only half that covers SIGKILL); and every descriptor above 2 is
## close-on-exec across the spawn.
##
## HOW THE ISSUE'S SHAPE IS REPRODUCED. This binary re-executes ITSELF as a
## child (`AutoRunQuotaChildModeVar` selects the child arm) through
## `startProcess` with the DEFAULT options -- the same call shape the e2e test
## used to start `repro dev`, so the child holds the same extra, non-cloexec
## copies of its own stdout pipe above descriptor 2. The child then calls the
## real `startAutoRunQuotaIfNeeded` on its real spawn arm, prints the daemon's
## pid, and sleeps until it is signalled. The parent also hands the child a
## SENTINEL descriptor (a file it opened without `O_CLOEXEC`), standing for
## "anything else the invocation's own caller leaked into it".
##
## THE THREE PRIMARY CASES, each against a fresh child and a fresh daemon:
##
##   (a) SIGTERM to the child -> the daemon is gone within a bounded window,
##       AND the child's stdout reaches end of file within a bounded window.
##       The second clause is the one the e2e test hung on; it is what a
##       caller of `repro` actually observes.
##   (b) While the child is alive, the daemon's `/proc/<pid>/fd` holds no
##       descriptor referring to the child's stdio pipes or to the sentinel.
##   (c) SIGKILL to the child -> the daemon is gone within a bounded window.
##       No handler in the child can see SIGKILL, so this is the daemon's own
##       parent watch, and it REQUIRES A `runquotad` THAT HONOURS
##       `RUNQUOTA_EXIT_WITH_PARENT` (runquota's
##       `tests/integration/t_exits_when_its_parent_dies.nim`). The test points
##       `RUNQUOTAD_BIN` at the sibling checkout's `../runquota/build/bin/runquotad`
##       when the variable is not already set, so build the sibling first
##       (`cd ../runquota && just build`); an older `runquotad` on `PATH` fails
##       this case, by design, rather than passing it vacuously.
##
## SIGNAL CONTROLS check that ignored SIGHUP leaves both processes alive,
## ordinary and SA_SIGINFO callbacks retain their exit behavior, and a
## one-shot handler retains SA_RESETHAND's default action on the next signal.
##
## EVERY WAIT IS BOUNDED. A daemon that does not go, or a pipe that never
## reaches end of file, is the failure being tested for, so nothing here may
## block on either: the stdout read is a `poll` loop with a deadline, and the
## daemon's exit is polled through `/proc`. Whatever a case starts is killed in
## a `finally`, pass or fail -- a red run must not leave the very orphan it
## detected behind.
##
## THE DAEMON IS NOT OUR CHILD, so its end is observed through `/proc` rather
## than `waitpid`: it is gone when its `/proc/<pid>/stat` is gone, names a
## zombie (a subreaper such as a test runner may not have reaped it yet), or
## names a different start time (the pid was reused).
##
## MOCK POLICY -- NO MOCKS. The real test binary as the invocation, the real
## `startAutoRunQuotaIfNeeded` on its real spawn branch, the real `runquotad`
## binary, real pipes from the real `osproc`, real signals from `kill(2)`, and
## the kernel's own `/proc` as the verdict. The one thing arranged rather than
## produced is the branch: `RUNQUOTA_SOCKET` names a path that does not exist,
## so both of `startAutoRunQuotaIfNeeded`'s early returns (which test
## reachability) fall through and the spawn arm is taken deterministically,
## exactly as `t_derived_daemon_ipc_trust` does it.
##
## LINUX ONLY. The verdicts read `/proc`; the behaviour itself is POSIX, but
## macOS has no `/proc` to read it from, and Windows deliberately keeps its
## shared per-user daemon running.

import std/[monotimes, os, osproc, strtabs, strutils, times, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support/owned_daemon_signals

when defined(linux):
  import std/posix
  import repro_test_support/process_fixtures
  from repro_core/paths import runquotaEndpointPath
  # Fixtures install real POSIX dispositions before ownership is acquired.
  # The handlers use only _exit, so their verdict survives signal context.
  {.emit: """
  #include <signal.h>
  #include <unistd.h>
  static void rq_test_previous(int sig) { _exit(sig == SIGTERM ? 42 : 43); }
  static volatile sig_atomic_t rq_test_once_count = 0;
  static void rq_test_returning(int sig) { (void)sig; rq_test_once_count++; }
  static int rq_test_once_calls(void) { return rq_test_once_count; }
  #include <sys/prctl.h>
  static int rq_test_subreaper(void) { int old = 0; return prctl(PR_GET_CHILD_SUBREAPER, &old) == 0 ? old : -1; }
  static int rq_test_set_subreaper(int value) { return prctl(PR_SET_CHILD_SUBREAPER, value); }
  static int rq_test_raw_child(void) {
    int ready[2]; char byte;
    if (pipe(ready) != 0) return -1;
    int pid = fork();
    if (pid == 0) { close(ready[0]); signal(SIGTERM, SIG_DFL); write(ready[1], "r", 1); close(ready[1]); for (;;) pause(); }
    close(ready[1]);
    if (pid > 0) while (read(ready[0], &byte, 1) < 0 && errno == EINTR) {}
    close(ready[0]);
    return pid;
  }
  static void rq_test_siginfo(int sig, siginfo_t *info, void *context) {
    (void)context;
    _exit(sig == SIGTERM && info != NULL && info->si_signo == sig ? 44 : 45);
  }
  static struct sigaction rq_test_chld_saved, rq_test_chld_expected;
  static int rq_test_chld_install(int mode) {
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask); sigaddset(&action.sa_mask, SIGUSR1);
    action.sa_handler = mode == 5 ? SIG_IGN : SIG_DFL;
    action.sa_flags = mode == 6 ? SA_NOCLDWAIT : 0;
    if (sigaction(SIGCHLD, &action, &rq_test_chld_saved) != 0) return 0;
    return sigaction(SIGCHLD, NULL, &rq_test_chld_expected) == 0;
  }
  static int rq_test_chld_unchanged(void) {
    struct sigaction action;
    if (sigaction(SIGCHLD, NULL, &action) != 0) return 0;
    if (action.sa_handler != rq_test_chld_expected.sa_handler ||
        action.sa_flags != rq_test_chld_expected.sa_flags) return 0;
    for (int sig = 1; sig < NSIG; sig++)
      if (sigismember(&action.sa_mask, sig) != sigismember(&rq_test_chld_expected.sa_mask, sig)) return 0;
    return 1;
  }
  static void rq_test_chld_restore(void) { sigaction(SIGCHLD, &rq_test_chld_saved, NULL); }
  static void rq_test_disposition(int mode) {
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    if (mode == 1) {
      action.sa_handler = SIG_IGN;
      action.sa_flags = SA_SIGINFO;
      sigaction(SIGHUP, &action, NULL);
    } else if (mode == 2) {
      action.sa_handler = rq_test_previous;
      sigaction(SIGTERM, &action, NULL);
    } else if (mode == 3) {
      action.sa_sigaction = rq_test_siginfo;
      action.sa_flags = SA_SIGINFO;
      sigaction(SIGTERM, &action, NULL);
    } else if (mode == 4) {
      action.sa_handler = rq_test_returning;
      action.sa_flags = SA_RESETHAND;
      sigaction(SIGTERM, &action, NULL);
    }
  }
  """.}
  proc installAutoReap(mode: cint): cint {.importc: "rq_test_chld_install", nodecl.}
  proc autoReapUnchanged(): cint {.importc: "rq_test_chld_unchanged", nodecl.}
  proc restoreAutoReap() {.importc: "rq_test_chld_restore", nodecl.}
  proc onceCalls(): cint {.importc: "rq_test_once_calls", nodecl.}
  proc subreaper(): cint {.importc: "rq_test_subreaper", nodecl.}
  proc setSubreaper(value: cint): cint {.importc: "rq_test_set_subreaper", nodecl.}
  proc rawChild(): cint {.importc: "rq_test_raw_child", nodecl.}
  proc setTestDisposition(mode: cint) {.importc: "rq_test_disposition", nodecl.}

import repro_cli_support
import repro_core/ambient_execution

const
  AutoRunQuotaChildModeVar = "REPRO_TEST_AUTO_RUNQUOTA_CHILD_SCRATCH"
    ## Set (to a scratch directory) only in the re-executed child. Its
    ## presence is what selects the child arm below.
  DaemonPidMarker = "auto-runquota-daemon-pid="
  ChildLifetimeMillis = 120_000
    ## How long a child waits to be signalled before it releases its daemon
    ## and exits on its own -- a backstop, so a parent that died mid-case
    ## does not leave a child (and its daemon) sleeping forever.
  StartupBudgetMillis = 60_000
    ## Child start, plus `startAutoRunQuotaIfNeeded`'s own readiness wait
    ## (up to 300 x 50 ms), plus slack for a loaded host.
  DaemonExitBudgetMillis = 15_000
    ## The daemon's orderly shutdown joins a worker pool and drains its
    ## SQLite writers; runquota's own SIGTERM tests allow the same 15 s. The
    ## parent watch adds one poll interval (200 ms) to it. A daemon that
    ## does not stop at all overruns this by an unbounded margin -- the
    ## orphans this file is about lived for hours.
  EofBudgetMillis = 15_000
    ## From the child's death to end of file on its stdout. With no other
    ## holder of the pipe, end of file is immediate; the budget only has to
    ## outlast the daemon's own shutdown, after which nothing can hold it.

proc childArm() =
  ## THE INVOCATION. Starts a daemon the way every `repro` build path does,
  ## announces its pid, and waits to be ended by the parent's signal.
  let scratch = getEnv(AutoRunQuotaChildModeVar)
  when defined(linux):
    setTestDisposition(cint(parseInt(getEnv("REPRO_TEST_OWNED_SIGNAL_MODE", "0"))))
  putEnv("RUNQUOTA_SOCKET", scratch / "no-such-runquota.sock")
  putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
  when defined(linux):
    let autoReapMode = parseInt(getEnv("REPRO_TEST_OWNED_AUTOREAP_MODE", "0"))
    if autoReapMode != 0:
      # A real executable marker distinguishes refusal BEFORE spawn from a
      # readiness failure after the child was already launched.
      let marker = scratch / "daemon-was-executed"
      let wrapper = scratch / "marked-runquotad"
      let realDaemon = getEnv("RUNQUOTAD_BIN")
      doAssert realDaemon.len > 0
      writeFile(wrapper, "#!/bin/sh\nprintf started > " & quoteShell(marker) &
        "\nexec " & quoteShell(realDaemon) & " \"$@\"\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("RUNQUOTAD_BIN", wrapper)
      doAssert installAutoReap(cint(autoReapMode)) == 1
      var daemon: owned(Process)
      var message = ""
      var registryAccepted = false
      var registeredCount = -1
      var hookedAfterRegistration = false
      var raw: cint = -1
      var dispositionPreserved = false
      try:
        try:
          daemon = startAutoRunQuotaIfNeeded(false)
        except OSError as error:
          message = error.msg
        finally:
          if daemon != nil:
            releaseAutoRunQuotaProcess(daemon)
        raw = rawChild()
        doAssert raw > 0
        registryAccepted = registerOwnedDaemon(int(raw))
        registeredCount = ownedDaemonCount()
        hookedAfterRegistration = ownedDaemonSignalIsHooked(SIGTERM)
        # Even RED must remove the unsafe entry BEFORE it kills the child.
        unregisterOwnedDaemon(int(raw))
        dispositionPreserved = autoReapUnchanged() == 1
      finally:
        if raw > 0:
          unregisterOwnedDaemon(int(raw))
          discard kill(Pid(raw), SIGKILL)
          var status: cint
          # Both dispositions auto-reap: bounded wait until ECHILD also
          # proves we preserved the kernel's original child-exit semantics.
          var reaped = false
          for _ in 0 ..< 500:
            let waited = waitpid(Pid(raw), status, WNOHANG)
            if waited < 0 and errno == ECHILD:
              reaped = true
              break
            if waited == Pid(raw): break
            sleep(10)
          restoreAutoReap()
          doAssert reaped
        else:
          restoreAutoReap()
      echo "auto-reap probe: mode=", autoReapMode, " daemonExecuted=", fileExists(marker),
        " registryAccepted=", registryAccepted, " registeredCount=", registeredCount,
        " hooked=", hookedAfterRegistration, " sigactionPreserved=", dispositionPreserved,
        " diagnostic=", message
      flushFile(stdout)
      doAssert not registryAccepted, "auto-reaped child was accepted into signal registry"
      doAssert registeredCount == 0 and not hookedAfterRegistration, "refused registration mutated registry or handlers"
      doAssert ownedDaemonCount() == 0
      doAssert dispositionPreserved, "SIGCHLD disposition or mask changed"
      doAssert "SIGCHLD" in message, "missing clear pre-spawn ownership diagnostic: " & message
      doAssert not fileExists(marker), "runquotad executed despite unsupported child ownership"
      echo "auto-reap refusal preserved SIGCHLD and spawned no daemon"
      flushFile(stdout)
      quit 0
  var daemon = startAutoRunQuotaIfNeeded(false)
  if daemon == nil:
    echo "auto-runquota-child: startAutoRunQuotaIfNeeded started no daemon"
    flushFile(stdout)
    quit 3
  echo DaemonPidMarker, processID(daemon)
  flushFile(stdout)
  var waited = 0
  while waited < ChildLifetimeMillis:
    sleep(100)
    waited += 100
  releaseAutoRunQuotaProcess(daemon)
  quit 0

if existsEnv(AutoRunQuotaChildModeVar):
  childArm()

when defined(linux):
  proc note(text: string) =
    ## Evidence, printed whether the case passes or fails: the pids, what
    ## each process holds and how long each end took, so a green run can be
    ## read for what it actually measured.
    echo "    ", text

  proc millisLeft(deadline: MonoTime): int =
    max(0, int((deadline - getMonoTime()).inMilliseconds))

  proc readSome(fd: cint; deadline: MonoTime; text: var string): int =
    ## One bounded read: waits for readability no later than `deadline`.
    ## Answers the byte count, 0 for end of file, and -1 for "nothing
    ## arrived before the deadline".
    var descriptor = TPollfd(fd: fd, events: POLLIN, revents: 0)
    while true:
      let left = millisLeft(deadline)
      let ready = poll(addr descriptor, Tnfds(1), cint(left))
      if ready < 0:
        if errno == EINTR:
          continue
        raiseOSError(osLastError())
      if ready == 0:
        return -1
      break
    var buffer: array[4096, char]
    while true:
      let got = read(fd, addr buffer[0], buffer.len)
      if got < 0:
        if errno == EINTR:
          continue
        raiseOSError(osLastError())
      for i in 0 ..< got:
        text.add(buffer[i])
      return got

  proc readDaemonPid(child: Process; output: var string): int =
    ## The pid line the child prints, read under `StartupBudgetMillis`.
    ## Raises with everything the child said when the line does not come.
    let fd = cint(child.outputHandle)
    let deadline = getMonoTime() + initDuration(milliseconds = StartupBudgetMillis)
    while true:
      for line in output.splitLines():
        if line.startsWith(DaemonPidMarker):
          return parseInt(line[DaemonPidMarker.len .. ^1].strip())
      let got = readSome(fd, deadline, output)
      if got <= 0:
        raise newException(IOError,
          "the child did not report a daemon pid (" &
          (if got == 0: "end of file" else: "timed out") & "); it said:\n" &
          output)

  proc drainsToEofWithin(child: Process; budgetMillis: int;
                         output: var string): bool =
    ## Reads the child's stdout until end of file or until the budget runs
    ## out. `true` only for end of file -- the outcome a caller that reads
    ## `repro`'s output with `readAll()` waits for.
    let fd = cint(child.outputHandle)
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMillis)
    while true:
      let got = readSome(fd, deadline, output)
      if got == 0:
        return true
      if got < 0:
        return false

  proc processStartTime(pid: int): string =
    ## Field 22 of `/proc/<pid>/stat`, the start time in clock ticks, or ""
    ## when the process is gone or is a zombie. Parsed past the LAST `)`
    ## because `comm` may contain spaces and parentheses.
    try:
      let stat = readFile("/proc/" & $pid & "/stat")
      let close = stat.rfind(')')
      if close < 0:
        return ""
      let fields = stat[close + 1 .. ^1].splitWhitespace()
      # fields[0] is the state (field 3); the start time is field 22.
      if fields.len < 20 or fields[0] == "Z" or fields[0] == "X":
        return ""
      result = fields[19]
    except IOError, OSError:
      result = ""

  proc isStillThere(pid: int; startTime: string): bool =
    startTime.len > 0 and processStartTime(pid) == startTime

  proc goneWithin(pid: int; startTime: string; budgetMillis: int): bool =
    let deadline = getMonoTime() + initDuration(milliseconds = budgetMillis)
    while isStillThere(pid, startTime):
      if getMonoTime() >= deadline:
        return false
      sleep(25)
    true

  proc killIfStillThere(pid: int; startTime: string) =
    ## The cleanup that must run whatever the verdict: a red run must not
    ## leave behind the orphan it detected. Identity-checked so a reused
    ## pid is never signalled.
    if pid > 0 and isStillThere(pid, startTime):
      discard kill(Pid(pid), SIGKILL)
      discard goneWithin(pid, startTime, 5_000)

  proc pipeInode(fd: FileHandle): string =
    var st: Stat
    if fstat(cint(fd), st) != 0:
      raiseOSError(osLastError())
    "pipe:[" & $st.st_ino & "]"

  proc inheritedDescriptors(pid: int; forbidden: openArray[string]): seq[string] =
    ## Every descriptor above 2 of `pid` whose target is one of
    ## `forbidden`, as "fd -> target".
    for kind, path in walkDir("/proc/" & $pid & "/fd"):
      let name = path.extractFilename
      var fd = -1
      try:
        fd = parseInt(name)
      except ValueError:
        continue
      if fd <= 2:
        continue
      var target = ""
      try:
        target = expandSymlink(path)
      except OSError:
        continue
      if target in forbidden:
        result.add($fd & " -> " & target)

  type Invocation = object
    scratch: string
    sentinelPath: string
    daemonDir: string
    sentinelFd: cint
    child: Process
    childOutput: string
    daemonPid: int
    daemonStart: string

  proc runquotadForChild(): string =
    ## RUNQUOTAD_BIN when the caller set one; otherwise the sibling
    ## checkout's build, which is the one that carries
    ## `RUNQUOTA_EXIT_WITH_PARENT`. Empty when neither exists.
    result = getEnv("RUNQUOTAD_BIN", "")
    if result.len > 0:
      return
    let sibling = currentSourcePath().parentDir.parentDir.parentDir.parentDir /
      "runquota" / "build" / "bin" / "runquotad"
    if fileExists(sibling):
      result = sibling

  proc startInvocation(result: var Invocation; tag: string; signalMode = 0) =
    result.scratch = getTempDir() / ("repro-rq-owned-" & tag & "-" &
      $getCurrentProcessId())
    releaseDirAtProcessExit(result.scratch)
    removeDir(result.scratch)
    createDir(result.scratch)
    # THE SENTINEL: a descriptor this process holds WITHOUT close-on-exec, so
    # the child inherits it as a caller's leak would reach `repro`. The
    # daemon must not end up with it.
    result.sentinelPath = result.scratch / "sentinel"
    writeFile(result.sentinelPath, "")
    result.sentinelFd = posix.open(cstring(result.sentinelPath), O_RDONLY)
    if result.sentinelFd < 0:
      raiseOSError(osLastError())
    # Compared against `/proc/<pid>/fd` link targets, which the kernel
    # spells canonically; a temp directory reached through a symlink would
    # otherwise never match and the check would pass vacuously.
    result.sentinelPath = expandSymlink("/proc/self/fd/" & $result.sentinelFd)
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      env[key] = value
    env[AutoRunQuotaChildModeVar] = result.scratch
    env["REPRO_TEST_OWNED_SIGNAL_MODE"] = $signalMode
    let runquotad = runquotadForChild()
    if runquotad.len > 0:
      env["RUNQUOTAD_BIN"] = runquotad
    # DEFAULT OPTIONS, ON PURPOSE: the call shape that leaves the child with
    # extra non-cloexec copies of its own pipe ends above 2. Uncontrolled
    # because the binary is this test itself, which no execution profile
    # describes.
    result.child = uncontrolledStartProcess(getAppFilename(), env = env)
    terminateAtProcessExit(processID(result.child))
    result.daemonDir = runquotaEndpointPath(
      "reprobuild-runquota-" & $processID(result.child)).parentDir
    releaseDirAtProcessExit(result.daemonDir)
    result.daemonPid = readDaemonPid(result.child, result.childOutput)
    result.daemonStart = processStartTime(result.daemonPid)
    note(tag & ": child pid=" & $processID(result.child) &
      " daemon pid=" & $result.daemonPid & " runquotad=" &
      (if runquotad.len > 0: runquotad else: "<discovered>"))

  proc cleanUp(inv: var Invocation) =
    # Startup may fail before the pid marker was read. Discover children
    # while their invocation still exists, so even a red startup cannot
    # leave an unfixed daemon behind after the invocation is killed.
    if inv.child != nil and inv.daemonPid == 0:
      try:
        let children = readFile("/proc/" & $processID(inv.child) &
          "/task/" & $processID(inv.child) & "/children")
        for childPid in children.splitWhitespace():
          let pid = parseInt(childPid)
          killIfStillThere(pid, processStartTime(pid))
      except IOError, OSError, ValueError:
        discard
    killIfStillThere(inv.daemonPid, inv.daemonStart)
    if inv.child != nil:
      if inv.child.running:
        inv.child.kill()
      discard inv.child.waitForExit()
      inv.child.close()
      inv.child = nil
    if inv.sentinelFd >= 0:
      discard posix.close(inv.sentinelFd)
      inv.sentinelFd = -1
    if inv.daemonDir.len > 0:
      removeDir(inv.daemonDir)
    removeDir(inv.scratch)

  proc runquotadAvailable(): bool =
    runquotadForChild().len > 0 or findRunQuotaDaemonBin().len > 0

  proc checkAutoReapRefusal(mode: int) =
    doAssert runquotadAvailable(), "real runquotad is required on Linux"
    var inv = Invocation(sentinelFd: -1)
    try:
      inv.scratch = getTempDir() / ("repro-rq-autoreap-" & $mode & "-" & $getCurrentProcessId())
      releaseDirAtProcessExit(inv.scratch)
      removeDir(inv.scratch)
      createDir(inv.scratch)
      let env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env[AutoRunQuotaChildModeVar] = inv.scratch
      env["REPRO_TEST_OWNED_AUTOREAP_MODE"] = $mode
      env["RUNQUOTAD_BIN"] = runquotadForChild()
      # This self-executing fixture has no typed execution profile.
      inv.child = uncontrolledStartProcess(getAppFilename(), env = env)
      terminateAtProcessExit(processID(inv.child))
      inv.daemonDir = runquotaEndpointPath("reprobuild-runquota-" & $processID(inv.child)).parentDir
      releaseDirAtProcessExit(inv.daemonDir)
      let deadline = getMonoTime() + initDuration(milliseconds = StartupBudgetMillis)
      var eof = false
      while millisLeft(deadline) > 0:
        let got = readSome(cint(inv.child.outputHandle), deadline, inv.childOutput)
        if got == 0:
          eof = true
          break
        if got < 0: break
      note(inv.childOutput)
      doAssert eof, "bounded fixture output did not close"
      doAssert inv.child.waitForExit() == 0, inv.childOutput
      doAssert "auto-reap refusal preserved SIGCHLD and spawned no daemon" in inv.childOutput
      doAssert not fileExists(inv.scratch / "daemon-was-executed")
    finally:
      cleanUp(inv)


suite "an auto-started runquotad ends with its invocation":

  test "readiness observation leaves an exited registered child waitable":
    when defined(linux):
      var child = uncontrolledStartProcess("/bin/sh", args = @["-c", "exit 23"])
      terminateAtProcessExit(processID(child))
      let pid = Pid(processID(child))
      var reaped = false
      try:
        doAssert registerOwnedDaemon(int(pid))
        let deadline = getMonoTime() + initDuration(seconds = 5)
        while ownedDaemonStillRunning(child) and getMonoTime() < deadline:
          sleep(10)
        doAssert not ownedDaemonStillRunning(child), "child did not exit promptly"
        check ownedDaemonCount() == 1
        unregisterOwnedDaemon(int(pid))
        var status: cint
        let waited = waitpid(pid, status, WNOHANG)
        reaped = waited == pid
        check waited == pid
        if reaped:
          check WIFEXITED(status)
          check WEXITSTATUS(status) == 23
      finally:
        unregisterOwnedDaemon(int(pid))
        if not reaped:
          var status: cint
          let observed = waitpid(pid, status, WNOHANG)
          if observed == 0:
            discard kill(pid, SIGKILL)
            while waitpid(pid, status, 0) < 0 and errno == EINTR:
              discard
        child.close()
    else:
      skip("Linux child ownership observation uses POSIX waitpid")

  test "(a) SIGTERM to the invocation stops its daemon and releases its stdout":
    when defined(linux):
      doAssert runquotadAvailable()
      block:
        var inv = Invocation(sentinelFd: -1)
        try:
          startInvocation(inv, "term")
          doAssert inv.daemonStart.len > 0
          doAssert kill(Pid(processID(inv.child)), SIGTERM) == 0
          let childExit = inv.child.waitForExit()
          note("child exit=" & $childExit)
          # THE SIGNAL STILL ENDS THE INVOCATION, and its status still names
          # SIGTERM (128 + 15 in `osproc`'s shell convention).
          check childExit == 128 + SIGTERM
          let afterChild = getMonoTime()
          let daemonGone = goneWithin(inv.daemonPid, inv.daemonStart,
            DaemonExitBudgetMillis)
          note("daemon gone=" & $daemonGone & " after " &
            $(getMonoTime() - afterChild).inMilliseconds & " ms")
          check daemonGone
          let eof = drainsToEofWithin(inv.child, EofBudgetMillis, inv.childOutput)
          note("stdout eof=" & $eof & " after " &
            $(getMonoTime() - afterChild).inMilliseconds & " ms")
          if not eof:
            note("stdout still open; holders of the daemon's fds: " &
              $inheritedDescriptors(inv.daemonPid,
                [pipeInode(inv.child.outputHandle)]))
          check eof
        finally:
          cleanUp(inv)
    else:
      skip("Linux only: the verdicts read /proc")

  test "(b) the daemon holds none of the invocation's descriptors above 2":
    when defined(linux):
      doAssert runquotadAvailable()
      block:
        var inv = Invocation(sentinelFd: -1)
        try:
          startInvocation(inv, "fds")
          doAssert inv.daemonStart.len > 0
          let forbidden = [
            pipeInode(inv.child.outputHandle),
            pipeInode(inv.child.inputHandle),
            inv.sentinelPath]
          # POSITIVE CONTROL: the CHILD does hold the sentinel above 2, so the
          # check below is looking at a descriptor that really was there to
          # inherit, not at one nobody had.
          let childHolds = inheritedDescriptors(processID(inv.child),
            [inv.sentinelPath])
          note("child holds: " & $childHolds)
          doAssert childHolds.len > 0
          let held = inheritedDescriptors(inv.daemonPid, forbidden)
          note("daemon holds: " & $held)
          check held.len == 0
        finally:
          cleanUp(inv)
    else:
      skip("Linux only: the verdicts read /proc")

  test "(c) SIGKILL to the invocation still stops its daemon":
    when defined(linux):
      doAssert runquotadAvailable()
      block:
        var inv = Invocation(sentinelFd: -1)
        try:
          startInvocation(inv, "kill")
          doAssert inv.daemonStart.len > 0
          doAssert kill(Pid(processID(inv.child)), SIGKILL) == 0
          discard inv.child.waitForExit()
          let started = getMonoTime()
          let daemonGone = goneWithin(inv.daemonPid, inv.daemonStart,
            DaemonExitBudgetMillis)
          note("daemon gone=" & $daemonGone & " after " &
            $(getMonoTime() - started).inMilliseconds & " ms")
          check daemonGone
        finally:
          cleanUp(inv)
    else:
      skip("Linux only: the verdicts read /proc")

  test "an inherited ignored SIGHUP leaves the invocation and daemon alive":
    when defined(linux):
      doAssert runquotadAvailable()
      var inv = Invocation(sentinelFd: -1)
      try:
        startInvocation(inv, "ignored", signalMode = 1)
        doAssert inv.daemonStart.len > 0
        doAssert kill(Pid(processID(inv.child)), SIGHUP) == 0
        sleep(500)
        check inv.child.running
        check isStillThere(inv.daemonPid, inv.daemonStart)
      finally:
        cleanUp(inv)
    else:
      skip("Linux only: the verdicts read /proc")

  test "previous ordinary and SA_SIGINFO handlers still run":
    when defined(linux):
      doAssert runquotadAvailable()
      for mode in [2, 3]:
        var inv = Invocation(sentinelFd: -1)
        try:
          startInvocation(inv, "previous-" & $mode, signalMode = mode)
          doAssert inv.daemonStart.len > 0
          doAssert kill(Pid(processID(inv.child)), SIGTERM) == 0
          check inv.child.waitForExit() == (if mode == 2: 42 else: 44)
          check goneWithin(inv.daemonPid, inv.daemonStart, DaemonExitBudgetMillis)
          check drainsToEofWithin(inv.child, EofBudgetMillis, inv.childOutput)
        finally:
          cleanUp(inv)
    else:
      skip("Linux only: the verdicts read /proc")

  test "a previous one-shot handler keeps its reset-on-delivery behavior":
    when defined(linux):
      doAssert runquotadAvailable()
      var inv = Invocation(sentinelFd: -1)
      try:
        startInvocation(inv, "one-shot", signalMode = 4)
        doAssert inv.daemonStart.len > 0
        doAssert kill(Pid(processID(inv.child)), SIGTERM) == 0
        doAssert goneWithin(inv.daemonPid, inv.daemonStart, DaemonExitBudgetMillis)
        check inv.child.running
        doAssert kill(Pid(processID(inv.child)), SIGTERM) == 0
        check inv.child.waitForExit() == 128 + SIGTERM
      finally:
        cleanUp(inv)
    else:
      skip("Linux only: the verdicts read /proc")


  test "a new owned child rearms a consumed one-shot signal disposition":
    when defined(linux):
      let previousSubreaper = subreaper()
      doAssert previousSubreaper >= 0
      doAssert setSubreaper(1) == 0
      var channel: array[2, cint]
      doAssert pipe(channel) == 0
      let ownChildrenPath = "/proc/" & $getpid() & "/task/" & $getpid() & "/children"
      let initialChildren = readFile(ownChildrenPath).splitWhitespace()
      var worker: Pid
      var children: seq[Pid]
      try:
        worker = fork()
        doAssert worker >= 0
        if worker == 0:
          discard close(channel[0])
          setTestDisposition(4)
          let first = rawChild()
          if first <= 0: exitnow(101)
          discard registerOwnedDaemon(int(first))
          discard kill(getpid(), SIGTERM)
          let second = rawChild()
          if second <= 0: exitnow(102)
          discard registerOwnedDaemon(int(second))
          let message = $first & " " & $second & " " & $onceCalls() & " " &
            $(if ownedDaemonSignalIsHooked(SIGTERM): 1 else: 0) & "\n"
          discard write(channel[1], message.cstring, message.len)
          while true: discard pause()
        terminateAtProcessExit(int(worker))
        discard close(channel[1])
        channel[1] = -1
        discard fcntl(channel[0], F_SETFL, O_NONBLOCK)
        var message = ""
        let deadline = getMonoTime() + initDuration(seconds = 10)
        while not message.contains('\n') and getMonoTime() < deadline:
          var buffer: array[256, char]
          let count = read(channel[0], addr buffer[0], buffer.len)
          if count > 0:
            for i in 0 ..< count: message.add(buffer[i])
          else: sleep(10)
        let fields = message.splitWhitespace()
        doAssert fields.len == 4
        children = @[Pid(parseInt(fields[0])), Pid(parseInt(fields[1]))]
        check parseInt(fields[2]) == 1
        check parseInt(fields[3]) == 1
        let secondIdentity = processStartTime(int(children[1]))
        doAssert secondIdentity.len > 0
        doAssert kill(worker, SIGTERM) == 0
        var status: cint
        var waited: Pid
        let exitDeadline = getMonoTime() + initDuration(seconds = 10)
        while getMonoTime() < exitDeadline:
          waited = waitpid(worker, status, WNOHANG)
          if waited == worker: break
          sleep(10)
        doAssert waited == worker
        worker = 0
        check WIFSIGNALED(status)
        check WTERMSIG(status) == SIGTERM
        # This child has no daemon parent-watch or other lifetime mechanism.
        check goneWithin(int(children[1]), secondIdentity, 2_000)
      finally:
        if worker > 0:
          # Discover children even if the status pipe failed before reporting
          # their PIDs, while the invocation still owns them.
          try:
            for value in readFile("/proc/" & $worker & "/task/" & $worker &
                "/children").splitWhitespace():
              let child = Pid(parseInt(value))
              if child notin children: children.add(child)
          except IOError, OSError: discard
          discard kill(worker, SIGKILL)
          var status: cint
          while waitpid(worker, status, 0) < 0 and errno == EINTR: discard
        # Failed startup can orphan a child before its PID reaches the pipe.
        # As subreaper we own those waitable PIDs and must release them too.
        for value in readFile(ownChildrenPath).splitWhitespace():
          let child = Pid(parseInt(value))
          if value notin initialChildren and child notin children:
            children.add(child)
        for child in children:
          discard kill(child, SIGKILL)
          var status: cint
          while waitpid(child, status, 0) < 0 and errno == EINTR: discard
        for fd in channel:
          if fd >= 0: discard close(fd)
        discard setSubreaper(previousSubreaper)
    else:
      skip("Linux only: real child adoption uses PR_SET_CHILD_SUBREAPER")

  test "auto-start refuses ignored SIGCHLD before spawning":
    when defined(linux):
      checkAutoReapRefusal(5)
    else:
      skip("Linux only: real child ownership and SIGCHLD auto-reaping fixture")

  test "auto-start refuses SA_NOCLDWAIT before spawning":
    when defined(linux):
      checkAutoReapRefusal(6)
    else:
      skip("Linux only: real child ownership and SIGCHLD auto-reaping fixture")
