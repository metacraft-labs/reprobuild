## The hardening floor after the A9 review's round 13 (ReproOS Add-On Mode
## spec §10.1 and §13 decisions 133, 139 and 141; reprobuild-pm issues
## 2026-11-14-floor-*):
##
## - §13 decision 139: a listener below ``/run/<stem>/`` is refused when a
##   place ANY unit sharing the stem can write covers it -- a template of the
##   stem and its instances, and the profile's drop-ins onto them -- in the
##   parse half; and the places are compared as the kernel resolves them
##   (``/var/run`` is ``/run``, links on the existing prefix followed), not
##   as spelled;
## - §13 decision 141: a directory made again outside a switch is accepted
##   only when it was born no later than the main process's start
##   (``ExecMainStartTimestamp``, read in the same ``systemctl show``) plus
##   ``MainStartToleranceNs``; a tree made later in the run is refused;
## - the revert hold is the add-on's only when it is a regular file holding
##   exactly ``RevertHoldText`` on a unit the generation installs
##   (``addonRevertHolds``, which both the effective check's collection and
##   the passing switch's clearing use);
##
## Falsifying builds, each red here: ``listener-writable-own-unit-only``,
## ``listener-writable-by-spelling``, ``recreated-no-upper-bound``,
## ``revert-hold-any-content``.
##
## *Mocking.* systemd's ``systemctl show`` output is given as text to the
## parser that reads it, and a ``SystemdView`` stands for one read: the rule
## under test is a function of those values, and a VM gate
## (``t_e2e_addon_floor_reapplies_after_restarts``) drives the same rules
## against a real systemd. The hold and ledger cases use real files in a
## temporary directory.

import std/[os, sets, strutils, tables, tempfiles, unittest]

import repro_infra/profile
import repro_infra/errors
import repro_infra/service_floor
import repro_infra/start_holds
import repro_addon/addon_apply
import repro_addon/effective_floor

const
  Start = 1_800_000_000_000_000_000'i64
  Prefix = "/repro/store/prefixes/svc/1.0"

proc unitStanza(name, service: string; install = true): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=x\n\n[Service]\n" & service &
    (if install: "\n[Install]\nWantedBy=multi-user.target\n" else: "\n") & "\"\n" &
    (if install: "" else: "  enabled = false\n") & "}\n"

proc rawUnit(name, content: string): string =
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" &
    content & "\"\n}\n"

proc refusedProfile(text: string): string =
  ## Why the parse half refuses ``text``, or "".
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

suite "§13 decision 139: the places every unit of the stem can write":
  let service = unitStanza("a9s.service", "User=a9e\nExecStart=" & Prefix & "/bin/svc\n")
  let sock = rawUnit("a9s.socket", "[Socket]\nListenStream=/run/a9s/sub/control\n" &
    "Service=a9s.service\nSocketUser=a9e\nSocketMode=0600\nRemoveOnStop=yes\n")
  test "the control: the service alone, nothing writable on the path, applies":
    check refusedProfile(service & sock) == ""
  test "a sibling template that owns /run/<stem> makes the listener refused":
    # The reviewer's profile: a9s@.service shares the stem a9s and declares
    # RuntimeDirectory=a9s, so its account owns /run/a9s.
    let tmpl = unitStanza("a9s@.service", "User=a9e\nRuntimeDirectory=a9s\nExecStart=" &
      Prefix & "/bin/svc\n", install = false)
    let why = refusedProfile(service & tmpl & sock)
    check "/run/a9s/sub/control" in why
    check "unit sharing its stem" in why
  test "so does a drop-in the profile writes onto a base unit of the stem":
    # A floored unit's own drop-in may not add a directory; one onto a base
    # template of the same stem may, and its account then owns /run/a9s.
    let di = "systemd.systemDropIn {\n  unit = \"a9s@.service\"\n  name = \"rt\"\n" &
      "  content = \"[Service]\nRuntimeDirectory=a9s\n\"\n}\n"
    check "/run/a9s/sub/control" in refusedProfile(service & sock & di)
  test "a unit of another stem does not":
    let other = unitStanza("a9t.service", "User=a9e\nRuntimeDirectory=a9t\nExecStart=" &
      Prefix & "/bin/svc\n")
    check refusedProfile(service & other & sock) == ""
  test "/var/run is /run: a place spelled through it covers the listener":
    check canonicalPlace("/var/run/a") == "/run/a"
    check canonicalPlace("/var/run") == "/run"
    check canonicalPlace("/var/runner/a") == "/var/runner/a"
    let why = listenerRefusal("a.socket", "/run/a/sub/control", "a.service",
                              ["/var/run/a"])
    check "/run/a/sub/control" in why
  test "the parse half: ReadWritePaths= spelled through /var/run covers it":
    let svc = unitStanza("a9s.service", "User=a9e\nReadWritePaths=/var/run/a9s\n" &
      "ExecStart=" & Prefix & "/bin/svc\n", install = false)
    let why = refusedProfile(svc & sock)
    check "/run/a9s/sub/control" in why
    check "lies below /run/a9s" in why
  test "a link on the existing prefix is followed on the host":
    let d = createTempDir("a9r13-", "")
    defer: removeDir(d)
    createDir(d / "real")
    createSymlink(d / "real", d / "link")
    check canonicalPlace(d / "link" / "below" / "x", resolveLinks = true) ==
      expandFilename(d / "real") / "below" / "x"
    # Spelled, not resolved: what the parse half compares.
    check canonicalPlace(d / "link" / "x") == d / "link" / "x"
  test "the activated service's own places still count, and shallow listeners pass":
    check listenerRefusal("a.socket", "/run/a/control", "a.service",
                          ["/run/a"]) == ""
    check listenerRefusal("a.socket", "/run/a/sub/control", "a.service",
                          ["/run/a"]).len > 0

