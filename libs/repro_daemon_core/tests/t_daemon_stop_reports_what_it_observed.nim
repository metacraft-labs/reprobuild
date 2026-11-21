## `requestUserDaemonShutdown` says what it observed after the shutdown ACK,
## and a stop whose daemon is gone is a successful stop.
##
## reprobuild-pm issue 2026-11-16 ("`repro daemon stop` reports 'did not
## release its endpoint within 5 s' even when the daemon exited"). The wait
## after the ACK raised ONE sentence,
##
##   user-daemon at <endpoint> accepted shutdown ACK but did not release its
##   endpoint within 5 s
##
## from two unrelated conditions: the endpoint still accepting connections,
## and the endpoint CLOSED with `<state dir>/.repro-daemon.lock` still on
## disk 5 s later. The second was reported on a Windows host whose daemon had
## exited: the sentence was false about the endpoint, and the command failed
## although the daemon was gone.
##
## WHAT THESE CASES ASSERT.
##
## 1. A lockfile the exiting daemon left behind does not fail the stop. The
##    stop returns, names the file as `staleLockPath`, and the note a command
##    prints says no process holds the lock. A daemon then starts on the same
##    state directory, which is what "the next start takes it over" promises.
## 2. A lock that is still HELD after the endpoint closed does fail the stop,
##    and the error names the lock and its path and says the endpoint closed.
##    It must not say the endpoint was not released.
## 3. An ordinary stop reports nothing: no leftover, no note.
## 4. An endpoint that keeps accepting connections fails the stop, and the
##    error says that.
## 5. A lock held by a DIFFERENT daemon, one whose pid the lockfile names,
##    does not fail the stop: the daemon that was asked is gone. The result
##    names the successor, so a caller does not clean up after it.
## 6. A lockfile that names a pid no process has, and whose lock nobody
##    holds, is a leftover: the stop does not report a dead "successor" as
##    left running, and the caller's cleanup still runs.
##
## Not covered here: a lockfile that cannot be opened at all (it needs a file
## this user may not open, and the suite also runs as root), and the two
## lines `repro daemon stop` prints, which are `userDaemonShutdownNote`'s
## text behind a fixed prefix.
##
## WITHOUT THE FIX this file does not compile (`UserDaemonShutdownResult` and
## `userDaemonShutdownNote` did not exist). Against the old wait, cases 1 and
## 2 both end in the sentence above: case 1 raises where it must return, and
## case 2's message blames the endpoint. Cases 4 and 5 end in it as well.
##
## HOW THE LEFTOVER IS MADE. The daemon removes its lockfile last, and only
## when the file still carries the token it wrote
## (`releaseUserDaemonLock`); any failure there is swallowed and the daemon
## exits. On POSIX the test rewrites the token while the daemon runs, so the
## daemon declines to remove the file. On Windows it holds the file open
## without delete sharing, so the daemon's removal fails the way it does when
## a scanner or indexer has the file, which is the field mechanism. Either
## way the daemon is a real `repro daemon serve --foreground`, exits on its
## own through the production shutdown path, and the file it leaves is the
## one the production release declined to remove.
##
## WHY CASES 2, 4, 5 AND 6 USE A SCRIPTED DAEMON, and why it is not a mock of the code
## under test. A real daemon releases its lock microseconds after closing its
## listener; none this tree can start stays alive holding it, keeps
## listening after its ACK, or hands its state directory on. So the daemon
## side is an in-process accept loop over the REAL `IpcListener` and the REAL
## frame encoders (`helloAckBody`, `statusBody`) that answers status and
## shutdown as a daemon does, closes its endpoint, and keeps a real `flock`
## on the lockfile. The client side, `requestUserDaemonShutdown` and the lock
## probe, is the production path, unmodified.
## (`t_daemon_missing_feature_refusal` embeds a daemon the same way.)
##
## MOCK POLICY: no mocks beyond that scripted peer. Real sockets, real locks,
## real files. Every daemon this file starts is killed in a `defer`.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_core
import repro_daemon_core
from repro_cli_support/daemon_cli import userDaemonConfigOfArgs

