## A build that is asked to stop by a terminating signal stops the actions it
## is running before its process dies of that signal.
##
## The failure this protects against: the scheduler runs every action in a
## process group of its own, so a SIGTERM from `timeout` (or a terminal's
## SIGINT, or SIGHUP) reached the engine only. Under the default disposition
## the engine died at once, the scheduler's teardown never ran, and every
## running action kept running as an orphan with its whole tree. `timeout`
## killing `repro lint` left the interface extraction it had started spinning
## on a core for hours.
##
## Each case runs the real `runBuild` in a real child process (this binary,
## re-executed in the `build` role). The graph's one action starts a
## grandchild in the background, records both pids and waits, so it never
## finishes on its own. The parent waits for both pid files, sends the signal
## to the build process only (as `timeout` does), and then requires:
##
## * the build process ended by that same signal, so a caller's exit status
##   reads as before (`timeout` and shells report 128 + signal);
## * the action and its grandchild are gone, not reparented and still running.
##
## The negative control is a case of its own: SIGKILL cannot be caught, so a
## build killed with it MUST leave its action running. That case is what shows
## the "gone" checks can see a survivor at all; without it a pid that was
## never alive would pass them. A second control shows that a host which
## ignores the signal keeps its own disposition: the build is not cancelled
## and the process does not die.
##
## MOCK POLICY -- NO MOCKS ARE USED IN THIS FILE. The scheduler, the RunQuota
## bypass launch path, `/bin/sh`, `sleep`, the signals and the process table
## are all real. POSIX only: Windows has no such signals.

import std/[os, osproc, strutils, tempfiles, times, unittest]

