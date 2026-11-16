## The hardening floor after the A9 review's round 16 (ReproOS Add-On Mode
## spec §10.1; §13 decision 163; the reviewer's probes
## ``probe16/p_activator_nodefdeps.nim`` and ``p_restart_window.nim``):
##
## - §13 decision 163: an activator of a floored service must be ordered
##   after ``sysinit.target`` and never before a unit the boot-hold unit
##   runs before, or at boot it starts before a pending switch's holds are
##   back. Refused at parse time (the profile's files) and in the effective
##   half (what systemd reports).
##
## - A9 review round 16, finding 5: what a revert stopped because it held
##   it is recorded, and the switch whose check passes starts exactly that
##   again, whatever kind of unit it is.
##
## - §13 decision 157: a switch to a generation with a health-checked
##   floored unit is confirmed by ``repro-addon-boot-confirm.service``,
##   ordered after the re-assertion (``needsBootConfirm``, the unit).
##
## Falsifying builds, red here: ``revert-stopped-not-restarted``,
## ``activator-boot-order-parse-unchecked``
## (the parse half), ``activator-boot-order-effective-unchecked`` (the
## effective half), ``activator-boot-order-unchecked`` (both).
##
## *Mocking.* The effective half is given ``systemctl show`` text: the rule
## is a function of the ``After=`` and ``Before=`` systemd reports, and the
## effective-unit VM gate drives it against systemd 252 and 257.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_infra/errors
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/generation0

const Prefix = "/repro/store/prefixes/svc/1.0"

let svc = "systemd.systemUnit {\n  name = \"a9q.service\"\n  content = \"[Unit]\n" &
  "Description=x\n\n[Service]\nUser=a\nExecStart=" & Prefix &
  "/bin/svc\n\"\n  enabled = false\n}\n"

proc sock(unitExtra: string; dropIn = ""): string =
  svc & "systemd.systemUnit {\n  name = \"a9q.socket\"\n  content = \"[Unit]\n" &
    unitExtra & "\n[Socket]\nListenStream=/run/a9q\nService=a9q.service\n\n" &
    "[Install]\nWantedBy=sockets.target\n\"\n  enabled = true\n}\n" &
    (if dropIn.len > 0:
       "systemd.systemDropIn {\n  unit = \"a9q.socket\"\n  name = \"10-x\"\n" &
       "  content = \"[Unit]\n" & dropIn & "\"\n}\n"
     else: "")

proc refused(text: string): string =
  try:
    discard parseAddOnUserProfile(text)
  except ESystemProfileInvalid as e:
    return e.msg
  ""

suite "§13 decision 163, the parse half: an activator ordered after sysinit.target":
  test "the reviewer's three sockets are refused":
    for extra in ["DefaultDependencies=no\n",
                  "DefaultDependencies=no\nBefore=sysinit.target\n",
                  "DefaultDependencies=no\nAfter=local-fs-pre.target\n"]:
      let m = refused(sock(extra))
      checkpoint extra & " -> " & m
      check "a9q.socket" in m
      check "pending switch's holds" in m
  test "before the boot-hold unit, with default dependencies, is refused":
    check "repro-addon-boot-hold.service" in
      refused(sock("Before=repro-addon-boot-hold.service\n"))
  test "a drop-in may not set DefaultDependencies= at all (the allowlist)":
    check "DefaultDependencies=no" in refused(sock("", dropIn = "DefaultDependencies=no\n"))
  test "default dependencies, or an explicit After=sysinit.target, pass":
    check refused(sock("")) == ""
    check refused(sock("DefaultDependencies=no\nAfter=sysinit.target\n")) == ""
    check refused(sock("DefaultDependencies=no\nAfter=basic.target\n")) == ""

suite "§13 decision 163, the effective half: what systemd reports":
  let base = "FragmentPath=/etc/systemd/system/a9q.socket\nTriggers=a9q.service\n"
  proc probs(extra: string): string =
    activatorProblems("a9q.socket", parseShow(base & extra),
      parseShowLines("Listen=/run/a9q (Stream)\n"),
      "/etc/systemd/system/a9q.socket", []).join("\n")
  test "no sysinit.target in its After= is refused":
    let m = probs("After=-.mount system.slice\nBefore=sockets.target\n")
    checkpoint m
    check "[rule:boot-order" in m
  test "before the boot-hold unit or sysinit.target is refused":
    check "[rule:boot-order" in probs("After=sysinit.target\nBefore=sysinit.target\n")
    check "[rule:boot-order" in
      probs("After=sysinit.target\nBefore=repro-addon-boot-hold.service\n")
  test "the default dependencies' order passes":
    check "[rule:boot-order" notin
      probs("After=sysinit.target -.mount system.slice\nBefore=sockets.target shutdown.target\n")

suite "A9 review round 16, finding 5: what a revert stopped comes back":
  test "the record round-trips and is removed when empty":
    let d = createTempDir("a9r16-", "-stopped")
    defer: removeDir(d)
    writeRevertStopped(d, ["a.timer", "a.socket", "a.timer"])
    check readRevertStopped(d) == @["a.timer", "a.socket"]
    writeRevertStopped(d, [])
    check readRevertStopped(d).len == 0
  test "exactly the recorded units still installed, not planned, not running":
    let gen = toHashSet(["a.timer", "a.socket", "b.service"])
    let up = revertStoppedToStart(["a.timer", "a.socket", "gone.timer", "b.service"],
      gen, ["b.service"], proc (u: string): bool = u == "a.socket")
    check up == @["a.timer"]

suite "§13 decision 157: the boot-confirm unit":
  const Exe = "/repro/store/prefixes/repro-addon-bin/x/bin/repro"
  let u = bootConfirmUnit(Exe)
  test "after the re-assertion, only while a switch is pending, never on the base's boot path":
    check ("After=local-fs.target repro-store.mount " & ReassertUnit & "\n") in u
    check ("ConditionPathExists=" & PendingMarkerPath & "\n") in u
    check "WantedBy=repro-addon.target\n" in u
    check "multi-user.target" notin u
    check " system addon boot-confirm;" in u
  test "generation 0 carries it on the re-assert unit's engine":
    var found = false
    for o in generation0Objects(Gen0Inputs(reproExe: Exe)):
      if o.kind == ookUnit and o.unit == BootConfirmUnit:
        found = true
        check o.content == u
        check o.enabled
    check found
  test "a switch needs it only for a health-checked floored unit":
    let floored = "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"[Unit]\n" &
      "Description=x\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nUser=a\n" &
      "ExecStart=" & Prefix & "/bin/svc\n\n[Install]\nWantedBy=multi-user.target\n\"\n"
    check needsBootConfirm(floored & "  healthCheck = \"active\"\n}\n")
    check not needsBootConfirm(floored & "}\n")
    check not needsBootConfirm(floored & "  healthCheck = \"active\"\n" &
      "  floorExceptions = [\"serviceFloor: a fixture\"]\n}\n")
    check not needsBootConfirm("not a profile {")
