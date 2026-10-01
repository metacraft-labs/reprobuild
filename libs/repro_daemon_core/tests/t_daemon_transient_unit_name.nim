## A daemon's transient systemd unit name must identify the ENDPOINT, because
## the unit namespace is per-user global while endpoints are not.
##
## WHAT WENT WRONG. The name was `"repro-daemon-" &
## safePathSegment(config.endpoint.extractFilename, "user") & ".service"` --
## the endpoint's LAST COMPONENT only. Endpoints live in per-run scratch
## directories precisely because the basename is not unique: every one of them
## is some directory's `d.sock`. Six concurrently-running daemons therefore
## wanted the single name `repro-daemon-d.sock.service`. One got it. The other
## five fell back to `launchWithFork` -- `fork()` + `setsid()`, which is not a
## supervised unit at all -- reparented to init, and ran for 11.8 days until
## they were reaped by hand.
##
## WHAT THESE CASES ASSERT, AND WHY THE LAST ONE IS THE REAL ONE. Every case
## reads the name out of `systemdUserRunArgs` -- the exact argv
## `launchWithSystemdUser` executes -- rather than out of the naming proc, so
## each one is a statement about what systemd is actually ASKED for. A naming
## rule the launcher did not pick up would leave them red. They pin: distinct
## endpoints get distinct names; one endpoint gets a stable name, independent
## of everything else in the config (the launching CLI and the later
## `cleanupPlatformBackgroundRegistration` that stops the unit by name share
## only the endpoint); the name stays legal for the longest endpoint an
## AF_UNIX socket can carry; and the basename stays readable in it, because
## the name is also what `systemctl --user list-units` shows.
##
## But "the strings differ" is this repository's claim, not systemd's. The
## final case hands both names to `systemd-run --user` and requires BOTH to
## start, which is the assertion the defect actually violated: with the old
## derivation the second invocation exits non-zero with `Unit
## repro-daemon-d.sock.service was already loaded or has a fragment file`, and
## that non-zero exit is the whole cause of the fallback. It runs only where a
## systemd user manager exists and says why when it does not.
##
## MOCK POLICY: no mocks. The naming is a pure function of the config, so the
## string cases need no filesystem and there is nothing to fake; the systemd
## case uses the REAL user manager, starts real transient units, and stops them
## in a `defer` -- leaving a unit behind is the sin this whole campaign is
## about.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

import repro_daemon_core

proc configFor(endpoint: string): UserDaemonConfig =
  result = defaultUserDaemonConfig(devMode = false)
  result.endpoint = endpoint
  result.stateDir = endpoint.parentDir / "state"

proc unitFor(config: UserDaemonConfig): string =
  ## The unit the LAUNCHER asks systemd for, read back out of the argv it
  ## builds -- never recomputed here.
  ##
  ## Deliberately NOT a call to the naming proc itself. `systemdUserRunArgs`
  ## is the exact command line `launchWithSystemdUser` executes, so every
  ## case below is a statement about what systemd is asked for, and a naming
  ## rule that were fixed without the launcher picking it up would leave
  ## these cases red.
  for arg in systemdUserRunArgs("/nonexistent/repro", config):
    if arg.startsWith("--unit="):
      return arg["--unit=".len .. ^1]
  ""

proc toolPath(name: string): string =
  ## `followSymlinks = false` is load-bearing, and it cost a red run to learn.
  ## Nim's `findExe` resolves the symlink it finds, and on a Nix host
  ## `<coreutils>/bin/sleep` is a symlink to the multi-call `coreutils`
  ## binary: following it yields `.../bin/coreutils`, which systemd then
  ## execs with `argv[0] = coreutils` and which exits 1 immediately. The unit
  ## therefore failed, `--collect` removed it, and the second start found the
  ## name free -- so the case reported two successes under the BROKEN naming
  ## and said nothing about the collision. A multi-call binary dispatches on
  ## `argv[0]`, so the symlink IS the program.
  findExe(name, followSymlinks = false)

proc unitProperty(unit, property: string): string =
  let systemctl = toolPath("systemctl")
  if systemctl.len == 0:
    return "unknown"
  let res = execCmdEx(quoteShellCommand([systemctl, "--user", "show",
    "--property=" & property, unit]))
  if res.exitCode != 0:
    return "unknown"
  res.output.strip().replace(property & "=", "")

proc stopUnit(unit: string) =
  ## Only ever called with a name this file derived from its OWN endpoints,
  ## and only for units this file started.
  let systemctl = toolPath("systemctl")
  if systemctl.len == 0:
    return
  discard execCmdEx(quoteShellCommand([systemctl, "--user", "stop", unit]))
  discard execCmdEx(quoteShellCommand([systemctl, "--user", "reset-failed",
    unit]))

