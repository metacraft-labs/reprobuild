## Gate ``e2e_addon_exclusive_never_overlaps``.
##
## A fixture service records its start and its stop with monotonic
## timestamps (``/proc/uptime``) in a log outside its unit, so two
## instances' lifetimes can be compared after the fact. The service is
## ``exclusive`` (ReproOS Add-On Mode §7.3: a unit two instances of which
## cause harm, a validator client signing with one key). Across:
##
## - a rename (the unit removed under one name and added under another),
## - a change of what it runs (its ``ExecStart`` argument, standing in for
##   a closure change),
## - an adoption under a new unit name (a hand-written unit the profile
##   claims as it is and the previous name removed),
##
## no two instances' lifetimes overlap: every stop is logged before the
## next start. And an old instance that ignores SIGTERM (with
## ``SendSIGKILL=no``, so systemd leaves it alive) makes the apply refuse
## with ``EAddOnExclusiveOverlap``: the successor is never started,
## ``current`` and ``/etc/repro/static`` are unchanged and no pending
## marker is left.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=exclusive-as-plain-restart``):
## the switch treats an exclusive unit like any other -- the successor
## starts before the old instance is stopped -- and the rename produces an
## overlapping pair in the log: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_exclusive_never_overlaps``).
## Bases: ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: real images, systemd and the static add-on binary.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  LogPath = "/var/log/repro-fixture-exclusive.log"
  # Logs `start <id> <uptime>` and, on SIGTERM, `stop <id> <uptime>`.
  Script = """#!/bin/sh
id="$1"
now() { cut -d' ' -f1 /proc/uptime; }
echo "start $id $(now)" >> """ & LogPath & """
trap 'echo "stop $id $(now)" >> """ & LogPath & """; exit 0' TERM
while :; do sleep 0.2; done
"""
  # Ignores SIGTERM; systemd gives up after TimeoutStopSec without a KILL.
  StubbornScript = """#!/bin/sh
id="$1"
now() { cut -d' ' -f1 /proc/uptime; }
echo "start $id $(now)" >> """ & LogPath & """
trap '' TERM
while :; do sleep 0.2; done
"""

proc exclusiveUnit(id: string; script = "/usr/local/bin/repro-fixture-exclusive";
                   extra = ""): string =
  "[Unit]\nDescription=exclusive fixture " & id & "\nX-Repro-Exclusive=true\n\n" &
    "[Service]\nExecStart=" & script & " " & id & "\n" & extra &
    "\n[Install]\nWantedBy=multi-user.target\n"

proc profile(units: openArray[(string, string)]): string =
  for (name, content) in units:
    result.add("systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"" &
      content & "\"\n}\n\n")
  if result.len == 0: result = "addOn {\n  managedEtcPrefixes = []\n}\n"

type Lifetime = object
  id: string
  start, stop: float

proc lifetimes(log: string): seq[Lifetime] =
  ## The instances in log order, with their start and (when logged) stop.
  for line in log.splitLines():
    let f = line.splitWhitespace()
    if f.len != 3: continue
    let t = parseFloat(f[2])
    if f[0] == "start":
      result.add(Lifetime(id: f[1], start: t, stop: -1))
    elif f[0] == "stop":
      for i in countdown(result.high, 0):
        if result[i].id == f[1] and result[i].stop < 0:
          result[i].stop = t
          break

