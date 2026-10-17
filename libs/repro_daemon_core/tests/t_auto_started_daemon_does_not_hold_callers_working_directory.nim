## A `repro-daemon` that `startUserDaemon` launches on a caller's behalf does
## not keep that caller's working directory.
##
## THE DEFECT THIS PINS (reprobuild-specs issue 2026-10-14, "auto-started
## repro-daemon holds its starter's working directory on Windows"). The daemon
## was created with `lpCurrentDirectory = nil`, so it started in whatever
## directory the `repro` that started it was running in, and kept it as its
## current directory for its whole life. Windows refuses to delete a directory
## that is some process's current directory, so the starter's directory -- a
## CMake `TryCompile-<id>` scratch directory, a test's temporary project --
## could not be removed until the daemon exited.
##
## THE SHAPE OF THE CASE:
##
##   this test
##     └─ this binary in fixture mode, working directory `<root>/scratch`
##          └─ startUserDaemon → the graph-built engine, `daemon serve`
##
## The fixture calls the PRODUCTION `startUserDaemon` -- dev mode, as the thin
## client calls it -- against a private endpoint, writes the daemon's pid to a
## file and exits. The test then deletes `scratch` while the daemon is still
## serving. The "still serving" half is what keeps the case honest: a delete
## that succeeded because the daemon had died would prove nothing.
##
## The fixture names the state directory RELATIVE to `scratch`
## (`../state/daemon`). The daemon no longer runs in the caller's directory, so
## every path it is handed has to be made absolute by the caller first; a
## relative state directory reaching the daemon unchanged would put the
## daemon's state in the wrong place, which the test checks for as well.
##
## Windows and Linux. POSIX does not refuse to remove a directory that is
## some process's working directory, so on Linux the case reads the daemon's
## working directory from `/proc/<pid>/cwd` and requires it not to be the
## starter's. `startUserDaemon` prefers `systemd --user` there, which a test
## must not register units with, so the fixture runs WITHOUT
## `$XDG_RUNTIME_DIR` and `$DBUS_SESSION_BUS_ADDRESS`: the real
## `systemd-run --user` declines and the production fork fallback
## (`launchWithFork`, which chdirs to `daemonWorkingDirectory`) starts the
## daemon; the case checks the daemon's log names that backend. Nothing is
## mocked. macOS would register a launchd job, so the case is skipped there
## with that reason.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_daemon_core
from repro_test_support import reproBinaryPath, requireBinary
import repro_test_support/reasoned_skip

const FixtureFlag = "--start-daemon-in-cwd-fixture"

if paramCount() == 5 and paramStr(1) == FixtureFlag:
  # The `repro build` client's role: start the per-user daemon from this
  # process's working directory, report it, and exit. Everything the daemon's
  # discovery reads is pointed at the private state directory first, so this
  # case cannot touch the real user daemon.
  let engine = paramStr(2)
  let endpoint = paramStr(3)
  let stateDir = paramStr(4)
  let pidFile = paramStr(5)
  putEnv("REPRO_DAEMON_STATE_DIR", absolutePath(stateDir))
  putEnv("REPRO_DAEMON_ENDPOINT", endpoint)
  var config = defaultUserDaemonConfig(devMode = true)
  config.endpoint = endpoint
  config.stateDir = stateDir
  config.logPath = stateDir / "logs" / "repro-daemon.log"
  try:
    let status = startUserDaemon(engine, config)
    writeFile(pidFile, $status.pid)
    quit(0)
  except CatchableError as err:
    writeFile(pidFile, "daemon start failed: " & err.msg)
    quit(2)

import repro_test_support/reasoned_skip

