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
## While that instance lives on (its unit ``failed``, its process alive):
##
## - **retrying** the refused apply refuses again: the unit's control
##   group, not its ``ActiveState``, says an instance is running, so the
##   retry is a stop-start, not a plain start beside it;
## - **renaming** it (the failed-but-alive unit removed, a successor added)
##   refuses too: the removed unit is stopped and confirmed, and the
##   successor never starts.
##
## Then four more cases:
##
## - a **delegated** instance (``Delegate=yes``) that moves its process
##   into a child control group and ignores SIGTERM: the unit's top-level
##   ``cgroup.procs`` is empty while the instance lives, and the apply
##   still refuses (``populated`` covers the subtree);
## - **socket activation** between the pre-stop and the start: a socket
##   whose connections queue up while its exclusive service is stopped
##   would start the old definition again in that window; the switch
##   pauses the socket for the stop-start, and the new definition runs;
## - an **unmanaged predecessor** the successor names in ``Conflicts=``:
##   while it runs (or is enabled) the apply refuses and the successor
##   never starts; once the operator stopped and disabled it the apply
##   goes through without overlap.
##
## Falsifying mutations:
##
## - ``REPRO_ADDON_MUTATION=exclusive-as-plain-restart``: the switch treats
##   an exclusive unit like any other -- the successor starts before the
##   old instance is stopped -- and the rename produces an overlapping
##   pair in the log, the retry and the failed-but-alive rename start
##   their successors beside the live instance, and the unmanaged
##   predecessor overlaps its successor: red.
## - ``REPRO_ADDON_MUTATION=exclusive-exited-by-top-level-procs``: "exited"
##   is read from the top-level ``cgroup.procs`` (empty for the delegated
##   instance) and unknowns count as exited: the delegated case starts its
##   successor beside the live instance: red.
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
  # (`@LOG@` is substituted below: a Nim triple-quoted literal swallows a
  # leading newline, so splicing the path with `&` would glue the next line
  # onto the redirect target.)
  # The timestamp is read with the shell's own `read` builtin: a command
  # substitution inside the TERM handler would fork while systemd is
  # signalling the whole control group and can come back empty.
  ScriptTemplate = """#!/bin/sh
id="$1"
read up _ < /proc/uptime
echo "start $id $up" >> @LOG@
trap 'read up _ < /proc/uptime; echo "stop $id $up" >> @LOG@; exit 0' TERM
while :; do sleep 0.2; done
"""
  # Ignores SIGTERM; systemd gives up after TimeoutStopSec without a KILL.
  StubbornTemplate = """#!/bin/sh
id="$1"
read up _ < /proc/uptime
echo "start $id $up" >> @LOG@
trap '' TERM
while :; do sleep 0.2; done
"""
  # Ignores SIGTERM and moves itself into a child control group of its
  # unit's (Delegate=yes), so the unit's own cgroup.procs is empty.
  DelegatedTemplate = """#!/bin/sh
id="$1"
read cg < /proc/self/cgroup
cg="/sys/fs/cgroup${cg#0::}"
mkdir -p "$cg/payload"
echo $$ > "$cg/payload/cgroup.procs"
read up _ < /proc/uptime
echo "start $id $up" >> @LOG@
trap '' TERM
while :; do sleep 0.2; done
"""
  # Takes a second to stop, so an overlap with a successor started
  # beside it is in the log whatever the scheduling.
  SlowStopTemplate = """#!/bin/sh
id="$1"
read up _ < /proc/uptime
echo "start $id $up" >> @LOG@
trap 'sleep 1; read up _ < /proc/uptime; echo "stop $id $up" >> @LOG@; exit 0' TERM
while :; do sleep 0.2; done
"""
  Script = ScriptTemplate.replace("@LOG@", LogPath)
  StubbornScript = StubbornTemplate.replace("@LOG@", LogPath)
  DelegatedScript = DelegatedTemplate.replace("@LOG@", LogPath)
  SlowStopScript = SlowStopTemplate.replace("@LOG@", LogPath)
  SocketUnit = "[Unit]\nDescription=exclusive fixture socket\n\n[Socket]\n" &
    "ListenStream=127.0.0.1:7999\nService=repro-fixture-excl-s.service\n\n" &
    "[Install]\nWantedBy=sockets.target\n"

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
  ## A malformed line is an error, never skipped: a skipped stop would
  ## hide an overlap.
  for line in log.splitLines():
    if line.strip().len == 0: continue
    let f = line.splitWhitespace()
    if f.len != 3:
      raise newException(ValueError, "malformed lifetime log line: " & line)
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
    writeFile(g.runDir / "delegated.sh", DelegatedScript)
    writeFile(g.runDir / "slowstop.sh", SlowStopScript)
    g.copyTo(g.runDir / "fixture.sh", "/usr/local/bin/repro-fixture-exclusive")
    g.copyTo(g.runDir / "stubborn.sh", "/usr/local/bin/repro-fixture-stubborn")
    g.copyTo(g.runDir / "delegated.sh", "/usr/local/bin/repro-fixture-delegated")
    g.copyTo(g.runDir / "slowstop.sh", "/usr/local/bin/repro-fixture-slowstop")
    discard g.run("chmod 0755 /usr/local/bin/repro-fixture-exclusive " &
      "/usr/local/bin/repro-fixture-stubborn /usr/local/bin/repro-fixture-delegated " &
      "/usr/local/bin/repro-fixture-slowstop; : > " & LogPath)
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
    # The stubborn instance is identified by its own process, not by the
    # unit's MainPID: after a stop that timed out under SendSIGKILL=no the
    # unit is `failed` and reports MainPID=0 while the process lives on.
    let pidBefore = g.run("pgrep -f '^/bin/sh /usr/local/bin/repro-fixture-stubborn d1$' | sort").strip()
    # Generation 6: change it; the old instance will not die.
    let changed = exclusiveUnit("d2", "/usr/local/bin/repro-fixture-stubborn",
                                "TimeoutStopSec=3\nSendSIGKILL=no\n")
    let r6 = g.applyProfile(repro, "g6-refused",
      profile([("repro-fixture-excl-c.service", exclusiveUnit("c1")),
               ("repro-fixture-excl-d.service", changed)]))
    step("g6: refused with EAddOnExclusiveOverlap",
         r6.exitCode == 2 and "EAddOnExclusiveOverlap" in r6.stderr and
         "repro-fixture-excl-d.service" in r6.stderr, "exit " & $r6.exitCode & "\n" & r6.stdout & r6.stderr)
    step("g6: the old instance is still the only one (same process), the successor never started",
         pidBefore.len > 0 and
         g.run("pgrep -f '^/bin/sh /usr/local/bin/repro-fixture-stubborn d1$' | sort").strip() == pidBefore and
         g.exec("pgrep -f '^/bin/sh /usr/local/bin/repro-fixture-stubborn d2$'").exitCode != 0 and
         "d2" notin g.run("cat " & LogPath) and
         "d2" notin g.run("systemctl show -p ExecStart --value repro-fixture-excl-d.service"),
         "pids before [" & pidBefore & "] now [" &
         g.run("pgrep -f '^/bin/sh /usr/local/bin/repro-fixture-stubborn' | sort").strip() & "]\n" & g.run("cat " & LogPath))
    step("g6: current and the static tree are unchanged, no pending marker",
         g.run(repro & " system addon status") == currentBefore and
         g.run("readlink /etc/repro/static").strip() == staticBefore and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0,
         g.run(repro & " system addon status"))
    let c1 = ("repro-fixture-excl-c.service", exclusiveUnit("c1"))
    proc instances(pattern: string): string =
      g.exec("pgrep -f " & quoteShell(pattern) & " | sort").stdout.strip()
    # g6b: retry the refused apply while the old instance lives (its unit
    # is `failed`, its process alive).
    let failedState = g.run("systemctl show -p ActiveState --value repro-fixture-excl-d.service").strip()
    step("vacuity guard: after g6 the stubborn unit is failed (or inactive) while its process lives",
         failedState in ["failed", "inactive"] and instances("^/bin/sh /usr/local/bin/repro-fixture-stubborn d1$") == pidBefore,
         failedState)
    let r6b = g.applyProfile(repro, "g6b-retry", profile([c1, ("repro-fixture-excl-d.service", changed)]))
    step("g6b: the retry refuses with EAddOnExclusiveOverlap (the group, not ActiveState, decides)",
         r6b.exitCode == 2 and "EAddOnExclusiveOverlap" in r6b.stderr and
         "repro-fixture-excl-d.service" in r6b.stderr, "exit " & $r6b.exitCode & "\n" & r6b.stdout & r6b.stderr)
    step("g6b: the successor never started, the old instance is the same process",
         instances("^/bin/sh /usr/local/bin/repro-fixture-stubborn d2$").len == 0 and
         "d2" notin g.run("cat " & LogPath) and
         instances("^/bin/sh /usr/local/bin/repro-fixture-stubborn d1$") == pidBefore,
         g.run("cat " & LogPath))
    # g6c: rename the failed-but-alive unit away.
    let r6c = g.applyProfile(repro, "g6c-rename-failed",
      profile([c1, ("repro-fixture-excl-e.service", exclusiveUnit("e1"))]))
    step("g6c: removing the failed-but-alive unit refuses with EAddOnExclusiveOverlap",
         r6c.exitCode == 2 and "EAddOnExclusiveOverlap" in r6c.stderr and
         "repro-fixture-excl-d.service" in r6c.stderr, "exit " & $r6c.exitCode & "\n" & r6c.stdout & r6c.stderr)
    step("g6c: the successor never started",
         " e1 " notin g.run("cat " & LogPath) and
         g.exec("systemctl is-active repro-fixture-excl-e.service").stdout.strip() != "active",
         g.run("cat " & LogPath))
    step("g6c: current and the static tree are unchanged, no pending marker",
         g.run(repro & " system addon status") == currentBefore and
         g.run("readlink /etc/repro/static").strip() == staticBefore and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0,
         g.run(repro & " system addon status"))
    # Put the stubborn instance down by force and start a fresh log: its
    # lifetime never logged a stop, so it would overlap everything after.
    discard g.run("systemctl kill -s KILL repro-fixture-excl-d.service; sleep 1; " &
      "systemctl reset-failed repro-fixture-excl-d.service; true")
    discard g.run("mv " & LogPath & " " & LogPath & ".part1; : > " & LogPath)

    # g8: a delegated instance in a child control group.
    let delegated = proc(id: string): string =
      exclusiveUnit(id, "/usr/local/bin/repro-fixture-delegated",
                    "Delegate=yes\nTimeoutStopSec=3\nSendSIGKILL=no\n")
    applied("g8-delegated", profile([c1, ("repro-fixture-excl-f.service", delegated("f1"))]))
    let topProcs = g.run("cat /sys/fs/cgroup$(systemctl show -p ControlGroup --value repro-fixture-excl-f.service)/cgroup.procs 2>/dev/null; true").strip()
    let fPid = instances("^/bin/sh /usr/local/bin/repro-fixture-delegated f1$")
    step("vacuity guard: f1 runs in a child group, the unit's top-level cgroup.procs is empty",
         fPid.len > 0 and topProcs.len == 0, "pid " & fPid & " top-level procs [" & topProcs & "]")
    let r8b = g.applyProfile(repro, "g8b-delegated-change",
      profile([c1, ("repro-fixture-excl-f.service", delegated("f2"))]))
    step("g8b: refused with EAddOnExclusiveOverlap while the delegated instance lives",
         r8b.exitCode == 2 and "EAddOnExclusiveOverlap" in r8b.stderr and
         "repro-fixture-excl-f.service" in r8b.stderr, "exit " & $r8b.exitCode & "\n" & r8b.stdout & r8b.stderr)
    step("g8b: f2 never started; f1 is the same process",
         "f2" notin g.run("cat " & LogPath) and
         instances("^/bin/sh /usr/local/bin/repro-fixture-delegated f2$").len == 0 and
         instances("^/bin/sh /usr/local/bin/repro-fixture-delegated f1$") == fPid,
         g.run("cat " & LogPath))
    discard g.run("systemctl kill -s KILL repro-fixture-excl-f.service; sleep 1; " &
      "systemctl reset-failed repro-fixture-excl-f.service; true")
    discard g.run("mv " & LogPath & " " & LogPath & ".part2; : > " & LogPath)

    # g9: socket activation between the pre-stop and the start.
    discard g.putProfile("sock", SocketUnit)
    discard g.run("cp /root/addon/sock.profile /etc/systemd/system/repro-fixture-excl-s.socket && " &
      "systemctl daemon-reload")
    applied("g9-socket", profile([c1, ("repro-fixture-excl-s.service", exclusiveUnit("s1"))]))
    # systemd refuses to start a socket whose (Accept=no) service already
    # runs: stop it, start the socket, and start the service again.
    discard g.run("systemctl stop repro-fixture-excl-s.service && " &
      "systemctl start repro-fixture-excl-s.socket && " &
      "systemctl start repro-fixture-excl-s.service")
    step("vacuity guard: the socket is listening and s1 runs",
         g.run("systemctl is-active repro-fixture-excl-s.socket").strip() == "active" and
         g.run("systemctl is-active repro-fixture-excl-s.service").strip() == "active", "")
    # A client that keeps connecting: while the service is stopped, its
    # queued connections would make systemd start it again at once.
    let loopPid = g.run("nohup bash -c 'while :; do (exec 3<>/dev/tcp/127.0.0.1/7999) 2>/dev/null; sleep 0.05; done' " &
      ">/dev/null 2>&1 & echo $!").strip()
    let plan9 = g.planProfile(repro, "g9b-plan", profile([c1, ("repro-fixture-excl-s.service", exclusiveUnit("s2"))]))
    step("g9b: the plan pauses the socket for the stop-start",
         "stop-start\trepro-fixture-excl-s.service" in plan9.stdout and
         "pauses repro-fixture-excl-s.socket" in plan9.stdout, plan9.stdout & plan9.stderr)
    applied("g9b-socket-change", profile([c1, ("repro-fixture-excl-s.service", exclusiveUnit("s2"))]))
    noOverlap("g9b-socket-change")
    step("g9b: the new definition runs (s2), not s1 re-activated in the window",
         "s2" in g.run("systemctl show -p ExecStart --value repro-fixture-excl-s.service") and
         instances("^/bin/sh /usr/local/bin/repro-fixture-exclusive s2$").len > 0 and
         instances("^/bin/sh /usr/local/bin/repro-fixture-exclusive s1$").len == 0 and
         g.run("systemctl is-active repro-fixture-excl-s.socket").strip() == "active",
         g.run("cat " & LogPath))
    # Vacuity guard: the activation the switch guarded against is real --
    # with the client still connecting, a stopped service is started
    # again by its socket within a second.
    discard g.run("systemctl stop repro-fixture-excl-s.service; sleep 1.5; true")
    step("vacuity guard: the socket re-activates its stopped service",
         g.run("systemctl is-active repro-fixture-excl-s.service").strip() == "active" and
         g.run("grep -c '^start s2 ' " & LogPath & "; true").strip() == "2",
         g.run("cat " & LogPath))
    discard g.run("kill " & loopPid & "; true")
    # The socket is the test's scaffolding, not the add-on's: take it away
    # (its queued connections would start the service again whenever it
    # stops, which a later removal of the exclusive service rightly
    # refuses to call "exited").
    discard g.run("systemctl stop repro-fixture-excl-s.socket; " &
      "rm -f /etc/systemd/system/repro-fixture-excl-s.socket; systemctl daemon-reload; true")
    discard g.run("mv " & LogPath & " " & LogPath & ".part3; : > " & LogPath)

    # g10: an unmanaged predecessor named in the successor's Conflicts=.
    discard g.putProfile("old", exclusiveUnit("o1", "/usr/local/bin/repro-fixture-slowstop"))
    discard g.run("cp /root/addon/old.profile /etc/systemd/system/repro-fixture-excl-old.service && " &
      "systemctl daemon-reload && systemctl enable --now repro-fixture-excl-old.service")
    let successor = "[Unit]\nDescription=exclusive fixture n1\nX-Repro-Exclusive=true\n" &
      "Conflicts=repro-fixture-excl-old.service\n\n[Service]\n" &
      "ExecStart=/usr/local/bin/repro-fixture-exclusive n1\n\n[Install]\nWantedBy=multi-user.target\n"
    let p10 = profile([c1, ("repro-fixture-excl-n.service", successor)])
    let r10 = g.applyProfile(repro, "g10-unmanaged-predecessor", p10)
    step("g10: refused with EAddOnExclusiveOverlap while the unmanaged predecessor runs",
         r10.exitCode == 2 and "EAddOnExclusiveOverlap" in r10.stderr and
         "repro-fixture-excl-old.service" in r10.stderr, "exit " & $r10.exitCode & "\n" & r10.stdout & r10.stderr)
    noOverlap("g10-unmanaged-predecessor")
    step("g10: the successor never started",
         " n1 " notin g.run("cat " & LogPath) and
         g.exec("systemctl is-active repro-fixture-excl-n.service").stdout.strip() != "active",
         g.run("cat " & LogPath))
    discard g.run("systemctl disable --now repro-fixture-excl-old.service")
    applied("g10b-after-the-operator-stopped-it", p10)
    noOverlap("g10b-after-the-operator-stopped-it")
    step("g10b: n1 runs, the predecessor does not",
         g.run("systemctl is-active repro-fixture-excl-n.service").strip() == "active" and
         g.exec("systemctl is-active repro-fixture-excl-old.service").stdout.strip() != "active", "")

    applied("g11-remove", profile([]))
    discard g.run("rm -f /etc/systemd/system/repro-fixture-excl-c.service " &
      "/etc/systemd/system/repro-fixture-excl-old.service; systemctl daemon-reload; true")
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
