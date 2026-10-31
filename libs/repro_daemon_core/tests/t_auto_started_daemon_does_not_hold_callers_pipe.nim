## A `repro-daemon` that `startUserDaemon` launches on a caller's behalf does
## not keep that caller's output pipe open.
##
## THE DEFECT THIS PINS (reprobuild-specs issue 2026-10-10, "auto-started
## repro-daemon inherits the caller's output pipe on Windows"). CMake runs each
## `try_compile()` as `repro build …` with stdout/stderr on a pipe and reads it
## to EOF. When no daemon was running, that `repro` started one through
## `osproc.startProcess`, which on Windows calls `CreateProcessW` with
## `bInheritHandles = TRUE`: every inheritable handle the client held --
## including the write end of CMake's pipe, its own stdout -- was duplicated
## into a process that lives as long as the daemon. The client exited, CMake's
## read never saw EOF, and the configure hung until the daemon was killed.
##
## THE SHAPE OF THE CASE IS THE SHAPE OF THE INCIDENT:
##
##   this test (CMake's role)
##     └─ this binary in fixture mode, stdout+stderr on ONE pipe (`repro build`)
##          └─ startUserDaemon → the graph-built engine, `daemon serve`
##
## The fixture calls the PRODUCTION `startUserDaemon` -- dev mode, as the thin
## client calls it -- against a private endpoint and state directory, prints
## the daemon's pid and exits. The test then requires the pipe to reach EOF
## while the daemon is still serving. The "still serving" half is what keeps
## the case honest: EOF observed because the daemon had died would prove
## nothing.
##
## Windows and Linux. On Linux `startUserDaemon` prefers `systemd --user`,
## which a test must not register units with, so the case starts its fixture
## WITHOUT `$XDG_RUNTIME_DIR` and `$DBUS_SESSION_BUS_ADDRESS`: the real
## `systemd-run --user` then cannot reach a user bus and declines, and the
## production fallback, `launchWithFork` (dup2 stdio onto /dev/null and the
## log, close every descriptor above 2), starts the daemon. That is the POSIX
## form of the same guarantee, exercised through the same entry point; nothing
## is mocked, and the case checks the daemon's log names the fork backend.
## macOS would register a launchd job, so the case is skipped there with that
## reason -- its fork fallback is the code the Linux case runs.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_daemon_core
from repro_test_support import reproBinaryPath, requireBinary
import repro_test_support/reasoned_skip

const FixtureFlag = "--start-daemon-fixture"

if paramCount() == 4 and paramStr(1) == FixtureFlag:
  # The `repro build` client's role: start the per-user daemon, report it, and
  # exit. Everything the daemon's discovery reads is pointed at the private
  # state directory first, so this case cannot touch the real user daemon.
  let engine = paramStr(2)
  let endpoint = paramStr(3)
  let stateDir = paramStr(4)
  putEnv("REPRO_DAEMON_STATE_DIR", stateDir)
  putEnv("REPRO_DAEMON_ENDPOINT", endpoint)
  var config = defaultUserDaemonConfig(devMode = true)
  config.endpoint = endpoint
  config.stateDir = stateDir
  config.logPath = stateDir / "logs" / "repro-daemon.log"
  try:
    let status = startUserDaemon(engine, config)
    echo "daemon-pid=", status.pid
    quit(0)
  except CatchableError as err:
    echo "daemon start failed: ", err.msg
    quit(2)

import repro_test_support/reasoned_skip

