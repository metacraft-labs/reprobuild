## No mocks: include the runtime to exercise its private logLine entry point
## against both the unfixed implementation and the bounded writer. The test
## intentionally uses no API introduced by the fix, so the clean landing
## branch can compile it and fail on the file-size assertions themselves.
import std/[tempfiles, unittest]
include ../src/repro_daemon_core/runtime
import repro_test_support/process_fixtures

proc logFixtureDir(prefix: string): string =
  result = genTempPath(prefix, "")
  releaseDirAtProcessExit(result)
  createDir(result)

suite "runtime daemon log retention":
  test "a running writer bounds both files without a restart":
    let dir = logFixtureDir("repro-runtime-log-")
    defer: removeDir(dir)
    let path = dir / "repro-daemon.log"
    const ceiling = 16 * 1024 * 1024
    let message = repeat('x', ceiling div 4)
    for i in 0 ..< 12:
      logLine(path, "ordinary diagnostic " & $i & " " & message)
      check getFileSize(path) <= ceiling
      if fileExists(path & ".1"):
        check getFileSize(path & ".1") <= ceiling
    check fileExists(path & ".1")
    check readFile(path).contains("ordinary diagnostic 11 ")

  test "launchd output cannot bypass the structured writer":
    var config = defaultUserDaemonConfig()
    config.logPath = "/tmp/repro-retention-log"
    let plist = renderLaunchdUserAgentPlist("/tmp/repro-daemon", config)
    check plist.contains("<key>StandardOutPath</key>\n  <string>/dev/null</string>")
    check plist.contains("<key>StandardErrorPath</key>\n  <string>/dev/null</string>")

  when defined(posix):
    test "detached raw output cannot grow the structured log":
      let dir = logFixtureDir("repro-runtime-raw-log-")
      defer: removeDir(dir)
      let exe = dir / "raw-output"
      let done = dir / "done"
      writeFile(exe, "#!/bin/sh\nprintf 'RAW-STDOUT-BYPASS\\n'\n" &
        "printf 'RAW-STDERR-BYPASS\\n' >&2\n" &
        "printf done > " & quoteShell(done) & "\n")
      setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
      var config = defaultUserDaemonConfig()
      config.stateDir = dir
      config.logPath = dir / "repro-daemon.log"
      launchWithFork(exe, config)
      let deadline = getTime() + initDuration(seconds = 10)
      while not fileExists(done) and getTime() < deadline:
        sleep(10)
      require fileExists(done)
      var status: cint
      check posix.waitpid(-1, status, 0) > 0
      check posix.WIFEXITED(status)
      check posix.WEXITSTATUS(status) == 0
      let diagnostics = readFile(config.logPath)
      check diagnostics.contains("launch requested backend=posix-fork")
      check not diagnostics.contains("RAW-STDOUT-BYPASS")
      check not diagnostics.contains("RAW-STDERR-BYPASS")
