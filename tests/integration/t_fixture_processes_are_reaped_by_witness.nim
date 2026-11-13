## Real-process regression for `repro_test_support/fixture_processes`, the
## platform-neutral teardown reap the shared-development-services
## integration files call. No mocks: real `/bin/sh` processes fork real
## `sleep` children, and the only authority the reap uses is the live
## process table.
##
## WHAT EACH CASE PINS.
##   * The CWD witness (Linux /proc and macOS libproc): a shell whose cwd is
##     below the fixture root is reaped together with its child, while a
##     shell in `<root>-unrelated` -- a sibling sharing the root as a STRING
##     PREFIX -- survives. That prefix is the boundary a careless
##     `startsWith(root)` gets wrong.
##   * The ARGV witness (Linux only): a process whose cwd is elsewhere but
##     whose argv names a path below the root is reaped -- the shape of
##     `__repro-dev-session-http --session-dir <root>/...`, the process F1
##     leaked -- while one whose argv names `<root>-unrelated/...` survives.
##     macOS has no argv witness (the darwin module reads cwd only), so the
##     case says so rather than pretending to run there.
##   * Unwinding: a failed prerequisite still reaps before its tree goes.
##
## `t_darwin_fixture_processes_are_reaped_by_cwd.nim` stays beside this file:
## it pins the darwin module's own contract (the `/var` vs `/private/var`
## alias), which this module only delegates to.

import std/unittest
import repro_test_support/reasoned_skip

when defined(linux) or defined(macosx):
  import std/[os, osproc, strutils, tempfiles, times]
  import repro_test_support/fixture_processes

  # The TERM trap gives the cleanup below its own authority over the child,
  # even if the reap under test is deliberately broken: closing the shell
  # handle then also stops its `sleep`.
  const TreeScript =
    "sleep 60 & child=$!; " &
    "trap 'kill \"$child\" 2>/dev/null; wait \"$child\"; exit' TERM; " &
    "echo \"$child\" > \"$1\"; wait \"$child\""

  proc waitForChildPid(path: string): int =
    let deadline = epochTime() + 10
    while epochTime() < deadline:
      if fileExists(path):
        let text = readFile(path).strip()
        if text.len > 0:
          return parseInt(text)
      sleep(20)
    raise newException(OSError, "Fixture shell never published its child pid")

  proc startTree(cwd, pidFile: string; extra: seq[string] = @[]):
      owned(Process) =
    ## `sh -c TreeScript tree <pidFile> <extra...>`: `$0` is a label and
    ## `$1` the pid file, so `extra` reaches the shell's argv unused -- the
    ## argv witness reads it, the script never does.
    startProcess("/bin/sh", workingDir = cwd,
      args = @["-c", TreeScript, "fixture-tree", pidFile] & extra,
      options = {poStdErrToStdOut})

  proc closeTree(process: var owned(Process)) =
    if process.running():
      process.terminate()
    discard process.waitForExit()
    process.close()

