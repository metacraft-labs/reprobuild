## ``repro_test_support/owned_processes`` stops exactly the process a test
## started through the product, and nothing that merely LOOKS like it.
##
## Each case runs a BYSTANDER beside its target: a process of the same user
## whose command line names the same socket path, or runs the same command,
## so a ``pkill -f`` of the target's pattern would have stopped it too (the
## hazard of reprobuild-pm issue 2026-11-13, "reprobuild tests and committed
## root scripts kill processes by pattern"). The bystander must survive every
## stop; the target must be gone.
##
## No mocks: real Unix sockets served by this binary re-invoked as a server,
## the real ``setsid``, real process groups. POSIX only; the module is a
## no-op on Windows, and the cases say so instead of passing vacuously.

import std/[net, os, osproc, posix, strutils, tempfiles, times, unittest]

import repro_test_support/owned_processes
import repro_test_support/reasoned_skip

const ServerMode = "owned-processes-socket-server"

let params = commandLineParams()
if params.len == 3 and params[0] == ServerMode:
  # <socket path to serve> <a path named only so the argv matches>
  let server = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  server.bindUnix(params[1])
  server.listen()
  while true:
    var client: Socket
    server.accept(client)
    client.close()

proc startServer(socketPath, alsoNamed: string): Process =
  result = startProcess(getAppFilename(),
    args = [ServerMode, socketPath, alsoNamed], options = {})
  let deadline = epochTime() + 30.0
  while unixSocketServerPid(socketPath) != result.processID:
    doAssert epochTime() < deadline, "the fixture server never listened on " &
      socketPath
    doAssert result.running, "the fixture server exited early"
    sleep(20)

proc stopFixture(p: Process) =
  ## Stop a fixture this case holds the handle of. A server the module
  ## already stopped was also reaped by it (it is this process's child), so
  ## the handle then reports ``ECHILD``; that is the module's documented
  ## behaviour, not a failure of the teardown.
  try:
    if p.running:
      p.kill()
    discard p.waitForExit()
  except OSError:
    discard
  p.close()

proc pidAlive(pid: int): bool = posix.kill(Pid(pid), 0) == 0

proc waitFor(cond: proc (): bool; seconds = 30.0): bool =
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    if cond():
      return true
    sleep(20)
  cond()

proc groupAlive(pgid: int): bool = posix.kill(Pid(-pgid), 0) == 0

suite "owned_processes":

  test "stopUnixSocketServer stops the socket's server, not a process naming it":
    if not defined(posix):
      skip("[platform N/A] owned_processes is POSIX-only; it is a " &
        "no-op on Windows")
    else:
      let dir = createTempDir("repro-owned-sock-", "")
      defer: removeDir(dir)
      let target = dir / "target.sock"
      let other = dir / "other.sock"
      let server = startServer(target, dir / "unused")
      defer: stopFixture(server)
      # Names the TARGET's socket path in its argv: `pkill -f target.sock`
      # would stop it.
      let bystander = startServer(other, target)
      defer: stopFixture(bystander)
      let serverPid = server.processID
      check unixSocketServerPid(target) == serverPid
      check stopUnixSocketServer(target, graceMs = 5_000)
      # Gone, and reaped: the module waits for a child it stops.
      check not pidAlive(serverPid)
      check bystander.running
      check unixSocketServerPid(other) == bystander.processID

  test "a path nothing serves stops nothing":
    if not defined(posix):
      skip("[platform N/A] owned_processes is POSIX-only; it is a " &
        "no-op on Windows")
    else:
      let dir = createTempDir("repro-owned-stale-", "")
      defer: removeDir(dir)
      check not stopUnixSocketServer(dir / "absent.sock")
      # A socket file whose server is gone: connecting is refused.
      let stale = dir / "stale.sock"
      let server = startServer(stale, dir / "unused")
      server.kill()
      discard server.waitForExit()
      server.close()
      check posix.access(stale.cstring, F_OK) == 0
      check unixSocketServerPid(stale) == -1
      check not stopUnixSocketServer(stale)

  test "the setsid recorder lets a test stop the session it detached, only it":
    if not defined(posix):
      skip("[platform N/A] owned_processes is POSIX-only; it is a " &
        "no-op on Windows")
    elif findExe("setsid").len == 0:
      skip("[missing] no setsid on PATH: nothing could detach " &
        "through one, so there is nothing to record")
    else:
      let dir = createTempDir("repro-owned-setsid-", "")
      defer: removeDir(dir)
      let record = dir / "sessions"
      check installSetsidRecorder(dir / "bin", record, findExe("setsid"))
      let marker = "4" & $(getCurrentProcessId() mod 100_000) & "1"
      # The bystander runs the very command the detached session runs.
      let bystander = startProcess("sleep", args = [marker],
        options = {poUsePath})
      defer: stopFixture(bystander)
      # Detached the way the product's post-commit push is: `setsid` resolved
      # through PATH from a shell, backgrounded, with its stdio closed, and
      # the launching shell gone at once.
      let launch = execCmd("PATH=" & quoteShell(dir / "bin") & ":\"$PATH\" " &
        "sh -c " & quoteShell("setsid sh -c 'sleep " & marker & " & wait' " &
        "</dev/null >/dev/null 2>&1 &"))
      check launch == 0
      check waitFor(proc (): bool = recordedSessions(record).len == 1)
      let sessions = recordedSessions(record)
      require sessions.len == 1
      let pgid = sessions[0]
      check pgid != int(getpgrp())
      check getsid(Pid(pgid)) == Pid(pgid)
      check groupAlive(pgid)
      check stopRecordedSessions(record, graceMs = 0, waitMs = 10_000) == 1
      check not groupAlive(pgid)
      check bystander.running
      # Nothing is signalled twice: the group is gone.
      check stopRecordedSessions(record) == 0

  test "the recorder holds when setsid has to fork (its caller leads a group)":
    if not defined(posix):
      skip("[platform N/A] owned_processes is POSIX-only; it is a " &
        "no-op on Windows")
    elif findExe("setsid").len == 0:
      skip("[missing] no setsid on PATH: nothing could detach " &
        "through one, so there is nothing to record")
    else:
      let dir = createTempDir("repro-owned-setsid-fork-", "")
      defer: removeDir(dir)
      let record = dir / "sessions"
      check installSetsidRecorder(dir / "bin", record, findExe("setsid"))
      let marker = "4" & $(getCurrentProcessId() mod 100_000) & "2"
      # The recorder run by a process-group leader (the real `setsid` makes
      # its child one before exec'ing the shim): util-linux setsid then
      # forks, and the recorded id must still be the NEW session's.
      let leader = startProcess(findExe("setsid"),
        args = [dir / "bin" / "setsid", "sleep", marker], options = {})
      defer: stopFixture(leader)
      check waitFor(proc (): bool = recordedSessions(record).len == 1)
      let sessions = recordedSessions(record)
      require sessions.len == 1
      check getsid(Pid(sessions[0])) == Pid(sessions[0])
      check stopRecordedSessions(record, graceMs = 0, waitMs = 10_000) == 1
      check not groupAlive(sessions[0])
