## Find and reap the processes a test fixture started, by a live witness.
##
## A test that drives `repro up` / `repro dev` against a throwaway tree
## starts processes it does not hold handles to: the dev session's
## `__repro-dev-session-http` child, declared service shells such as
## `sh scripts/idp.sh`, and whatever those fork. `repro down` cannot stop a
## `repro dev` session, and `reapSession` signals only the pids a session
## PUBLISHED, so the graceful teardown leaves them running. Measured: a
## review of D-SS11 had to kill 12 orphaned `repro-dev-session-http`
## processes and 4 orphaned `idp.sh` loops accumulated over that file's
## runs, and F1 (`t_dssf1_repro_up_builds_the_rendered_config.nim`), which
## had no reap, was recorded leaving the same HTTP children (reprobuild-pm
## issue `2026-10-20-the-f1-up-case-leaves-its-dev-session-http-processes-running`).
##
## WHY A LIVE WITNESS AND NOT A PID LIST. A pid is a HISTORICAL RECORD, not
## a handle. Between a process exiting and a teardown running, its number
## can be reissued -- to a nim compiler, to a parallel test's fixture, to a
## login shell. Killing by number alone turns a reap of a dead fixture into
## an attack on a live stranger, and SIGKILL gives the stranger no say. This
## host runs CI jobs concurrently with developer trees, so that is not
## hypothetical. A process is therefore signalled only while the process
## table itself says it belongs to the fixture root, re-read immediately
## before each signal.
##
## TWO WITNESSES ON LINUX, because a fixture's processes do not all name it
## the same way. The daemon and the `__repro-dev-session-http` child carry
## the fixture's directories in their ARGV (`--endpoint`, `--state-dir`,
## `--session-dir`); a declared SERVICE instance is `sh scripts/idp.sh`,
## which names nothing at all -- its only link to the fixture is its WORKING
## DIRECTORY, which the materialiser sets to the project root. Requiring
## argv alone would leave every service process behind. Either witness is
## conclusive when the root is the caller's own `createTempDir` path: no
## process outside the fixture can mention it.
##
## THE CWD WITNESS ALSO CATCHES A SHARED HELPER STARTED FROM THE FIXTURE.
## Measured on Linux at reprobuild `0c0797f4b`: F1's first case leaves the
## per-user `reprobuild-nix-daemon` (spawned detached by
## `requestNixDaemon` with no working directory of its own) running with
## its cwd in that case's deleted project dir, and this reap stops it. It
## restarts on the next request; a concurrent case that is mid-request at
## that instant is the cost, and the remedy belongs to the spawn site, not
## to a narrower witness here. That remedy is in the helper itself: its
## `main` now leaves the launcher's directory (`os.chdir("/")`) before it
## serves, so a helper started from a fixture no longer matches the cwd
## witness and this reap leaves it to the other clients sharing it.
##
## ONE WITNESS ON macOS: the libproc cwd record, through
## `darwin_fixture_processes`. That module states its own reasoning; this
## one only delegates so a test has a single, platform-neutral call.
##
## WHAT THIS IS NOT: a structural guarantee. It is a teardown sweep over a
## process table read at one instant, so a process that forks after the
## final scan is missed, and the real fix is for a session to stop what it
## started on the way out. What it does guarantee is that a leak is never
## SILENT: `reapFixtureProcesses` raises when anything still matches after
## SIGKILL.
##
## ORDER AT THE CALL SITE. Reap after any daemon whose argv names the root
## has been closed gracefully (otherwise the sweep kills it out from under
## the graceful `repro down` calls), and before the tree is removed. The
## macOS witness needs the tree to exist. On Linux both witnesses still
## answer after removal -- argv keeps its text, and a cwd in a deleted
## directory reads `<path> (deleted)`, which is matched -- but a root
## reached through a symlinked `TMPDIR` loses its resolved spelling once
## the tree is gone, so reaping first is the order that always works.