proc overlaps(ls: seq[Lifetime]): seq[string] =
  ## Every pair of instances that were alive at the same moment.
  for i in 0 ..< ls.len:
    for j in i + 1 ..< ls.len:
      let aEnd = if ls[i].stop < 0: 1e18 else: ls[i].stop
      let bEnd = if ls[j].stop < 0: 1e18 else: ls[j].stop
      if ls[i].start < bEnd and ls[j].start < aEnd:
        result.add(ls[i].id & " [" & $ls[i].start & ", " & $ls[i].stop & "] and " &
                   ls[j].id & " [" & $ls[j].start & ", " & $ls[j].stop & "]")

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    writeFile(g.runDir / "fixture.sh", Script)
    writeFile(g.runDir / "stubborn.sh", StubbornScript)
    g.copyTo(g.runDir / "fixture.sh", "/usr/local/bin/repro-fixture-exclusive")
    g.copyTo(g.runDir / "stubborn.sh", "/usr/local/bin/repro-fixture-stubborn")
    discard g.run("chmod 0755 /usr/local/bin/repro-fixture-exclusive " &
      "/usr/local/bin/repro-fixture-stubborn; : > " & LogPath)
    if not g.bootstrapAddon(repro, step): return fails

    proc applied(name: string; p: string) =
      let r = g.applyProfile(repro, name, p)
      step(name & ": applied", r.exitCode == 0, r.stdout & r.stderr)
    proc noOverlap(name: string) =
      let ls = lifetimes(g.run("cat " & LogPath))
      let ov = overlaps(ls)
      step(name & ": no overlapping lifetimes", ov.len == 0,
           (if ov.len > 0: ov.join("\n") else: "") & "\nlog:\n" & g.run("cat " & LogPath))

    # Generation 1: the service under its first name.
    applied("g1-a", profile([("repro-fixture-excl-a.service", exclusiveUnit("a1"))]))
    step("g1: a1 runs", g.run("systemctl is-active repro-fixture-excl-a.service").strip() == "active", "")
    # Generation 2: renamed. The plan lists the stop before the start.
    let p2 = profile([("repro-fixture-excl-b.service", exclusiveUnit("b1"))])
    let plan2 = g.planProfile(repro, "g2-plan", p2)
    step("g2: the plan stops the old name before starting the new",
         plan2.stdout.find("stop\trepro-fixture-excl-a.service") >= 0 and
         plan2.stdout.find("stop\trepro-fixture-excl-a.service") <
           plan2.stdout.find("start\trepro-fixture-excl-b.service"), plan2.stdout)
    applied("g2-rename", p2)
    noOverlap("g2-rename")
    step("g2: only b1 runs",
         g.run("systemctl is-active repro-fixture-excl-b.service").strip() == "active" and
         g.exec("systemctl is-active repro-fixture-excl-a.service").stdout.strip() != "active", "")
    # Generation 3: what it runs changes (its argument; a closure change
    # would change the unit file the same way).
    let p3 = profile([("repro-fixture-excl-b.service", exclusiveUnit("b2"))])
    let plan3 = g.planProfile(repro, "g3-plan", p3)
    step("g3: the plan is a stop-start", "stop-start\trepro-fixture-excl-b.service" in plan3.stdout, plan3.stdout)
    applied("g3-change", p3)
    noOverlap("g3-change")
    step("g3: b2 runs", "b2" in g.run("systemctl show -p ExecStart --value repro-fixture-excl-b.service"), "")
    # Generation 4: adopted under a new name. A hand-written, inactive unit
    # carries the same service; the profile claims it as it is and drops
    # the previous name.
    discard g.putProfile("hand-c", exclusiveUnit("c1"))
    discard g.run("cp /root/addon/hand-c.profile /etc/systemd/system/repro-fixture-excl-c.service && systemctl daemon-reload")
    let p4 = profile([("repro-fixture-excl-c.service", exclusiveUnit("c1"))])
    let plan4 = g.planProfile(repro, "g4-plan", p4)
    step("g4: the plan adopts c and stops b before starting c",
         "adopt\t/etc/systemd/system/repro-fixture-excl-c.service" in plan4.stdout and
         plan4.stdout.find("stop\trepro-fixture-excl-b.service") <
           plan4.stdout.find("start\trepro-fixture-excl-c.service"), plan4.stdout)
    applied("g4-adopt", p4)
    noOverlap("g4-adopt")
    step("g4: c1 runs alone",
         g.run("systemctl is-active repro-fixture-excl-c.service").strip() == "active" and
         g.exec("systemctl is-active repro-fixture-excl-b.service").stdout.strip() != "active", "")
    let ls4 = lifetimes(g.run("cat " & LogPath))
    step("vacuity guard: four instances were logged, three stopped",
         ls4.len == 4 and ls4[0].stop >= 0 and ls4[1].stop >= 0 and
         ls4[2].stop >= 0 and ls4[3].stop < 0, $ls4.len)

    # Generation 5: an instance that ignores SIGTERM and may not be killed.
    let stubborn = exclusiveUnit("d1", "/usr/local/bin/repro-fixture-stubborn",
                                 "TimeoutStopSec=3\nSendSIGKILL=no\n")
    applied("g5-stubborn", profile([("repro-fixture-excl-c.service", exclusiveUnit("c1")),
                                    ("repro-fixture-excl-d.service", stubborn)]))
    let currentBefore = g.run(repro & " system addon status")
    let staticBefore = g.run("readlink /etc/repro/static").strip()
    let pidBefore = g.run("systemctl show -p MainPID --value repro-fixture-excl-d.service").strip()
    # Generation 6: change it; the old instance will not die.
    let changed = exclusiveUnit("d2", "/usr/local/bin/repro-fixture-stubborn",
                                "TimeoutStopSec=3\nSendSIGKILL=no\n")
    let r6 = g.applyProfile(repro, "g6-refused",
      profile([("repro-fixture-excl-c.service", exclusiveUnit("c1")),
               ("repro-fixture-excl-d.service", changed)]))
    step("g6: refused with EAddOnExclusiveOverlap",
         r6.exitCode == 2 and "EAddOnExclusiveOverlap" in r6.stderr and
         "repro-fixture-excl-d.service" in r6.stderr, "exit " & $r6.exitCode & "\n" & r6.stdout & r6.stderr)
    step("g6: the old instance is still the only one (same PID), the successor never started",
         g.run("systemctl show -p MainPID --value repro-fixture-excl-d.service").strip() == pidBefore and
         "d2" notin g.run("cat " & LogPath) and
         "d2" notin g.run("systemctl show -p ExecStart --value repro-fixture-excl-d.service"),
         g.run("cat " & LogPath))
    step("g6: current and the static tree are unchanged, no pending marker",
         g.run(repro & " system addon status") == currentBefore and
         g.run("readlink /etc/repro/static").strip() == staticBefore and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0,
         g.run(repro & " system addon status"))
    # Put the stubborn instance down by force and remove everything.
    discard g.run("systemctl kill -s KILL repro-fixture-excl-d.service; sleep 1; systemctl reset-failed repro-fixture-excl-d.service; true")
    applied("g7-remove", profile([]))
    discard g.run("rm -f /etc/systemd/system/repro-fixture-excl-c.service; systemctl daemon-reload; true")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_exclusive_never_overlaps":
  test "an exclusive service never has two instances alive at once":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_exclusive_never_overlaps)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_exclusive_never_overlaps",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_exclusive_never_overlaps", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
