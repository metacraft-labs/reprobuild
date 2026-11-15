## The hardening floor after the A9 review's round 15 (ReproOS Add-On Mode
## spec §10.1; §13 decision 155, activators held, and decision 156, a
## restart's delay; reprobuild-pm issues
## 2026-11-15-floor-*):
##
## - §13 decision 156: a directory made again after a ``Restart=`` restart
##   is bounded from the run's real start -- ``InactiveExitTimestamp`` plus
##   the restart delay when ``NRestarts`` grew, never later than the main
##   process's start -- read with the rest in one ``systemctl show``;
## - the start step waits, bounded, for a unit's pending directories before
##   it records them (``waitForPendingPaths``; finding 2, ``Type=simple`` on
##   systemd 257);
## - §13 decision 155: the activators of floored services are held like the
##   services (``flooredActivatorNames``).
##
## Falsifying builds, red here: ``recreated-bound-from-inactive-exit-only``
## and ``record-without-waiting`` (the record is taken before the
## directory exists). ``activators-unheld`` and
## ``revert-held-left-running`` act at their call sites in the switch and
## are red in the VM gate ``t_e2e_addon_floor_reapplies_after_restarts``.
##
## *Mocking.* A ``SystemdView`` and ``systemctl show`` text stand for
## systemd's report, and ``waitForPendingPaths`` is given stand-ins for the
## file system and the unit's state: the rules are functions of those
## values, and the VM gate drives them against systemd 252 and 257.

import std/[sets, strutils, tables, unittest]

import repro_addon/addon_apply
import repro_addon/effective_floor

const
  Start = 1_800_000_000_000_000_000'i64
  S = 1_000_000_000'i64
  Prefix = "/repro/store/prefixes/svc/1.0"