when defined(posix):
  import std/posix

  import repro_build_engine
  import repro_core

  const
    RoleFlag = "--interrupted-build-role="
    RootFlag = "--root="
    IgnoreFlag = "--ignore-signal="
    WaitForPidsSec = 120.0
      ## The child compiles nothing; it only has to start one action. Wide,
      ## so a loaded shared host does not turn slowness into a failure.
    WaitForExitSec = 60.0
    WaitForGoneSec = 30.0

  proc actionScript(root: string): string =
    ## Starts a grandchild, records both pids, then waits for the grandchild,
    ## so the action ends only when something stops it.
    "sleep 600 &\n" &
    "echo $! > " & quoteShell(root / "grandchild.pid") & ".tmp\n" &
    "mv " & quoteShell(root / "grandchild.pid") & ".tmp " &
      quoteShell(root / "grandchild.pid") & "\n" &
    "echo $$ > " & quoteShell(root / "action.pid") & ".tmp\n" &
    "mv " & quoteShell(root / "action.pid") & ".tmp " &
      quoteShell(root / "action.pid") & "\n" &
    "wait\n"

  proc runBuildRole(root: string; ignoreSignal: cint) =
    ## The child: one never-ending action through the real scheduler.
    # The cases are about a host with the default dispositions, so do not
    # inherit an ignored SIGTERM or SIGHUP from whatever started the suite
    # (`nohup`, a supervisor). SIGINT is left alone: the Nim runtime has
    # already installed its own handler for it, which is the default case.
    for sig in [SIGTERM, SIGHUP]:
      discard signal(sig, SIG_DFL)
    if ignoreSignal != 0:
      discard signal(ignoreSignal, SIG_IGN)
    let work = root / "work"
    createDir(work / "out")
    var config = defaultBuildEngineConfig(root / "cache")
    config.bypassRunQuota = true
    config.maxParallelism = 1'u32
    let g = graph([action("run/forever",
      ["/bin/sh", "-c", actionScript(root)],
      cwd = work,
      outputs = ["out/never.out"],
      # A depfile selects the legacy gathering policy, so the action needs
      # no live io monitor (as in `t_soft_rebuild_and_retention`).
      depfile = "out/never.dep",
      cacheable = false,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())])
    try:
      discard runBuild(g, config)
    except CatchableError as err:
      stderr.writeLine("build ended: " & err.msg)
    # Reached only when the build was not stopped by a signal at all.
    writeFile(root / "build-returned", "")
    quit(0)

  proc readPid(path: string): Pid =
    Pid(parseInt(readFile(path).strip()))

  proc isAlive(pid: Pid): bool =
    ## Running, or at least not yet reaped and not a zombie. A zombie has
    ## finished; only its parent's wait is missing.
    if kill(pid, 0) != 0:
      return false
    let stat = "/proc/" & $pid & "/stat"
    if fileExists(stat):
      let text = try: readFile(stat) except IOError: ""
      let close = text.rfind(')')
      if close >= 0 and close + 2 < text.len and text[close + 2] == 'Z':
        return false
    true

  proc waitUntil(deadlineSec: float; cond: proc (): bool): bool =
    let deadline = epochTime() + deadlineSec
    while epochTime() < deadline:
      if cond():
        return true
      sleep(50)
    cond()

  type Outcome = object
    root: string
    buildPid: Pid
    action, grandchild: Pid
    status: cint
    exited: bool

  proc startBuild(ignoreSignal: cint = 0): Outcome =
    result.root = createTempDir("repro-interrupted-build-", "")
    let root = result.root
    var args = @[RoleFlag & "build", RootFlag & root]
    if ignoreSignal != 0:
      args.add(IgnoreFlag & $ignoreSignal)
    let child = startProcess(getAppFilename(), args = args,
      options = {poParentStreams})
    result.buildPid = Pid(processID(child))
    let ready = waitUntil(WaitForPidsSec, proc (): bool =
      fileExists(root / "action.pid") and fileExists(root / "grandchild.pid"))
    doAssert ready, "the build never started its action (root " & root & ")"
    result.action = readPid(root / "action.pid")
    result.grandchild = readPid(root / "grandchild.pid")
    doAssert isAlive(result.action) and isAlive(result.grandchild)

  proc awaitBuildExit(o: var Outcome; deadlineSec = WaitForExitSec) =
    ## Reaps the build process with a raw `waitpid`, so the signal that ended
    ## it is read from the status itself.
    let deadline = epochTime() + deadlineSec
    while epochTime() < deadline:
      var status: cint
      let r = waitpid(o.buildPid, status, WNOHANG)
      if r == o.buildPid:
        o.status = status
        o.exited = true
        return
      sleep(50)

  proc cleanup(o: Outcome) =
    for pid in [o.grandchild, o.action, o.buildPid]:
      if pid > 0 and isAlive(pid):
        discard kill(pid, SIGKILL)
    if not o.exited and o.buildPid > 0:
      var status: cint
      discard waitpid(o.buildPid, status, 0)
    removeDir(o.root)

  type Interrupted = object
    ## What one interrupted build was seen to do. Each case checks every
    ## field itself, so its assertions are in its own body.
    sent: bool
      ## `kill` delivered the signal to the build process.
    exited: bool
      ## The build process ended within `WaitForExitSec`.
    deathSignal: cint
      ## The signal that ended it, or 0 when it did not end by a signal.
    buildReturned: bool
      ## `runBuild` returned to its caller (it must not: the process dies).
    actionsGone: bool
      ## The action and its grandchild were both gone within
      ## `WaitForGoneSec`.

  proc interruptBuild(sig: cint): Interrupted =
    ## Starts a build, sends `sig` to the build process alone (as `timeout`
    ## does) and records what followed.
    var o = startBuild()
    defer: cleanup(o)
    result.sent = kill(o.buildPid, sig) == 0
    o.awaitBuildExit()
    result.exited = o.exited
    if o.exited and WIFSIGNALED(o.status):
      result.deathSignal = WTERMSIG(o.status)
    result.buildReturned = fileExists(o.root / "build-returned")
    let action = o.action
    let grandchild = o.grandchild
    result.actionsGone = waitUntil(WaitForGoneSec, proc (): bool =
      not isAlive(action) and not isAlive(grandchild))

  let roleArg = block:
    var r = ""
    for i in 1 .. paramCount():
      if paramStr(i).startsWith(RoleFlag):
        r = paramStr(i)[RoleFlag.len .. ^1]
    r

  if roleArg == "build":
    var root = ""
    var ignoreSignal: cint = 0
    for i in 1 .. paramCount():
      let a = paramStr(i)
      if a.startsWith(RootFlag):
        root = a[RootFlag.len .. ^1]
      elif a.startsWith(IgnoreFlag):
        ignoreSignal = cint(parseInt(a[IgnoreFlag.len .. ^1]))
    runBuildRole(root, ignoreSignal)

  suite "an interrupted build stops its running actions":

    test "SIGTERM: the actions stop and the build dies of SIGTERM":
      let r = interruptBuild(SIGTERM)
      check r.sent
      check r.exited
      check r.deathSignal == SIGTERM
      check not r.buildReturned
      check r.actionsGone

    test "SIGINT: the actions stop and the build dies of SIGINT":
      let r = interruptBuild(SIGINT)
      check r.sent
      check r.exited
      check r.deathSignal == SIGINT
      check not r.buildReturned
      check r.actionsGone

    test "SIGHUP: the actions stop and the build dies of SIGHUP":
      let r = interruptBuild(SIGHUP)
      check r.sent
      check r.exited
      check r.deathSignal == SIGHUP
      check not r.buildReturned
      check r.actionsGone

    test "negative control: SIGKILL cannot be caught, so the action survives":
      var o = startBuild()
      defer: cleanup(o)
      check kill(o.buildPid, SIGKILL) == 0
      o.awaitBuildExit()
      check o.exited
      check WIFSIGNALED(o.status) and WTERMSIG(o.status) == SIGKILL
      # Give a teardown, were there one, the time the other cases allow.
      sleep(2000)
      check isAlive(o.action)
      check isAlive(o.grandchild)

    test "a host that ignores SIGTERM keeps its disposition; nothing is cancelled":
      var o = startBuild(ignoreSignal = SIGTERM)
      defer: cleanup(o)
      check kill(o.buildPid, SIGTERM) == 0
      o.awaitBuildExit(deadlineSec = 3.0)
      check not o.exited
      check isAlive(o.action)
      check isAlive(o.grandchild)

else:
  import repro_test_support/reasoned_skip
  suite "an interrupted build stops its running actions":
    test "POSIX only":
      skip("POSIX signal delivery only; Windows has no such signals")