when defined(linux):
  import std/[os, posix, strutils]

  const PathNameChars = Letters + Digits + {'/', '.', '-', '_', '~'}

  proc fixtureRoots(root: string): seq[string] =
    ## The spellings of `root` a witness may report: the caller's spelling
    ## and, while the tree exists, its realpath -- `/proc/<pid>/cwd` is
    ## always resolved, so a temp root under a symlinked `TMPDIR` would
    ## otherwise never match its own cwd.
    if root.len == 0:
      return @[]
    let trimmed =
      if root.len > 1 and root.endsWith('/'): root[0 ..< ^1] else: root
    if trimmed == "/":
      raise newException(ValueError, "A fixture process root cannot be /")
    result = @[trimmed]
    if dirExists(trimmed):
      let canonical = expandFilename(trimmed)
      if canonical == "/":
        raise newException(ValueError, "A fixture process root cannot be /")
      if canonical != trimmed:
        result.add(canonical)

  proc namesRoot(arg, root: string): bool =
    ## Does one argv element name `root` or a path below it? A bare
    ## substring test would let `<root>-unrelated` match, so the occurrence
    ## must end the element or continue with `/`, and must not continue a
    ## longer path name on its left (`--session-dir=<root>/...` matches,
    ## `/elsewhere<root>` does not).
    var start = 0
    while true:
      let at = arg.find(root, start)
      if at < 0:
        return false
      let after = at + root.len
      let leftOk = at == 0 or arg[at - 1] notin PathNameChars
      let rightOk = after == arg.len or arg[after] == '/'
      if leftOk and rightOk:
        return true
      start = at + 1

  const DeletedSuffix = " (deleted)"
    ## What the kernel appends to a `/proc/<pid>/cwd` link whose directory
    ## has been removed (proc(5), "/proc/pid/cwd"; `d_path` in
    ## fs/d_path.c). A process standing in a deleted fixture directory is
    ## exactly the residue this module exists to find, so the marker must
    ## not hide it.

  proc liveCwdPath(link: string): string =
    ## The directory a `/proc/<pid>/cwd` link names, with the kernel's
    ## ` (deleted)` marker removed when the directory is gone. The marker
    ## is stripped only when nothing exists at the marked spelling, so a
    ## live directory really named `... (deleted)` keeps its own name.
    result = link
    if result.endsWith(DeletedSuffix) and not dirExists(result):
      result.setLen(result.len - DeletedSuffix.len)

  proc belongsToFixture(pid: int; roots: seq[string]): bool =
    # Neither this process nor the one that started it (the suite runner,
    # or a shell) is ever a fixture process, whatever its cwd or argv:
    # reaping the runner would end the run that is asking.
    if pid <= 0 or pid == getCurrentProcessId() or pid == int(getppid()) or
        roots.len == 0:
      return false
    # Unreadable identity is never permission: a process that exited, or
    # one this user cannot inspect, reads as empty and is not signalled.
    let cmdline =
      try: readFile("/proc/" & $pid & "/cmdline")
      except CatchableError: ""
    if cmdline.len > 0:
      for arg in cmdline.split('\0'):
        for root in roots:
          if namesRoot(arg, root):
            return true
    let cwd =
      try: liveCwdPath(expandSymlink("/proc/" & $pid & "/cwd"))
      except CatchableError: ""
    if cwd.len == 0:
      return false
    for root in roots:
      if cwd == root or cwd.startsWith(root & "/"):
        return true
    false

  proc fixturePids(roots: seq[string]): seq[int] =
    if roots.len == 0:
      return @[]
    for kind, path in walkDir("/proc"):
      if kind != pcDir:
        continue
      var pid = 0
      try: pid = parseInt(path.extractFilename)
      except ValueError: continue
      if belongsToFixture(pid, roots):
        result.add(pid)

elif defined(macosx):
  import repro_test_support/darwin_fixture_processes

proc fixtureProcessIds*(root: string): seq[int] =
  ## Live processes that belong to the fixture rooted at `root`: on Linux,
  ## those whose argv names `root` (or a path below it) or whose cwd is at
  ## or below it, a deleted cwd included; on macOS, those whose cwd is.
  ## This process and its parent are excluded.
  ## An empty root yields nothing; `/` raises `ValueError`. Elsewhere there
  ## is no witness, so nothing is reported.
  when defined(linux):
    fixturePids(fixtureRoots(root))
  elif defined(macosx):
    darwinFixtureProcessIds(root)
  else:
    @[]

proc reapFixtureProcesses*(root: string) =
  ## Stop every process `fixtureProcessIds(root)` reports, and raise
  ## `OSError` if any still remain after SIGKILL -- so a fixture that leaks
  ## fails its test instead of passing green.
  ##
  ## SIGTERM FIRST, THEN A RE-CHECK, THEN SIGKILL. The re-check is not
  ## belt-and-braces: a pid that exited under the SIGTERM needs no SIGKILL,
  ## and if its number has already been reissued the second signal is
  ## exactly the one that must not be sent. Each pid is re-tested against
  ## the witness immediately before it is signalled.
  ##
  ## `posix.kill` rather than a `kill(1)` command string: the signal is sent
  ## by this process with no shell in the path, which keeps the teardown
  ## clear of `scripts/check_shell_command_strings.sh`'s subject.
  when defined(linux):
    let roots = fixtureRoots(root)
    if roots.len == 0:
      return
    for signal in [SIGTERM, SIGKILL]:
      for pid in fixturePids(roots):
        if belongsToFixture(pid, roots):
          if posix.kill(Pid(pid), signal) != 0 and errno != ESRCH:
            raiseOSError(osLastError(),
              "Cannot stop fixture process " & $pid)
      for attempt in 0 ..< 20:
        if fixturePids(roots).len == 0:
          return
        sleep(50)
    let remaining = fixturePids(roots)
    if remaining.len > 0:
      raise newException(OSError,
        "Fixture processes remain under " & root & ": " & $remaining)
  elif defined(macosx):
    reapDarwinFixtureProcesses(root)
  else:
    discard
