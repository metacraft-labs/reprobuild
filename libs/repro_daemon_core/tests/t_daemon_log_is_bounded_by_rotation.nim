## Real-filesystem retention regression: no mocks. Tiny ceilings exercise the
## same writer used by the daemon, launch clients and detached build workers.
## Concurrent writers use real forked processes and kernel locks.

import std/[algorithm, os, strutils, tempfiles, times, unittest]

import repro_daemon_core
import repro_test_support/process_fixtures

proc logFixtureDir(prefix: string): string =
  result = genTempPath(prefix, "")
  releaseDirAtProcessExit(result)
  createDir(result)

when defined(posix):
  import std/posix

const Ceiling = 4096
  ## Small enough that fifty ceilings is a fast test, large enough that a
  ## generation holds dozens of lines.

proc sizeOrZero(path: string): int =
  if fileExists(path): int(getFileSize(path)) else: 0

proc lastLine(path: string): string =
  let lines = readFile(path).strip(leading = false).splitLines()
  if lines.len > 0: lines[^1] else: ""

proc firstLine(path: string): string =
  let lines = readFile(path).splitLines()
  if lines.len > 0: lines[0] else: ""

proc logDirEntries(dir: string): seq[string] =
  for kind, entry in walkDir(dir, relative = true):
    result.add(entry)