when defined(linux):
  import std/[monotimes, posix, strtabs, times]

  type PipeState = enum
    psEof, psOpen

  proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

  proc drainUntilEof(fd: cint; timeoutMs: int;
                     collected: var string): PipeState =
    ## Read the pipe until every writer has closed it (`read` returns 0) or
    ## `timeoutMs` passes with a writer still holding it. `poll` bounds every
    ## wait, so a writer that never closes cannot block the test.
    let deadline = nowMs() + timeoutMs
    var buffer: array[4096, char]
    while true:
      let remaining = max(0'i64, deadline - nowMs())
      var pfd = TPollfd(fd: fd, events: POLLIN)
      let ready = posix.poll(addr pfd, 1, cint(min(remaining, 200'i64)))
      if ready > 0:
        let got = posix.read(fd, addr buffer[0], buffer.len)
        if got == 0:
          return psEof
        if got > 0:
          for i in 0 ..< got:
            collected.add buffer[i]
          continue
        if errno != EINTR:
          raiseOSError(osLastError(), "read on the starter's stdout")
      if nowMs() >= deadline:
        return psOpen

  proc withoutUserBus(): StringTableRef =
    ## This process's environment minus what `systemd-run --user` needs to
    ## reach the user manager (see the header).
    result = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if key notin ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]:
        result[key] = value

  suite "auto-started daemon stdio":
    test "the daemon does not hold its starter's output pipe open":
      let engine = requireBinary(reproBinaryPath(stem = "reprobuild"),
        "reprobuild.apps.reprobuild")
      let stateDir = createTempDir("repro-daemon-stdio-", "")
      let endpoint = stateDir / "d.sock"
      var daemonPid = 0
      var output = ""
      try:
        let starter = startProcess(getAppFilename(),
          args = [FixtureFlag, engine, endpoint, stateDir],
          env = withoutUserBus(), options = {poStdErrToStdOut})
        let fd = cint(outputHandle(starter))
        # The starter must exit on its own: it only waits for the daemon's
        # status handshake. Its output is drained meanwhile so a full pipe
        # cannot be what holds it.
        var state = psOpen
        let exitDeadline = nowMs() + 120_000
        while starter.running and nowMs() < exitDeadline:
          state = drainUntilEof(fd, 200, output)
          if state == psEof:
            break
        let starterExit = starter.waitForExit(5_000)
        check starterExit == 0
        for line in output.splitLines:
          if line.startsWith("daemon-pid="):
            daemonPid = parseInt(line["daemon-pid=".len .. ^1].strip)
        check daemonPid > 0
        # The daemon came from the fork fallback, not from a unit.
        let logPath = stateDir / "logs" / "repro-daemon.log"
        check fileExists(logPath) and
          readFile(logPath).contains("backend=posix-fork")
        # THE PROPERTY. The starter is gone; the only process that could still
        # hold the write end is the daemon it started.
        if state != psEof:
          state = drainUntilEof(fd, 10_000, output)
        if state != psEof:
          echo "the starter exited but its stdout pipe never reached EOF; ",
            "output so far:\n", output
        check state == psEof
        # ...and the daemon is still serving, so the EOF above is not the
        # daemon having died.
        check queryUserDaemonStatus(endpoint).running
        starter.close()
      finally:
        putEnv("REPRO_DAEMON_STATE_DIR", stateDir)
        try:
          stopUserDaemon(endpoint)
        except CatchableError:
          discard
        sleep(500)
        if daemonPid > 0:
          discard posix.kill(Pid(daemonPid), SIGKILL)
        delEnv("REPRO_DAEMON_STATE_DIR")
        try:
          removeDir(stateDir)
        except CatchableError:
          discard
elif not defined(windows):
  suite "auto-started daemon stdio":
    test "the daemon does not hold its starter's output pipe open":
      skip("macOS: startUserDaemon would register a launchd job, which a " &
        "test must not do; the fork fallback runs in this case on Linux " &
        "(home-pc) and the Windows launch on eli-pc")
else:
  import std/[monotimes, times, winlean]

  const ErrorBrokenPipe = 109

  type PipeState = enum
    psEof, psOpen

  proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

  proc drainUntilEof(handle: Handle; timeoutMs: int;
                     collected: var string): PipeState =
    ## Read whatever the pipe carries until every writer has closed it (EOF,
    ## which a pipe reports as ERROR_BROKEN_PIPE) or ``timeoutMs`` passes with
    ## a writer still holding it. Polls with PeekNamedPipe so a writer that
    ## never closes cannot block the test.
    let deadline = nowMs() + timeoutMs
    var buffer: array[4096, char]
    while true:
      var available: int32 = 0
      if not peekNamedPipe(handle, nil, 0, nil, addr available, nil):
        let error = osLastError()
        if error.int32 == ErrorBrokenPipe:
          return psEof
        raiseOSError(error, "PeekNamedPipe on the starter's stdout")
      if available > 0:
        var got: int32 = 0
        if readFile(handle, addr buffer[0], int32(buffer.len), addr got,
            nil) != 0 and got > 0:
          for i in 0 ..< int(got):
            collected.add buffer[i]
        continue
      if nowMs() >= deadline:
        return psOpen
      sleep(50)

  proc killPid(pid: int) =
    if pid <= 0:
      return
    let process = openProcess(PROCESS_TERMINATE, WINBOOL(0), DWORD(pid))
    if process != 0:
      discard terminateProcess(process, 1)
      discard closeHandle(process)

  suite "auto-started daemon stdio":
    test "the daemon does not hold its starter's output pipe open":
      let engine = requireBinary(reproBinaryPath(stem = "reprobuild"),
        "reprobuild.apps.reprobuild")
      let stateDir = createTempDir("repro-daemon-stdio-", "")
      let endpoint = "\\\\.\\pipe\\repro-daemon-stdio-test-" &
        $getCurrentProcessId()
      var daemonPid = 0
      var output = ""
      try:
        let starter = startProcess(getAppFilename(),
          args = [FixtureFlag, engine, endpoint, stateDir],
          options = {poStdErrToStdOut})
        let pipe = Handle(outputHandle(starter))
        # The starter must exit on its own: it only waits for the daemon's
        # status handshake. Its output is drained meanwhile so a full pipe
        # cannot be what holds it.
        var state = psOpen
        let exitDeadline = nowMs() + 120_000
        while starter.running and nowMs() < exitDeadline:
          state = drainUntilEof(pipe, 200, output)
          if state == psEof:
            break
        let starterExit = starter.waitForExit(5_000)
        check starterExit == 0
        for line in output.splitLines:
          if line.startsWith("daemon-pid="):
            daemonPid = parseInt(line["daemon-pid=".len .. ^1].strip)
        check daemonPid > 0
        # THE PROPERTY. The starter is gone; the only process that could still
        # hold the write end is the daemon it started.
        if state != psEof:
          state = drainUntilEof(pipe, 10_000, output)
        if state != psEof:
          echo "the starter exited but its stdout pipe never reached EOF; ",
            "output so far:\n", output
        check state == psEof
        # ...and the daemon is still serving, so the EOF above is not the
        # daemon having died.
        check queryUserDaemonStatus(endpoint).running
        starter.close()
      finally:
        putEnv("REPRO_DAEMON_STATE_DIR", stateDir)
        try:
          stopUserDaemon(endpoint)
        except CatchableError:
          discard
        sleep(500)
        killPid(daemonPid)
        delEnv("REPRO_DAEMON_STATE_DIR")
        try:
          removeDir(stateDir)
        except CatchableError:
          discard
