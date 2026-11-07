## The peer-cache simulator's TLS smoke pass (``sim.runTlsHandshakeSmokePass``,
## the demonstration driver's ``--tls-enabled=true`` path) settles and
## stops its peers, under every Nim the ``uses:`` range admits: the Nim
## 2.2.4 lane (``scripts/run_nim224_lane.sh``) builds and runs it
## (reprobuild-pm issue 2026-11-08-nim224-lane-reports-green-for-an-
## unknown-suite-and-does-not-hold-the-simulator).
##
## No falsifier can be red here, and that is a finding, not a gap. The
## build ``sim-stop-in-finally`` puts back the round-4 code exactly (the
## peers stopped by ``await``s in a ``finally``), and it is GREEN under Nim
## 2.2.4 as well. That ``finally`` is left only by falling off the end or
## by an exception, never by a ``return``, and Nim 2.2.4's "yielded nil"
## defect needs a ``return`` that leaves through a ``finally`` holding a
## ``try: await ... except``. The round-4 change was therefore not a fix
## for 2.2.4. It is kept so that no such ``finally`` is left to gain a
## ``return`` later, and this suite and the build stay in the lane as the
## control that shows it.
##
## Mocks: none -- real loopback peers over BearSSL TLS.

import std/[asyncdispatch, unittest]

import repro_peer_cache/sim

suite "the simulator's TLS smoke pass":
  test "three loopback peers settle, then stop":
    check waitFor runTlsHandshakeSmokePass(3)
    # Stopped: a second pass on fresh peers settles as well.
    check waitFor runTlsHandshakeSmokePass(2)