when defined(linux):
  import std/[posix, strtabs]

  proc withoutUserBus(): StringTableRef =
    ## This process's environment minus what `systemd-run --user` needs to
    ## reach the user manager (see the header).
    result = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if key notin ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]:
        result[key] = value

  suite "auto-started daemon working directory":
    test "the daemon does not hold its starter's working directory":
      let engine = requireBinary(reproBinaryPath(stem = "reprobuild"),
        "reprobuild.apps.reprobuild")
      let root = createTempDir("repro-daemon-cwd-", "")
      let scratch = root / "scratch"
      let stateDir = root / "state" / "daemon"
      let pidFile = root / "daemon.pid"
      createDir(scratch)
      let endpoint = root / "d.sock"
      var daemonPid = 0
      try:
        let starter = startProcess(getAppFilename(),
          workingDir = scratch,
          args = [FixtureFlag, engine, endpoint, ".." / "state" / "daemon",
            pidFile],
          env = withoutUserBus(), options = {poParentStreams})
        let starterExit = starter.waitForExit(120_000)
        starter.close()
        let report = if fileExists(pidFile): readFile(pidFile).strip else: ""
        if starterExit != 0:
          echo "the starter failed: ", report
        check starterExit == 0
        if report.len > 0 and report.allCharsInSet(Digits):
          daemonPid = parseInt(report)
        check daemonPid > 0
        # The relative state directory was resolved against the STARTER's
        # directory, as the caller meant it.
        check dirExists(stateDir / "logs")
        check not dirExists(root / "state" / "state")
        # The daemon came from the fork fallback, not from a unit.
        let logPath = stateDir / "logs" / "repro-daemon.log"
        check fileExists(logPath) and
          readFile(logPath).contains("backend=posix-fork")
        # THE PROPERTY. POSIX does not refuse to delete a directory that is
        # some process's working directory, so the Linux form of the defect
        # is the daemon keeping it (and its file system) busy: read the
        # daemon's working directory from /proc.
        var daemonCwd = ""
        try:
          daemonCwd = expandSymlink("/proc/" & $daemonPid & "/cwd")
        except OSError as err:
          echo "cannot read the daemon's working directory: ", err.msg
        checkpoint("daemon cwd: " & daemonCwd)
        check daemonCwd.len > 0
        check daemonCwd != expandFilename(scratch)
        check not daemonCwd.startsWith(expandFilename(scratch) & "/")
        removeDir(scratch)
        check not dirExists(scratch)
        # ...and the daemon is still serving.
        check queryUserDaemonStatus(endpoint).running
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
          removeDir(root)
        except CatchableError:
          discard
elif not defined(windows):
  suite "auto-started daemon working directory":
    test "the daemon does not hold its starter's working directory":
      skip("macOS: startUserDaemon would register a launchd job, which a " &
        "test must not do; the fork fallback runs in this case on Linux " &
        "(home-pc) and the Windows launch on eli-pc")
else:
  import std/winlean

  proc killPid(pid: int) =
    if pid <= 0:
      return
    let process = openProcess(PROCESS_TERMINATE, WINBOOL(0), DWORD(pid))
    if process != 0:
      discard terminateProcess(process, 1)
      discard closeHandle(process)

  suite "auto-started daemon working directory":
    test "the daemon does not hold its starter's working directory":
      let engine = requireBinary(reproBinaryPath(stem = "reprobuild"),
        "reprobuild.apps.reprobuild")
      let root = createTempDir("repro-daemon-cwd-", "")
      let scratch = root / "scratch"
      let stateDir = root / "state" / "daemon"
      let pidFile = root / "daemon.pid"
      createDir(scratch)
      let endpoint = "\\\\.\\pipe\\repro-daemon-cwd-test-" &
        $getCurrentProcessId()
      var daemonPid = 0
      try:
        # Parent streams, not a pipe: what this case is about is the working
        # directory, and the inherited-pipe defect has its own case.
        let starter = startProcess(getAppFilename(),
          workingDir = scratch,
          args = [FixtureFlag, engine, endpoint, ".." / "state" / "daemon",
            pidFile],
          options = {poParentStreams})
        let starterExit = starter.waitForExit(120_000)
        starter.close()
        let report = if fileExists(pidFile): readFile(pidFile).strip else: ""
        if starterExit != 0:
          echo "the starter failed: ", report
        check starterExit == 0
        if report.len > 0 and report.allCharsInSet(Digits):
          daemonPid = parseInt(report)
        check daemonPid > 0
        # The relative state directory was resolved against the STARTER's
        # directory, as the caller meant it. Resolved against the daemon's own
        # (the state directory itself) it would land in `state/state/daemon`.
        check dirExists(stateDir / "logs")
        check not dirExists(root / "state" / "state")
        # THE PROPERTY. The starter is gone; the only process that could still
        # hold `scratch` as its current directory is the daemon it started.
        var removeError = ""
        try:
          removeDir(scratch)
        except OSError as err:
          removeError = err.msg
        if removeError.len > 0:
          echo "the starter's working directory could not be deleted while ",
            "the daemon runs: ", removeError
        check removeError.len == 0
        check not dirExists(scratch)
        # ...and the daemon is still serving, so the delete above is not the
        # daemon having died.
        check queryUserDaemonStatus(endpoint).running
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
          removeDir(root)
        except CatchableError:
          discard