suite "fixture processes are reaped by their live witness":
  test "the cwd witness reaps a tree while a prefix-sharing sibling survives":
    when defined(linux) or defined(macosx):
      let root = createTempDir("repro-fixture-reap-", "")
      let sibling = root & "-unrelated"
      createDir(sibling)
      createDir(root / "nested")
      defer:
        removeDir(root)
        removeDir(sibling)
      # The pid files live beside the shells, so neither argv names the
      # OTHER tree: only the cwd distinguishes them.
      var own = startTree(root / "nested", "child.pid")
      var other = startTree(sibling, "child.pid")
      defer:
        closeTree(own)
        closeTree(other)
      let ownChild = waitForChildPid(root / "nested" / "child.pid")
      let otherChild = waitForChildPid(sibling / "child.pid")
      check fixtureProcessIds("").len == 0
      expect ValueError:
        discard fixtureProcessIds($DirSep)
      let ownPids = fixtureProcessIds(root)
      check own.processID in ownPids
      check ownChild in ownPids
      check other.processID notin ownPids
      check otherChild notin ownPids
      # This process is never its own fixture, even standing in the tree.
      let previousCwd = getCurrentDir()
      setCurrentDir(root)
      defer: setCurrentDir(previousCwd)
      check getCurrentProcessId() notin fixtureProcessIds(root)
      reapFixtureProcesses(root)
      setCurrentDir(previousCwd)
      check fixtureProcessIds(root).len == 0
      check not own.running()
      discard own.waitForExit()     # reap the direct child, not just its cwd
      check other.running()
      let surviving = fixtureProcessIds(sibling)
      check other.processID in surviving
      check otherChild in surviving
    else:
      skip("needs a live process-table witness: Linux /proc or macOS libproc")

  test "the argv witness reaps a process whose cwd is elsewhere":
    when defined(linux):
      let root = createTempDir("repro-fixture-reap-argv-", "")
      let sibling = root & "-unrelated"
      let elsewhere = createTempDir("repro-fixture-reap-cwd-", "")
      createDir(sibling)
      defer:
        removeDir(root)
        removeDir(sibling)
        removeDir(elsewhere)
      # Both shells stand in `elsewhere` and write their pid files there,
      # so the cwd witness cannot decide either one. The `--session-dir`
      # token is the spelling `__repro-dev-session-http` carries.
      var named = startTree(elsewhere, elsewhere / "named.pid",
        @["--session-dir", root / "p1" / "session"])
      var unrelated = startTree(elsewhere, elsewhere / "unrelated.pid",
        @["--session-dir=" & sibling / "p1" / "session"])
      defer:
        closeTree(named)
        closeTree(unrelated)
      let namedChild = waitForChildPid(elsewhere / "named.pid")
      let unrelatedChild = waitForChildPid(elsewhere / "unrelated.pid")
      let pids = fixtureProcessIds(root)
      check named.processID in pids
      # The `sleep` child names nothing and stands in `elsewhere`: no
      # witness ties it to the fixture, so it is NOT reported. It stops
      # with its shell through the TERM trap.
      check namedChild notin pids
      check unrelated.processID notin pids
      check unrelatedChild notin pids
      reapFixtureProcesses(root)
      check fixtureProcessIds(root).len == 0
      discard named.waitForExit()
      check not named.running()
      check unrelated.running()
      check unrelated.processID in fixtureProcessIds(sibling)
      # The tree's removal does not end the argv witness: a process whose
      # argv names a deleted root is still found, which is why a teardown
      # may reap after `removeDir` on Linux (but should not rely on it).
      removeDir(root)
      var late = startTree(elsewhere, elsewhere / "late.pid",
        @[root / "gone"])
      defer: closeTree(late)
      discard waitForChildPid(elsewhere / "late.pid")
      check late.processID in fixtureProcessIds(root)
      reapFixtureProcesses(root)
      discard late.waitForExit()
      check fixtureProcessIds(root).len == 0
    else:
      skip("only Linux has an argv witness; macOS reaps by cwd alone")

  test "the cwd witness still finds a process whose fixture dir was deleted":
    # The F1 residue in its measured shape: the shared nix helper outlived
    # its case with `/proc/<pid>/cwd` reading `<root>/p1 (deleted)`. The
    # kernel's ` (deleted)` marker must not hide such a process -- neither
    # one standing in the removed root itself nor one below it -- or a
    # teardown that removes the tree first would report it clean.
    when defined(linux):
      let root = createTempDir("repro-fixture-reap-deleted-", "")
      let elsewhere = createTempDir("repro-fixture-reap-deleted-pids-", "")
      createDir(root / "p1")
      defer:
        removeDir(root)
        removeDir(elsewhere)
      # Pid files outside the root, so argv names `elsewhere` only and the
      # cwd is the one witness that can decide.
      var atRoot = startTree(root, elsewhere / "root.pid")
      var below = startTree(root / "p1", elsewhere / "below.pid")
      defer:
        closeTree(atRoot)
        closeTree(below)
      let atRootChild = waitForChildPid(elsewhere / "root.pid")
      let belowChild = waitForChildPid(elsewhere / "below.pid")
      # The resolved spelling, taken while the tree exists: once it is gone
      # a symlinked `TMPDIR` can no longer be resolved, and /proc reports
      # the resolved path (the module header records that limit).
      let resolved = expandFilename(root)
      removeDir(root)
      check not dirExists(resolved)
      # Positive control: the kernel really reports these cwds as deleted,
      # so the case below exercises the marker rather than a live path.
      check expandSymlink("/proc/" & $below.processID & "/cwd") ==
        resolved / "p1" & " (deleted)"
      let pids = fixtureProcessIds(resolved)
      check atRoot.processID in pids
      check atRootChild in pids
      check below.processID in pids
      check belowChild in pids
      reapFixtureProcesses(resolved)
      check fixtureProcessIds(resolved).len == 0
      discard atRoot.waitForExit()
      discard below.waitForExit()
    else:
      skip("only Linux reports a deleted cwd through /proc")

  test "a failed prerequisite unwinds teardown before its tree is removed":
    when defined(linux) or defined(macosx):
      let root = createTempDir("repro-fixture-reap-failure-", "")
      defer: removeDir(root)
      var childPid = 0
      proc failAfterStartingFixture() =
        var process = startTree(root, "child.pid")
        defer:
          reapFixtureProcesses(root)
          closeTree(process)
        childPid = waitForChildPid(root / "child.pid")
        check childPid in fixtureProcessIds(root)
        raise newException(AssertionDefect, "fixture prerequisite failed")
      expect AssertionDefect:
        failAfterStartingFixture()
      check childPid > 0
      check fixtureProcessIds(root).len == 0
    else:
      skip("needs a live process-table witness: Linux /proc or macOS libproc")