suite "§13 decision 141: no later than the main process's start":
  let created = {"/var/lib/a": CreatedDir(unit: "a.service", invocation: "I0")}.toTable
  proc view(btime, mainStart: int64; stopped = false): SystemdView =
    SystemdView(dynamicUid: -1, owner: 1000, btime: btime, invocationId: "I1",
                invocationStart: Start, mainStart: mainStart, stopped: stopped,
                lastStop: (if stopped: Start + 10_000_000_000'i64 else: 0))
  proc verdict(v: SystemdView): string =
    systemdRecreated("/var/lib/a", "a.service", ["/var/lib/a"], created, false, v)
  test "born as systemd sets the run up: accepted":
    check verdict(view(Start + 2_000_000, Start + 1_000_000)) == ""
    check verdict(view(Start + 1_000_000 + MainStartToleranceNs,
                       Start + 1_000_000)) == ""
  test "born three seconds into the run: refused":
    let why = verdict(view(Start + 3_000_000_000'i64, Start + 1_000_000))
    check "after the main process" in why
  test "the same for a stopped unit's last run":
    check "after the main process" in
      verdict(view(Start + 3_000_000_000'i64, Start + 1_000_000, stopped = true))
  test "no main-process start reported: refused":
    check "no start of the main process" in verdict(view(Start + 1, 0))
  test "the start is read in the same systemctl show as the run":
    let r = parseUnitRun("InvocationID=abc\n" &
      "InactiveExitTimestamp=Sat 2026-11-14 10:00:00.100000 UTC\n" &
      "ExecMainStartTimestamp=Sat 2026-11-14 10:00:00.250000 UTC\n" &
      "ActiveState=active\n")
    check r.mainStart - r.start == 150_000_000'i64

suite "the revert hold is recognised by its exact content":
  let d = createTempDir("a9r13h-", "")
  let gen = toHashSet(["a.service", "t@.service"])
  proc put(unit, content: string): string =
    result = d / (unit & ".d") / RevertHoldName
    createDir(parentDir(result))
    writeFile(result, content)
  let own = put("a.service", RevertHoldText)
  let tmpl = put("t@.service", RevertHoldText)
  let planted = put("b.service", RevertHoldText)        # not the generation's
  let other = put("c.service", "[Unit]\nDescription=renamed\n")
  test "only the hold's text on a unit the generation installs":
    let found = addonRevertHolds(gen + toHashSet(["c.service"]), [d])
    check own in found
    check tmpl in found
    check planted notin found
    check other notin found
  test "a link with the hold's name is not one":
    let target = d / "elsewhere"
    writeFile(target, RevertHoldText)
    let l = d / "a.service.d" / RevertHoldName
    removeFile(l)
    createSymlink(target, l)
    check l notin addonRevertHolds(gen, [d])
    removeFile(l)
    writeFile(l, RevertHoldText)
  test "the effective check judges a planted file as foreign":
    # What effectiveFloorCheck adds to the add-on's own drop-ins is exactly
    # this list: a file of that name with other content stays foreign.
    let found = addonRevertHolds(toHashSet(["c.service"]), [d])
    check found.len == 0
  removeDir(d)