suite "§13 decision 156: a restart's run begins its delay after InactiveExitTimestamp":
  test "systemd's time spans are read":
    check parseTimespanNs("0") == 0
    check parseTimespanNs("3s") == 3 * S
    check parseTimespanNs("100ms") == 100_000_000
    check parseTimespanNs("1min 30s") == 90 * S
    check parseTimespanNs("infinity") == -1
  test "NRestarts and the delay come from the same systemctl show":
    let r = parseUnitRun("InvocationID=x\nNRestarts=2\nRestartUSec=3s\n" &
      "InactiveExitTimestamp=Sun 2026-11-15 01:26:34.663524 UTC\nActiveState=active\n")
    check r.nRestarts == 2
    check r.restartDelay == 3 * S
    let n = parseUnitRun("RestartUSec=3s\nRestartUSecNext=5s\n")
    check n.restartDelay == 5 * S
  let created = {"/run/u": CreatedDir(unit: "u.service", invocation: "I0")}.toTable
  proc verdict(btime, mainStart: int64; restarts: int; delay: int64): string =
    systemdRecreated("/run/u", "u.service", ["/run/u"], created, false,
      SystemdView(dynamicUid: -1, owner: 1000, btime: btime, invocationId: "I1",
                  invocationStart: Start, mainStart: mainStart,
                  nRestarts: restarts, restartDelay: delay))
  test "systemd 257: born RestartSec= after InactiveExitTimestamp, accepted":
    # The reviewer's a9u: RestartSec=3, born 3.257 s after the stamp.
    check verdict(Start + 3_257_000_000'i64, Start + 3_232_000_000'i64, 1, 3 * S) == ""
  test "without a restart the same birth is refused":
    check verdict(Start + 3_257_000_000'i64 + RunStartToleranceNs,
                  Start + 3_232_000_000'i64, 0, 3 * S).len > 0
  test "systemd 252 stamps the new run itself: the delay does not widen the bound":
    # Main process at the stamp, so the run start stays at the stamp.
    check runStartOf(SystemdView(invocationStart: Start, mainStart: Start,
                                 nRestarts: 1, restartDelay: 3 * S)) == Start
    check verdict(Start + RunStartToleranceNs + 2 * S, Start, 1, 3 * S).len > 0
  test "a tree made well into a restarted run is refused":
    check verdict(Start + 3 * S + RunStartToleranceNs + 1 * S,
                  Start + 3 * S, 1, 3 * S).len > 0

suite "the start step waits for a unit's directories before it records them":
  test "it returns once every pending path of the unit exists":
    var calls = 0
    waitForPendingPaths("a.service", [("/run/a", "a.service"), ("/run/b", "b.service")],
      timeoutMs = 5000,
      exists = proc (p: string): bool =
        inc calls
        calls > 3,
      stillStarting = proc (u: string): bool = true)
    check calls >= 4
  test "it stops waiting when the unit no longer runs, or at the bound":
    var calls = 0
    waitForPendingPaths("a.service", [("/run/a", "a.service")], timeoutMs = 5000,
      exists = proc (p: string): bool = (inc calls; false),
      stillStarting = proc (u: string): bool = false)
    check calls == 1
    waitForPendingPaths("a.service", [("/run/a", "a.service")], timeoutMs = 120,
      exists = proc (p: string): bool = false,
      stillStarting = proc (u: string): bool = true)
  test "the start step records a unit's directories only once they exist":
    # The directory appears on the fourth look, as a Type=simple unit's
    # does once systemd-executor has made it; the record must see it.
    var looks = 0
    var seenAtRecord = false
    let exists = proc (p: string): bool =
      inc looks
      looks > 3
    recordAfterStart("a.service", [("/run/a", "a.service")],
      record = proc (u: string) = seenAtRecord = exists("/run/a"),
      wait = proc (u: string) =
        waitForPendingPaths(u, [("/run/a", "a.service")], timeoutMs = 5000,
          exists = exists, stillStarting = proc (v: string): bool = true))
    check seenAtRecord
  test "nothing to wait for when no path is pending for the unit":
    var calls = 0
    waitForPendingPaths("a.service", [("/run/b", "b.service")], timeoutMs = 5000,
      exists = proc (p: string): bool = (inc calls; false))
    check calls == 0

suite "§13 decision 155: the activators of floored services are held":
  test "a socket of a floored service is held; a socket of none is not":
    let p = parseAddOnUserProfile(
      "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"[Unit]\nDescription=x\n\n" &
      "[Service]\nUser=a\nExecStart=" & Prefix & "/bin/svc\n\"\n  enabled = false\n}\n" &
      "systemd.systemUnit {\n  name = \"a.socket\"\n  content = \"[Socket]\nListenStream=/run/a/control\n" &
      "Service=a.service\n\n[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n" &
      "systemd.systemUnit {\n  name = \"b.timer\"\n  content = \"[Timer]\nOnCalendar=daily\n" &
      "Unit=b-none.service\n\n[Install]\nWantedBy=timers.target\n\"\n  enabled = true\n}\n")
    let acts = flooredActivatorNames(p.resources)
    check "a.socket" in acts
    check "b.timer" notin acts
  test "a timer declared as a systemd.systemTimer is held like one declared as a unit":
    let p = parseAddOnUserProfile(
      "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"[Unit]\nDescription=x\n\n" &
      "[Service]\nUser=a\nExecStart=" & Prefix & "/bin/svc\n\"\n  enabled = false\n}\n" &
      "systemd.systemTimer {\n  name = \"a.timer\"\n  content = \"[Timer]\nOnCalendar=daily\n" &
      "Unit=a.service\n\"\n}\n")
    check "a.timer" in flooredActivatorNames(p.resources)
    check activatorsOf(p.resources, ["a.service"]) == @["a.timer"]
  test "a revert that holds a service holds its activators with it":
    let p = parseAddOnUserProfile(
      "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"[Unit]\nDescription=x\n\n" &
      "[Service]\nUser=a\nExecStart=" & Prefix & "/bin/svc\n\"\n  enabled = false\n}\n" &
      "systemd.systemUnit {\n  name = \"a.socket\"\n  content = \"[Socket]\nListenStream=/run/a/control\n" &
      "Service=a.service\n\n[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n" &
      "systemd.systemUnit {\n  name = \"t@.service\"\n  content = \"[Unit]\nDescription=x\n\n" &
      "[Service]\nUser=a\nExecStart=" & Prefix & "/bin/svc\n\"\n  enabled = false\n}\n" &
      "systemd.systemUnit {\n  name = \"t@daily.timer\"\n  content = \"[Timer]\nOnCalendar=daily\n" &
      "\n[Install]\nWantedBy=timers.target\n\"\n  enabled = true\n}\n" &
      "systemd.systemUnit {\n  name = \"b.timer\"\n  content = \"[Timer]\nOnCalendar=daily\n" &
      "Unit=b-none.service\n\n[Install]\nWantedBy=timers.target\n\"\n  enabled = true\n}\n")
    check activatorsOf(p.resources, ["a.service"]) == @["a.socket"]
    check activatorsOf(p.resources, ["t@.service"]) == @["t@daily.timer"]
    check activatorsOf(p.resources, ["a.service", "a.socket"]).len == 0
    check activatorsOf(p.resources, ["c.service"]).len == 0