const
  FixtureFlag = "--daemon-fixture"
  OldSentence = "did not release its endpoint"

if paramCount() >= 1 and paramStr(1) == FixtureFlag:
  # `repro daemon serve --foreground <flags>`, in this process.
  quit(runUserDaemonForeground(userDaemonConfigOfArgs(
    @["daemon", "serve", "--foreground"] & commandLineParams()[1 .. ^1])))

when defined(posix):
  import std/[atomics, posix]
  from repro_test_support/process_fixtures import shortSocketDirAtProcessExit

  proc cFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

  proc scratchDir(): string =
    ## Short enough for a Unix-socket path whatever TMPDIR is
    ## (process_fixtures.shortSocketDirAtProcessExit says why).
    createTempDir("repro-stop-", "", shortSocketDirAtProcessExit("st-"))

  proc endpointIn(scratch: string): string = scratch / "run" / "d.sock"
else:
  proc scratchDir(): string = createTempDir("repro-stop-", "")

  proc endpointIn(scratch: string): string =
    r"\\.\pipe\repro-stop-" & $getCurrentProcessId() & "-" &
      scratch.extractFilename

type Daemon = object
  process: Process
  endpoint: string

proc startDaemon(endpoint, stateDir: string): Daemon =
  result.endpoint = endpoint
  result.process = startProcess(getAppFilename(),
    args = [FixtureFlag, "--endpoint", endpoint, "--state-dir", stateDir],
    options = {poParentStreams})
  discard waitForUserDaemonStatus(endpoint, 30_000)

proc killDaemon(daemon: var Daemon) =
  if daemon.process != nil:
    if daemon.process.running:
      daemon.process.kill()
    discard daemon.process.waitForExit()
    daemon.process.close()
    daemon.process = nil

proc exitedWithin(daemon: Daemon; ms: int): bool =
  for _ in 0 ..< ms div 25:
    if not daemon.process.running:
      return true
    sleep(25)
  not daemon.process.running

# The lease reaper reads a lease store outside the scratch directory; these
# cases have no leases and must not touch one.
putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "0")

