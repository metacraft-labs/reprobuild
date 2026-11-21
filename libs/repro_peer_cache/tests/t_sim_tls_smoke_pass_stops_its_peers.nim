## The peer-cache simulator's TLS smoke pass (``sim.runTlsHandshakeSmokePass``,
## the demonstration driver's ``--tls-enabled=true`` path) settles and
## stops its peers, under every Nim the ``uses:`` range admits: the Nim
## 2.2.4 lane (``scripts/run_nim224_lane.sh``) builds and runs it
## (reprobuild-pm issue 2026-11-08-nim224-lane-reports-green-for-an-
## unknown-suite-and-does-not-hold-the-simulator).
##
## After the pass returns, every peer's server port refuses a connection:
## the pass stopped its peers. (Whether the dispatcher is idle afterwards
## is not checked: the peer-cache client leaves timers behind even when
## stopped, so that check fails with the stops in place.)
##
## Falsifying build: ``sim-skips-stop`` (the pass never stops its peers:
## their ports still accept, red). The build ``sim-stop-in-finally`` puts
## back the round-4 code exactly, with the stops awaited in a ``finally``.
## It is a CONTROL and stays green under Nim 2.2.4 too, because that
## ``finally`` is never left by a ``return``, which Nim 2.2.4's "yielded
## nil" defect needs.

## Mocks: none -- real loopback peers over BearSSL TLS.

import std/[asyncdispatch, net, unittest]

import repro_peer_cache/sim

proc refuses(port: Port): bool =
  ## A TCP connection to ``port`` on loopback is refused.
  let sock = newSocket()
  defer: sock.close()
  try:
    sock.connect("127.0.0.1", port, timeout = 2000)
    false
  except OSError, TimeoutError:
    true

suite "the simulator's TLS smoke pass":
  test "three loopback peers settle, then stop":
    let ports = new(seq[Port])
    check waitFor runTlsHandshakeSmokePass(3, ports)
    check ports[].len == 3
    for p in ports[]:
      checkpoint "port " & $p
      check refuses(p)