suite "the daemon log is bounded by rotation":
  test "fifty ceilings of writes leave at most two bounded generations":
    let dir = logFixtureDir("repro-daemon-log-")
    defer: removeDir(dir)
    let path = dir / "repro-daemon.log"
    let previous = userDaemonLogPreviousGeneration(path)
    check previous == path & ".1"
    # A line of ~100 bytes including the timestamp `logLine` prefixes.
    let message = "build request accepted session=" & repeat('x', 40)
    var written = 0
    var longestLine = 0
    var worstCurrent = 0
    var worstPrevious = 0
    var violation = ""
    while written < 50 * Ceiling:
      appendUserDaemonLogLine(path, message, maxBytes = Ceiling)
      let current = sizeOrZero(path)
      let older = sizeOrZero(previous)
      if written == 0:
        longestLine = current
        require longestLine > 0
      written += longestLine
      worstCurrent = max(worstCurrent, current)
      worstPrevious = max(worstPrevious, older)
      if violation.len == 0 and
          (current > Ceiling or older > Ceiling or
           current + older > 2 * Ceiling):
        violation = "after " & $written & " bytes written: current=" &
          $current & " previous=" & $older
    checkpoint("line=" & $longestLine & " bytes, wrote " & $written &
      " bytes; worst current=" & $worstCurrent & " worst previous=" &
      $worstPrevious & " ceiling=" & $Ceiling)
    check violation == ""
    check worstCurrent <= Ceiling
    check worstPrevious <= Ceiling
    # Rotation actually happened, so the bound is not satisfied vacuously by
    # a writer that stopped writing.
    check fileExists(previous)
    check lastLine(path).endsWith(message)
    # Exactly one previous generation: never a `.2`, never anything else.
    var entries = logDirEntries(dir)
    entries.sort()
    check entries == @["repro-daemon.log", "repro-daemon.log.1", "repro-daemon.log.lock"]

  test "the newest line is current, the one before a rotation is in .1":
    let dir = logFixtureDir("repro-daemon-log-")
    defer: removeDir(dir)
    let path = dir / "repro-daemon.log"
    let previous = userDaemonLogPreviousGeneration(path)
    var rotations = 0
    var lastSize = 0
    for i in 1 .. 2_000:
      let message = "line-" & align($i, 6, '0') & " " & repeat('y', 30)
      appendUserDaemonLogLine(path, message, maxBytes = Ceiling)
      let size = sizeOrZero(path)
      # The newest line is ALWAYS in the current file, whole.
      check lastLine(path).endsWith(message)
      if size < lastSize:
        inc rotations
        # The rotation boundary: this line starts the fresh file, and the
        # line written just before it ends the previous generation.
        check firstLine(path).endsWith(message)
        check lastLine(previous).endsWith("line-" & align($(i - 1), 6, '0') &
          " " & repeat('y', 30))
      lastSize = size
    checkpoint("rotations=" & $rotations)
    check rotations >= 10
    # The oldest history is discarded, not kept in a third generation.
    check not readFile(path).contains("line-000001 ")
    check not readFile(previous).contains("line-000001 ")
    check not fileExists(path & ".2")

  test "oversized lines are marked and cannot bypass the ceiling":
    let dir = logFixtureDir("repro-daemon-log-")
    defer: removeDir(dir)
    let path = dir / "repro-daemon.log"
    appendUserDaemonLogLine(path, repeat('z', 4 * Ceiling), maxBytes = Ceiling)
    check getFileSize(path) == Ceiling
    check readFile(path).endsWith(" [truncated]\n")
    appendUserDaemonLogLine(path, "after", maxBytes = Ceiling)
    check getFileSize(path & ".1") == Ceiling
    check lastLine(path).endsWith("after")

  test "legacy oversized generations retain their bounded tails":
    let dir = logFixtureDir("repro-daemon-log-")
    defer: removeDir(dir)
    let path = dir / "repro-daemon.log"
    # A small append must also bound an existing previous generation even
    # when no current generation exists to rotate over it.
    writeFile(path & ".1", repeat('c', 5 * Ceiling))
    appendUserDaemonLogLine(path, "small", maxBytes = Ceiling)
    check readFile(path & ".1") == repeat('c', Ceiling)
    check lastLine(path).endsWith("small")
    writeFile(path, repeat('a', 3 * Ceiling) & repeat('b', Ceiling))
    writeFile(path & ".1", repeat('c', 5 * Ceiling))
    appendUserDaemonLogLine(path, "new", maxBytes = Ceiling)
    check readFile(path & ".1") == repeat('b', Ceiling)
    check lastLine(path).endsWith("new")
    check sizeOrZero(path) <= Ceiling

  test "logs prints the previous generation, then the current file":
    let dir = logFixtureDir("repro-daemon-log-")
    defer: removeDir(dir)
    var config = defaultUserDaemonConfig()
    config.logPath = dir / "logs" / "repro-daemon.log"
    let previous = userDaemonLogPreviousGeneration(config.logPath)
    # Neither file: the existing "no log file" message.
    check renderUserDaemonLogs(config) ==
      "repro daemon logs: no log file at " & config.logPath
    # Only the current file: exactly it.
    appendUserDaemonLogLine(config.logPath, "only-current",
      maxBytes = Ceiling)
    check renderUserDaemonLogs(config) == readFile(config.logPath)
    # After a rotation: `.1` first, the current file after it, so the most
    # recent ceiling's worth of history is never hidden by a rotation.
    for i in 1 .. 200:
      appendUserDaemonLogLine(config.logPath, "entry-" & $i & " " &
        repeat('w', 40), maxBytes = Ceiling)
    require fileExists(previous)
    let rendered = renderUserDaemonLogs(config)
    check rendered == readFile(previous) & readFile(config.logPath)
    check rendered.find("entry-200 ") > rendered.find(lastLine(previous))
    check rendered.len > Ceiling
    # Only the previous generation (the current file was removed by hand):
    # what there is, rather than "no log file".
    removeFile(config.logPath)
    check renderUserDaemonLogs(config) == readFile(previous)

  when defined(posix):
    proc cFlock(fd: cint; operation: cint): cint
      {.importc: "flock", header: "<sys/file.h>".}

    proc waitChild(pid: Pid): cint =
      var status: cint
      if posix.waitpid(pid, status, 0) != pid: return -1
      if posix.WIFEXITED(status): posix.WEXITSTATUS(status) else: -1

    test "concurrent processes never exceed either generation ceiling":
      let dir = logFixtureDir("repro-daemon-log-")
      defer: removeDir(dir)
      let path = dir / "repro-daemon.log"
      var children: seq[Pid]
      stdout.flushFile()
      stderr.flushFile()
      for worker in 0 ..< 8:
        let pid = posix.fork()
        if pid == 0:
          for i in 0 ..< 500:
            appendUserDaemonLogLine(path, "worker=" & $worker & " entry=" &
              $i & " " & repeat('x', 100), maxBytes = Ceiling)
            for generation in [path, path & ".1"]:
              try:
                if getFileSize(generation) > Ceiling: exitnow(3)
              except OSError as error:
                # Rename leaves a short missing-current window; any other
                # filesystem failure must fail the test.
                if error.errorCode.int != ENOENT.int: exitnow(4)
          exitnow(0)
        require pid > 0
        terminateAtProcessExit(pid.int)
        children.add(pid)
      for child in children:
        check waitChild(child) == 0
      appendUserDaemonLogLine(path, "final", maxBytes = Ceiling)
      check sizeOrZero(path) <= Ceiling
      check sizeOrZero(path & ".1") <= Ceiling
      check lastLine(path).endsWith("final")
      check fileExists(path & ".1")
      # No torn appends: retained lines all have the real writer's timestamp.
      for generation in [path, path & ".1"]:
        for line in readFile(generation).splitLines():
          if line.len > 0:
            check line.len >= 4
            check line[0 .. 3] == $now().year
            check line.contains("worker=") or line.endsWith("final")

    test "a dead lock owner cannot strand subsequent diagnostics":
      let dir = logFixtureDir("repro-daemon-log-")
      defer: removeDir(dir)
      let path = dir / "repro-daemon.log"
      let pid = posix.fork()
      if pid == 0:
        let fd = posix.open(cstring(path & ".lock"), O_RDWR or O_CREAT,
          Mode(0o600))
        if fd < 0 or cFlock(fd, 2.cint) != 0: exitnow(2)
        # Deliberately skip cleanup: the kernel must release on process exit.
        exitnow(0)
      require pid > 0
      terminateAtProcessExit(pid.int)
      check waitChild(pid) == 0
      appendUserDaemonLogLine(path, "owner died", maxBytes = Ceiling)
      check lastLine(path).endsWith("owner died")