suite "a daemon stop reports what it observed":

  test "a lockfile left by a daemon that exited does not fail the stop":
    let scratch = scratchDir()
    defer: removeDir(scratch)
    let stateDir = scratch / "state"
    let endpoint = endpointIn(scratch)
    let lockPath = stateDir / UserDaemonLockFileName
    var daemon = startDaemon(endpoint, stateDir)
    defer: daemon.killDaemon()
    check fileExists(lockPath)
    # Premise: while the daemon lives, the probe sees its lock as held.
    check probeUserDaemonLock(lockPath).state == udlHeld

    when defined(windows):
      # No delete sharing: the daemon's `removeFile` fails while this is open.
      var pin = open(lockPath, fmRead)
    else:
      let original = readFile(lockPath)
      check "token=" in original
      writeFile(lockPath, original.replace("token=", "token=not-this-daemon-"))

    var outcome: UserDaemonShutdownResult
    var raised = ""
    try:
      outcome = requestUserDaemonShutdown(endpoint)
    except UserDaemonClientError as exc:
      raised = exc.msg
    when defined(windows):
      pin.close()
    checkpoint("raised: " & raised)
    check raised == ""

    # Premises, so the result below is about the condition in the issue: the
    # daemon process really ended, on its own, and really left the file.
    check daemon.exitedWithin(10_000)
    check fileExists(lockPath)
    check userDaemonProcessGone(daemon.process.processID)
    check not userDaemonEndpointAcceptsConnections(endpoint)

    check outcome.staleLockPath == lockPath
    check outcome.successorPid == 0
    let note = userDaemonShutdownNote(outcome)
    checkpoint("note: " & note)
    check lockPath in note
    check "released its lock" in note
    check "no process holds the lock" in note
    check OldSentence notin note
    check probeUserDaemonLock(lockPath).state == udlFree

    # "The next daemon start takes it over."
    daemon.killDaemon()
    var next = startDaemon(endpoint, stateDir)
    defer: next.killDaemon()
    check queryUserDaemonStatus(endpoint).running
    check probeUserDaemonLock(lockPath).state == udlHeld
    # ...and that daemon, whose lockfile is intact, stops with nothing to say.
    let clean = requestUserDaemonShutdown(endpoint)
    check clean.staleLockPath == ""
    check userDaemonShutdownNote(clean) == ""
    check not fileExists(lockPath)

  test "an ordinary stop reports no leftover":
    let scratch = scratchDir()
    defer: removeDir(scratch)
    let stateDir = scratch / "state"
    let endpoint = endpointIn(scratch)
    var daemon = startDaemon(endpoint, stateDir)
    defer: daemon.killDaemon()
    let outcome = requestUserDaemonShutdown(endpoint)
    check outcome == UserDaemonShutdownResult()
    check userDaemonShutdownNote(outcome) == ""
    check probeUserDaemonLock(stateDir / UserDaemonLockFileName).state ==
      udlAbsent
    check daemon.exitedWithin(10_000)

  when defined(posix):
    type
      ScriptedMode = enum
        smHoldsLock       ## closes the endpoint, keeps the lock
        smKeepsListening  ## ACKs, then goes on accepting connections
        smHandedOver      ## as smHoldsLock, but the status it gave named
                          ## another pid: the lock's holder is a successor
        smDeadPidLeft     ## the status named another pid, the lockfile names
                          ## a pid that does not exist, and the lock is let
                          ## go with the endpoint: a successor that died
      ScriptedArgs = tuple[endpoint, stateDir: string; mode: ScriptedMode]

    const StoppedDaemonPid = 0x3fff_fff0'i64
      ## The pid the smHandedOver daemon reports for itself: not this
      ## process, which holds the lock as the "successor".
    const GonePid = 0x3fff_fff1'i64
      ## Above every platform's pid limit, so no process has it.

    var scriptedReady: Atomic[bool]
    var scriptedRelease: Atomic[bool]

    proc runScriptedDaemon(args: ScriptedArgs) {.thread.} =
      ## Answer status queries and a shutdown as a daemon does, then do what
      ## ``args.mode`` says, keeping the state-directory lock until told to
      ## let go.
      createDir(args.stateDir)
      let lockPath = args.stateDir / UserDaemonLockFileName
      let lockfilePid =
        if args.mode == smDeadPidLeft: GonePid
        else: getCurrentProcessId().int64
      writeFile(lockPath, "role=" & UserDaemonRole & "\npid=" &
        $lockfilePid & "\n")
      let fd = posix.open(lockPath.cstring, O_RDWR or posix.O_CLOEXEC)
      doAssert fd >= 0
      doAssert cFlock(fd, 2.cint or 4.cint) == 0  # LOCK_EX or LOCK_NB
      var listener = bindIpcListener(args.endpoint)
      scriptedReady.store(true)
      let identity = binaryIdentity("repro", getAppFilename(), versionString())
      let reportedPid =
        if args.mode in {smHandedOver, smDeadPidLeft}: StoppedDaemonPid
        else: getCurrentProcessId().int64
      var stopping = false
      while not scriptedRelease.load() and
          not (stopping and args.mode != smKeepsListening):
        if not listener.waitForClient(50):
          continue
        var conn = listener.acceptIpc()
        try:
          if conn.readFrame(10_000).kind == udkHello:
            conn.writeFrame(udkHelloAck, helloAckBody(identity,
              UserDaemonFeatureFlags, "scripted"), timeoutMs = 10_000)
            let request = conn.readFrame(10_000)
            if request.kind == udkStatus:
              conn.writeFrame(udkStatusResponse, statusBody(UserDaemonStatus(
                running: true, role: UserDaemonRole, endpoint: args.endpoint,
                stateDir: args.stateDir, pid: reportedPid,
                protocolMajor: UserDaemonProtocolMajor,
                protocolMinor: UserDaemonProtocolMinor, binary: identity,
                featureFlags: UserDaemonFeatureFlags,
                generation: "scripted")), timeoutMs = 10_000)
            elif request.kind == udkShutdown:
              conn.writeFrame(udkShutdownAck, timeoutMs = 10_000)
              stopping = true
        except CatchableError:
          discard
        conn.closeIpcConn()
      closeIpcListener(listener)
      for _ in 0 ..< 3000:
        if scriptedRelease.load() or args.mode == smDeadPidLeft:
          break
        sleep(10)
      discard posix.close(fd)

    type ScriptedStop = object
      raised: string
      outcome: UserDaemonShutdownResult
      endpointAccepting: bool
      lockState: UserDaemonLockState
      lockPath: string

    proc stopScripted(mode: ScriptedMode): ScriptedStop =
      ## Stop a scripted daemon in ``mode`` through the production client,
      ## and read the premises while it is still in that state.
      let scratch = scratchDir()
      defer: removeDir(scratch)
      let stateDir = scratch / "state"
      let endpoint = endpointIn(scratch)
      result.lockPath = stateDir / UserDaemonLockFileName
      createDir(parentDir(endpoint))
      scriptedReady.store(false)
      scriptedRelease.store(false)
      var thread: Thread[ScriptedArgs]
      createThread(thread, runScriptedDaemon, (endpoint, stateDir, mode))
      defer:
        scriptedRelease.store(true)
        joinThread(thread)
      for _ in 0 ..< 500:
        if scriptedReady.load():
          break
        sleep(10)
      doAssert scriptedReady.load(), "scripted daemon never bound " & endpoint
      try:
        result.outcome = requestUserDaemonShutdown(endpoint)
      except UserDaemonClientError as exc:
        result.raised = exc.msg
      result.endpointAccepting = userDaemonEndpointAcceptsConnections(endpoint)
      result.lockState = probeUserDaemonLock(result.lockPath).state

    test "a lock still held after the endpoint closed is reported as that":
      let stop = stopScripted(smHoldsLock)
      checkpoint("raised: " & stop.raised)
      # Premises: the endpoint did close, and the lock was held.
      check not stop.endpointAccepting
      check stop.lockState == udlHeld

      check stop.raised != ""
      check OldSentence notin stop.raised
      check "closed its endpoint" in stop.raised
      check "is still held 5 s later" in stop.raised
      check stop.lockPath in stop.raised
      # The holder is this live process, and the message says so.
      check ("pid " & $getCurrentProcessId()) in stop.raised
      check "still exists" in stop.raised

    test "an endpoint that keeps accepting connections is reported as that":
      let stop = stopScripted(smKeepsListening)
      checkpoint("raised: " & stop.raised)
      check stop.endpointAccepting
      check stop.raised != ""
      check OldSentence notin stop.raised
      check "is still accepting connections 5 s later" in stop.raised
      check "lock" notin stop.raised

    test "a lock held by another daemon does not fail the stop":
      let stop = stopScripted(smHandedOver)
      checkpoint("raised: " & stop.raised)
      check not stop.endpointAccepting
      check stop.lockState == udlHeld
      check stop.raised == ""
      check stop.outcome.successorPid == getCurrentProcessId().int64
      check stop.outcome.staleLockPath == ""
      let note = userDaemonShutdownNote(stop.outcome)
      checkpoint("note: " & note)
      check ("another daemon (pid " & $getCurrentProcessId() & ")") in note
      check "left running" in note

    test "a lockfile naming a pid that is gone is a leftover, not a successor":
      let stop = stopScripted(smDeadPidLeft)
      checkpoint("raised: " & stop.raised)
      check not stop.endpointAccepting
      check stop.lockState == udlFree
      check userDaemonProcessGone(GonePid)
      check stop.raised == ""
      check stop.outcome.successorPid == 0
      check stop.outcome.staleLockPath == stop.lockPath
      check "no process holds the lock" in userDaemonShutdownNote(stop.outcome)
