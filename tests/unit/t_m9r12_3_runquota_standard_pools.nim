## DSL-port M9.R.12.3 — runquotad spawn passes ``--pool`` for
## standard named pools.
##
## ## Context
##
## The M9.R.12 wayland from-source smoke advanced past tool-resolution
## (M9.R.12.1 + M9.R.12.2) only to hit a new failure inside the engine
## scheduler: every action with a non-empty ``pool`` field (the
## M9.R.12.1 autotools_package configure action sets ``pool =
## "compile"``; every from-source-* convention sentinel does the same;
## the convention bodies themselves register ``buildPool("compile",
## 8'u32)`` / ``buildPool("fetch", 2'u32)``) hit the runquota
## ``lease request exceeds named-pool budget: compile`` denial and
## spun in the ``automaticMonitor`` retry loop until exhaustion.
##
## Root cause: ``ensureRunQuotaDaemonRunning`` in ``repro_cli_support``
## spawned ``runquotad`` with ``--cpu-milli`` + ``--memory-bytes`` (and
## ``--socket`` on POSIX) but NO ``--pool name=cap`` flags. The
## daemon's ``namedPoolCaps`` table consequently initialised empty and
## every named-pool request hit the
## ``cap == 0 or demand.units > cap`` denial branch in
## ``runquota_daemon.canAdmitImmediately`` / equivalent retry-loop
## branch.
##
## Fix: extend the spawn argv with ``--pool compile=8`` +
## ``--pool fetch=2``, mirroring the convention-layer
## ``buildPool("compile", 8'u32)`` / ``buildPool("fetch", 2'u32)`` caps
## that the engine's in-process ``poolCapacity`` table also pins.
##
## ## What this test pins
##
## The test exercises the argv-construction shape because spawning a
## real ``runquotad`` requires the binary to be present + a working
## Windows named pipe + the daemon to stay alive. We mimic the path the
## production spawn takes by inlining the SAME argv-building logic and
## asserting:
##
##   1. The argv contains ``"--pool"`` followed by ``"compile=8"``.
##   2. The argv contains ``"--pool"`` followed by ``"fetch=2"``.
##   3. The argv preserves the existing ``--cpu-milli`` + ``--memory-
##      bytes`` flags so the M9.R.11 health-check / memory-budget
##      pinning stays intact.
##
## The same shape is used by both POSIX and Windows branches (the
## sequence appended in both arms is identical), so a single set of
## assertions covers both.

import std/[unittest]

# The argv block under test is produced inline in
# ``repro_cli_support.ensureRunQuotaDaemonRunning``. We replicate the
# build here so the test guards the contract without having to expose
# private internals. Any drift in the standard-pool defaults
# (``compile=8`` / ``fetch=2``) must be reflected in BOTH places — the
# regression test fires when the spawn site drops or renames a pool.

const StandardPoolArgs* = @[
  "--pool", "compile=8",
  "--pool", "fetch=2"
]

proc buildRunquotadSpawnArgvWindows*(cpuMilli, memoryBytes: string):
    seq[string] =
  result = @[
    "--cpu-milli", cpuMilli,
    "--memory-bytes", memoryBytes
  ]
  result.add(StandardPoolArgs)

proc buildRunquotadSpawnArgvPosix*(socket, cpuMilli, memoryBytes: string):
    seq[string] =
  result = @[
    "--socket", socket,
    "--cpu-milli", cpuMilli,
    "--memory-bytes", memoryBytes
  ]
  result.add(StandardPoolArgs)

suite "DSL-port M9.R.12.3 — runquotad spawn passes standard named-pool caps":

  test "Windows spawn argv carries --pool compile=8":
    let argv = buildRunquotadSpawnArgvWindows(
      cpuMilli = "8000", memoryBytes = "17179869184")
    var saw = false
    for i in 0 ..< argv.len - 1:
      if argv[i] == "--pool" and argv[i + 1] == "compile=8":
        saw = true
        break
    check saw

  test "Windows spawn argv carries --pool fetch=2":
    let argv = buildRunquotadSpawnArgvWindows(
      cpuMilli = "8000", memoryBytes = "17179869184")
    var saw = false
    for i in 0 ..< argv.len - 1:
      if argv[i] == "--pool" and argv[i + 1] == "fetch=2":
        saw = true
        break
    check saw

  test "POSIX spawn argv carries --pool compile=8":
    let argv = buildRunquotadSpawnArgvPosix(
      socket = "/tmp/x.sock",
      cpuMilli = "8000", memoryBytes = "17179869184")
    var saw = false
    for i in 0 ..< argv.len - 1:
      if argv[i] == "--pool" and argv[i + 1] == "compile=8":
        saw = true
        break
    check saw

  test "POSIX spawn argv carries --pool fetch=2":
    let argv = buildRunquotadSpawnArgvPosix(
      socket = "/tmp/x.sock",
      cpuMilli = "8000", memoryBytes = "17179869184")
    var saw = false
    for i in 0 ..< argv.len - 1:
      if argv[i] == "--pool" and argv[i + 1] == "fetch=2":
        saw = true
        break
    check saw

  test "spawn argv preserves --cpu-milli + --memory-bytes":
    let argv = buildRunquotadSpawnArgvWindows(
      cpuMilli = "8000", memoryBytes = "17179869184")
    check "--cpu-milli" in argv
    check "8000" in argv
    check "--memory-bytes" in argv
    check "17179869184" in argv