suite "a transient unit name identifies the endpoint, not its basename":
  test "endpoints differing only by their parent directory get different units":
    # The measured collision, minimised. Same basename, different run.
    let a = configFor("/run/user/1000/repro-run-a/d.sock")
    let b = configFor("/run/user/1000/repro-run-b/d.sock")
    checkpoint("a=" & unitFor(a))
    checkpoint("b=" & unitFor(b))
    check unitFor(a) != unitFor(b)

  test "six endpoints that all end in d.sock get six distinct units":
    # The cohort as observed, since two-differ can be satisfied by a rule that
    # still collapses a realistic population.
    var names: seq[string] = @[]
    for i in 0 ..< 6:
      names.add(unitFor(configFor("/tmp/repro-" & $i & "/d.sock")))
    checkpoint(names.join(" "))
    for i in 0 ..< names.len:
      for j in i + 1 ..< names.len:
        check names[i] != names[j]

  test "one endpoint always names one unit":
    # The other half of the requirement, and the half a random or
    # pid-derived name would fail: `startUserDaemon` creates the unit and
    # `cleanupPlatformBackgroundRegistration` stops it by name, in a
    # different process.
    let endpoint = "/run/user/1000/repro-run-a/d.sock"
    check unitFor(configFor(endpoint)) ==
      unitFor(configFor(endpoint))
    # ...and it does not depend on anything else in the config, because the
    # two processes that derive it do not agree on the rest.
    var other = configFor(endpoint)
    other.stateDir = "/somewhere/else"
    other.logPath = "/somewhere/else/log"
    other.devMode = true
    check unitFor(other) == unitFor(configFor(endpoint))

  test "the launcher names a unit at all, and names it once":
    # The premise every other case rests on: `--unit=` is present in the argv
    # exactly once, so `unitFor` is reading the real selector rather than
    # silently returning "" and comparing two empty strings.
    let config = configFor("/run/user/1000/repro-run-a/d.sock")
    var unitArgs = 0
    for arg in systemdUserRunArgs("/nonexistent/repro", config):
      if arg.startsWith("--unit="):
        inc unitArgs
    check unitArgs == 1
    check unitFor(config).len > 0

  test "the name stays a legal systemd unit name for the longest endpoint":
    # `sun_path` is 108 bytes, so that is the worst case a unix endpoint can
    # present. systemd's limit is 255 bytes, and it accepts only
    # `[A-Za-z0-9:_.\-]` before the suffix.
    let longName = "d" & repeat("x", 97) & ".sock"
    let endpoint = "/tmp/" & longName
    check endpoint.len == 108
    let unit = unitFor(configFor(endpoint))
    checkpoint("len=" & $unit.len)
    check unit.len <= 255
    check unit.endsWith(".service")
    for ch in unit:
      check ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', ':', '_', '.', '-'}

  test "the endpoint basename is still readable in the name":
    # The name is a human interface: it is what `systemctl --user list-units`
    # shows and what someone types to stop a daemon. A name that is only a
    # hash tells that reader nothing.
    let unit = unitFor(configFor("/tmp/repro-run-a/build.sock"))
    checkpoint(unit)
    check "build.sock" in unit

  when defined(linux):
    test "systemd itself starts both units for two same-basename endpoints":
      ## THE CASE THAT IS ABOUT THE DEFECT RATHER THAN ABOUT THIS FILE'S
      ## ARITHMETIC. `systemd-run` is what rejected the duplicate name, with a
      ## non-zero exit -- `Failed to start transient service unit: Unit
      ## repro-daemon-d.sock.service was already loaded or has a fragment
      ## file.` -- and that exit is what drove five daemons into the
      ## unsupervised fallback. So both names go to the REAL user manager and
      ## both invocations must succeed.
      ##
      ## Note what makes this case decide anything: `systemd-run` without
      ## `--wait` returns 0 once the job is enqueued, so the exit code alone
      ## does not say a unit is running. Both the exit code AND the manager's
      ## own `ActiveState` are asserted, which is how a unit that started and
      ## instantly died -- freeing its name and hiding the collision -- is
      ## told apart from one that held it.
      let systemdRun = toolPath("systemd-run")
      let systemctl = toolPath("systemctl")
      let sleepExe = toolPath("sleep")
      if systemdRun.len == 0 or systemctl.len == 0 or sleepExe.len == 0:
        skip("no systemd-run/systemctl/sleep on PATH; asking systemd " &
          "whether it accepts two unit names requires a systemd user manager")
        return
      if execCmdEx(quoteShellCommand([systemctl, "--user",
          "is-system-running"])).exitCode notin {0, 1}:
        skip("no reachable systemd --user manager (no user bus in this " &
          "environment), so systemd cannot be asked whether it accepts " &
          "both unit names")
        return
      # Endpoints unique to this process. Under the FIXED naming that makes
      # the unit names unique too; under the broken one they collapse, which
      # is the point.
      let tag = $getCurrentProcessId()
      let first = configFor("/tmp/repro-unit-a-" & tag & "/d.sock")
      let second = configFor("/tmp/repro-unit-b-" & tag & "/d.sock")
      let names = [unitFor(first), unitFor(second)]
      for name in names:
        if unitProperty(name, "LoadState") != "not-found":
          skip("a unit named " & name & " already exists on this host, so " &
            "this case cannot tell a collision it caused from one it " &
            "inherited (which is itself the defect: the name is not unique)")
          return
      defer:
        for name in names:
          stopUnit(name)
      var exitCodes: seq[int] = @[]
      var states: seq[string] = @[]
      for name in names:
        exitCodes.add(execCmdEx(quoteShellCommand([systemdRun, "--user",
          "--unit=" & name, "--collect", "--quiet", sleepExe,
          "30"])).exitCode)
        states.add(unitProperty(name, "ActiveState"))
      checkpoint("units=" & names[0] & "," & names[1] & " exits=" &
        $exitCodes & " states=" & $states)
      check exitCodes == @[0, 0]
      check states == @["active", "active"]
