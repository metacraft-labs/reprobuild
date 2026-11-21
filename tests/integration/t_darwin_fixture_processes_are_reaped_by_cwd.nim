## Real-process regression for fixture teardown on macOS. No mocks: a real
## shell forks a real sleep child, and an unrelated sibling directory runs
## another shell with the same executable and a confusingly similar path.
## Their live kernel cwd records are the only authority used for signalling.

import std/unittest
import repro_test_support/reasoned_skip

when defined(macosx):
  import std/[os, osproc, strutils, tempfiles, times]
  import repro_test_support/darwin_fixture_processes

  proc waitForChildPid(path: string): int =
    let deadline = epochTime() + 10
    while epochTime() < deadline:
      if fileExists(path):
        let text = readFile(path).strip()
        if text.len > 0:
          return parseInt(text)
      sleep(20)
    raise newException(OSError, "Fixture shell never published its child pid")

  proc startTree(root: string): owned(Process) =
    # The TERM trap gives the control's fallback cleanup its own authority
    # over the child even if the cwd reaper is deliberately broken.
    startProcess("/bin/sh", workingDir = root, args = @["-c",
      "sleep 60 & child=$!; trap 'kill \"$child\" 2>/dev/null; wait \"$child\"; exit' TERM; echo \"$child\" > child.pid; wait \"$child\""],
      options = {poStdErrToStdOut})

  proc closeTree(process: var owned(Process)) =
    if process.running():
      process.terminate()
    discard process.waitForExit()
    process.close()

suite "Darwin fixture descendants are reaped by their live cwd":
  test "a fixture tree is reaped while a sibling sharing its prefix survives":
    when defined(macosx):
      let root = createTempDir("repro-native-reap-", "")
      let sibling = root & "-unrelated"
      createDir(sibling)
      createDir(root / "nested")
      defer:
        removeDir(root)
        removeDir(sibling)
      var own = startTree(root / "nested")
      var other = startTree(sibling)
      defer:
        closeTree(own)
        closeTree(other)
      let ownChild = waitForChildPid(root / "nested" / "child.pid")
      let otherChild = waitForChildPid(sibling / "child.pid")
      check darwinFixtureProcessIds(root / "missing").len == 0
      expect ValueError:
        discard darwinFixtureProcessIds($DirSep)
      let ownPids = darwinFixtureProcessIds(root)
      check own.processID in ownPids
      check ownChild in ownPids
      check other.processID notin ownPids
      check otherChild notin ownPids
      # /var and /private/var are the same tree on macOS; the kernel reports
      # the latter even when a temp-root caller supplies the former.
      let alias = if root.startsWith("/private/var/"): root[8 .. ^1]
                  else: root
      let previousCwd = getCurrentDir()
      setCurrentDir(root)
      defer: setCurrentDir(previousCwd)
      check getCurrentProcessId() notin darwinFixtureProcessIds(root)
      reapDarwinFixtureProcesses(alias)
      setCurrentDir(previousCwd)
      check darwinFixtureProcessIds(root).len == 0
      check not own.running()
      discard own.waitForExit()     # reap the direct child, not just its cwd
      check other.running()
      let surviving = darwinFixtureProcessIds(sibling)
      check other.processID in surviving
      check otherChild in surviving

    else:
      skip("requires macOS libproc live cwd records")

  test "a failed prerequisite unwinds teardown before its tree is removed":
    when defined(macosx):
      let root = createTempDir("repro-native-reap-failure-", "")
      defer: removeDir(root)
      var childPid = 0
      proc failAfterStartingFixture() =
        var process = startTree(root)
        defer:
          reapDarwinFixtureProcesses(root)
          closeTree(process)
        childPid = waitForChildPid(root / "child.pid")
        check childPid in darwinFixtureProcessIds(root)
        raise newException(AssertionDefect, "fixture prerequisite failed")
      expect AssertionDefect:
        failAfterStartingFixture()
      check childPid > 0
      check darwinFixtureProcessIds(root).len == 0
    else:
      skip("requires macOS libproc live cwd records")
