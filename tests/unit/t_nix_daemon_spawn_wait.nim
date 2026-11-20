## `exchangeWithNixDaemon` waits for a spawned daemon while it is alive, says
## why when it never binds, and does not keep the daemon it started as a
## defunct child.
##
## The recipe's C compiler is provisioned through `reprobuild-nix-daemon`; on
## a clean CI runner nothing is listening yet, so the client spawns one and
## polls its socket. That poll used to be a fixed ~2 s whether or not the
## daemon was alive, and the only report was "Failed to connect or spawn
## reprobuild-nix-daemon" -- a daemon still starting on a loaded runner and
## one that had crashed read identically, with nothing in the log to tell
## them apart (reprobuild release run 37906066406, linux leg).
##
## Asserted:
##   1. a daemon that EXITS before binding ends the wait at once (well under
##      the bind ceiling), and the diagnostic carries its exit status and the
##      text it printed;
##   2. a daemon that binds only after the old ~2 s budget is still reached,
##      and its answer returned;
##   3. a daemon this process started, and that answered, is REAPED when it
##      later exits: the client is its parent, and a client that never waits
##      for it keeps a `<defunct>` child for the rest of its own life once
##      the daemon idles out. A user daemon's build worker and a direct
##      `repro build` were both seen holding one for the whole build
##      (reprobuild-pm issue `2026-11-19-a-daemon-hosted-build-blocks-its-
##      client-forever-when-the-workers-nix-child-has-died.md`).
##
## NO MOCKS of the code under test: the real `exchangeWithNixDaemon` drives
## real processes over a real Unix socket. The "daemons" are tiny stand-ins
## (`sh`, `python3`) because the properties are about the client's waiting,
## reporting and reaping, not about Nix evaluation -- spawning the real daemon would make
## case 1 impossible to provoke and case 2 depend on host load.

import std/[os, osproc, strutils, tempfiles, times, unittest]
when defined(posix):
  from std/posix import Pid, kill, signal, SIGCHLD, SIG_DFL
import repro_test_support/reasoned_skip
import repro_build_engine

when defined(windows):
  suite "nix daemon spawn wait":
    test "t_nix_daemon_spawn_wait_is_posix_only":
      skip("POSIX only: both cases drive the client over a Unix-domain " &
        "socket, which is what `exchangeWithNixDaemon` polls")
else:
  suite "nix daemon spawn wait":

    test "t_nix_daemon_that_exits_is_reported_with_its_output":
      let dir = createTempDir("repro-nixd-exit-", "")
      defer: removeDir(dir)
      let socketPath = dir / "d.sock"
      proc spawnDaemon(): Process =
        startProcess("/bin/sh",
          args = ["-c", "echo 'cannot import nixeval' >&2; exit 3"],
          options = {poDaemon, poStdErrToStdOut})
      let started = epochTime()
      let exchange = exchangeWithNixDaemon(socketPath, "{}", spawnDaemon)
      let elapsedMs = int((epochTime() - started) * 1000)
      checkpoint("diagnostic: " & exchange.diagnostic)
      check not exchange.connected
      check "exited with status 3" in exchange.diagnostic
      check "cannot import nixeval" in exchange.diagnostic
      # Stopped because the process ended, not because the ceiling ran out.
      check elapsedMs < NixDaemonBindTimeoutMs div 2

    test "t_nix_daemon_slower_than_two_seconds_is_still_reached":
      let python = findExe("python3")
      if python.len == 0:
        skip("python3 not on PATH; this case needs it to stand in for a " &
          "daemon that binds only after the old ~2 s budget")
      else:
        let dir = createTempDir("repro-nixd-slow-", "")
        defer: removeDir(dir)
        let socketPath = dir / "d.sock"
        let script = "import socket, time\n" &
          "time.sleep(3)\n" &
          "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n" &
          "s.bind(" & socketPath.escape() & ")\n" &
          "s.listen(1)\n" &
          "c, _ = s.accept()\n" &
          "c.recv(65536)\n" &
          "c.sendall(b'answered\\n')\n"
        proc spawnDaemon(): Process =
          startProcess(python, args = ["-c", script],
            options = {poDaemon, poStdErrToStdOut})
        let started = epochTime()
        let exchange = exchangeWithNixDaemon(socketPath, "{}", spawnDaemon)
        let elapsedMs = int((epochTime() - started) * 1000)
        checkpoint("diagnostic: " & exchange.diagnostic)
        check exchange.connected
        check exchange.response == "answered"
        check elapsedMs >= 3000

    test "t_nix_daemon_started_by_this_process_is_reaped_when_it_exits":
      let python = findExe("python3")
      if python.len == 0:
        skip("python3 not on PATH; this case needs it to stand in for a " &
          "daemon that answers one request and then exits")
      else:
        let dir = createTempDir("repro-nixd-reap-", "")
        defer: removeDir(dir)
        let socketPath = dir / "d.sock"
        # Answers one request, stays up a moment longer (so it is certainly
        # still running when the exchange returns), then exits by itself, as
        # the real helper does once it has been idle.
        let script = "import socket, time\n" &
          "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n" &
          "s.bind(" & socketPath.escape() & ")\n" &
          "s.listen(1)\n" &
          "c, _ = s.accept()\n" &
          "c.recv(65536)\n" &
          "c.sendall(b'answered\\n')\n" &
          "c.close()\n" &
          "time.sleep(2)\n"
        # A process that inherits SIGCHLD as ignored has its children reaped
        # by the kernel, and this case would then pass with no reaping in
        # the client at all. The engine's own processes run with the default
        # disposition (the user daemon's build worker sets it), so the case
        # does too, whatever started the suite.
        signal(SIGCHLD, SIG_DFL)
        var daemonPid = 0
        proc spawnDaemon(): Process =
          result = startProcess(python, args = ["-c", script],
            options = {poDaemon, poStdErrToStdOut})
          daemonPid = result.processID
        let exchange = exchangeWithNixDaemon(socketPath, "{}", spawnDaemon)
        checkpoint("diagnostic: " & exchange.diagnostic)
        check exchange.connected
        check exchange.response == "answered"
        require daemonPid > 0
        # An exited child that nobody waited for is a zombie, and a zombie
        # still answers signal 0; only a reaped one is gone. So "the pid no
        # longer exists" within a few seconds of the stand-in's exit is
        # exactly "this process reaped it".
        var gone = false
        let deadline = epochTime() + 15.0
        while epochTime() < deadline:
          if kill(Pid(daemonPid), 0) != 0:
            gone = true
            break
          sleep(50)
        check gone
