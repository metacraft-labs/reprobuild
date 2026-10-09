## `exchangeWithNixDaemon` waits for a spawned daemon while it is alive, and
## says why when it never binds.
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
##      and its answer returned.
##
## NO MOCKS of the code under test: the real `exchangeWithNixDaemon` drives
## real processes over a real Unix socket. The "daemons" are tiny stand-ins
## (`sh`, `python3`) because the property is about the client's waiting and
## reporting, not about Nix evaluation -- spawning the real daemon would make
## case 1 impossible to provoke and case 2 depend on host load.

import std/[os, osproc, strutils, tempfiles, times, unittest]
import repro_build_engine

when defined(windows):
  suite "nix daemon spawn wait":
    test "t_nix_daemon_spawn_wait_is_posix_only":
      skip()
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
        skip()
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
