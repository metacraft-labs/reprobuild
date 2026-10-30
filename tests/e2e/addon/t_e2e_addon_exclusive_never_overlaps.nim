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
## Then more cases:
##
## - a **delegated** instance (``Delegate=yes``) that moves its process
##   into a child control group and ignores SIGTERM: the unit's top-level
##   ``cgroup.procs`` is empty while the instance lives, and the apply
##   still refuses (``populated`` covers the subtree);
## - **socket activation** between the pre-stop and the start: a socket
##   whose connections queue up while its exclusive service is stopped
##   would start the old definition again in that window; the switch
##   pauses the socket for the stop-start, and the new definition runs;
## - removing that service while the socket (not the add-on's) is still
##   active: the socket starts it again after every stop, so the stop is
##   never confirmed and the apply refuses before the flip, naming the
##   socket, with the fingerprint unchanged;
## - an exclusive unit ``PartOf=`` a unit that changes: systemd carries
##   the restart to it, so the plan does too, as a confirmed stop-start
##   after its anchor -- a SIGTERM-ignoring instance refuses the apply
##   before the flip, a cooperative one is stopped and started again;
## - a static predecessor behind an enabled socket refuses the successor,
##   naming the socket, with the fingerprint unchanged;
## - an **unmanaged predecessor** the successor names in ``Conflicts=``:
##   while it runs (or is enabled) the apply refuses and the successor
##   never starts; once the operator stopped and disabled it the apply
##   goes through without overlap.
##
## More cases: a socket-activated unit that idles out between the plan
## and step 2 (the switch paused at the seam after realise): its socket is
## listening again after the switch; an exclusive unit that ``Requires=``
## the anchor, under ``KillMode=process`` with a SIGTERM-ignoring worker,
## refuses the anchor's change; ``PropagatesStopTo=`` stops its dependent.
## The gate runs on the seam build (pause points compiled in, inert unless
## a control file asks; ``scripts/run_addon_gate.sh``).
##
## Falsifying mutations -- every case is red under one of them and green
## without (each in its own run, so a mutation red early does not hide a
## later case; the measurement record maps cases to mutations):
##
## - ``exclusive-as-plain-restart``: the successor starts before the old
##   instance stops -- the rename, change and adoption overlap (g2-g4) and
##   the stubborn instance is not refused (g6): red.
## - ``exclusive-planned-by-active-state``: exclusive units planned by
##   ``ActiveState`` alone, no group confirmed before a start -- the retry
##   and the failed-but-alive rename start a successor (g6b, g6c): red.
## - ``exclusive-exited-by-top-level-procs``: "exited" read from the
##   top-level ``cgroup.procs`` -- the delegated instance (g8b): red.
## - ``trigger-not-paused``: the socket re-activates the old definition
##   during the stop-start, which is then refused (g9b): red.
## - ``idle-unit-triggers-left-paused``: the idle unit's socket stays
##   stopped after the switch (g9d): red.
## - ``removed-exclusive-stop-unconfirmed``: a removed exclusive unit is
##   stopped without confirmation -- the failed-but-alive rename and the
##   removal an unmanaged socket keeps alive go through (g6c, g9c): red.
## - ``unmanaged-predecessor-not-refused``: the unmanaged predecessor (g10)
##   and the static one behind an enabled socket (g13) do not refuse: red.
## - ``partof-not-propagated``: the plan leaves what systemd carries along
##   ``PartOf=``, ``Requires=`` and ``PropagatesStopTo=`` implicit (g12b,
##   g14b, g15b): red.
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
  # A main process that stops on SIGTERM and a worker child that ignores
  # it: under KillMode=process systemd signals only the main process, so
  # the worker outlives the unit's stop in its control group.
  WithChildTemplate = """#!/bin/sh
id="$1"
read up _ < /proc/uptime
echo "start $id $up" >> @LOG@
( trap '' TERM; read up _ < /proc/uptime; echo "start $id-worker $up" >> @LOG@; while :; do sleep 0.2; done ) &
trap 'read up _ < /proc/uptime; echo "stop $id $up" >> @LOG@; exit 0' TERM
while :; do sleep 0.2; done
"""
  WithChildScript = WithChildTemplate.replace("@LOG@", LogPath)
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
    writeFile(g.runDir / "withchild.sh", WithChildScript)
    g.copyTo(g.runDir / "withchild.sh", "/usr/local/bin/repro-fixture-withchild")
    g.copyTo(g.runDir / "fixture.sh", "/usr/local/bin/repro-fixture-exclusive")
    g.copyTo(g.runDir / "stubborn.sh", "/usr/local/bin/repro-fixture-stubborn")
    g.copyTo(g.runDir / "delegated.sh", "/usr/local/bin/repro-fixture-delegated")
    g.copyTo(g.runDir / "slowstop.sh", "/usr/local/bin/repro-fixture-slowstop")
    discard g.run("chmod 0755 /usr/local/bin/repro-fixture-exclusive " &
      "/usr/local/bin/repro-fixture-stubborn /usr/local/bin/repro-fixture-delegated " &
      "/usr/local/bin/repro-fixture-slowstop /usr/local/bin/repro-fixture-withchild; : > " & LogPath)
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
    proc forceDown(unit: string) =
      ## Put a unit down by force and wait until nothing of it is left:
      ## no process in its control group (any child group included), no
      ## pending job, not active. A falsifying mutation can leave systemd
      ## a propagated restart still queued behind a stop that timed out;
      ## killing once would race it, and the next case would start on a
      ## live instance.
      discard g.run("for i in $(seq 1 30); do systemctl kill -s KILL " & unit &
        " 2>/dev/null; sleep 1; systemctl reset-failed " & unit & " 2>/dev/null; " &
        "cg=$(systemctl show -p ControlGroup --value " & unit & "); " &
        "st=$(systemctl show -p ActiveState --value " & unit & "); " &
        "jobs=$(systemctl list-jobs --no-legend " & unit & " 2>/dev/null | wc -l); " &
        "if [ \"$st\" != active ] && [ \"$st\" != activating ] && [ \"$st\" != deactivating ] && " &
        "[ \"$jobs\" = 0 ] && { [ -z \"$cg\" ] || [ ! -e /sys/fs/cgroup$cg ] || " &
        "grep -q 'populated 0' /sys/fs/cgroup$cg/cgroup.events; }; then break; fi; " &
        "done; true", timeoutSec = 120)
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
    forceDown("repro-fixture-excl-d.service")
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
    forceDown("repro-fixture-excl-f.service")
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
    # g9c: removing the exclusive service while a socket the add-on does
    # not own keeps activating it: the stop cannot be confirmed (the
    # socket starts it again), and the add-on does not stop a trigger it
    # does not own, so the apply refuses before the flip, naming the
    # socket, and writes nothing.
    let fb = g.takeFingerprint(repro)
    let r9c = g.applyProfile(repro, "g9c-remove-with-unmanaged-socket", profile([c1]))
    step("g9c: removing a unit an unmanaged active socket re-activates refuses, naming the socket",
         r9c.exitCode == 2 and "EAddOnExclusiveOverlap" in r9c.stderr and
         "repro-fixture-excl-s.service" in r9c.stderr and
         "repro-fixture-excl-s.socket" in r9c.stderr,
         "exit " & $r9c.exitCode & "\n" & r9c.stdout & r9c.stderr)
    let ib = identityReport(fb, g.takeFingerprint(repro))
    step("g9c: the refused removal wrote nothing (fingerprint unchanged)", ib.ok, ib.text)
    step("g9c: the unit file is still there and the service still runs from the socket",
         g.exec("test -f /etc/systemd/system/repro-fixture-excl-s.service").exitCode == 0 and
         g.run("systemctl is-active repro-fixture-excl-s.service").strip() == "active" and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0, "")
    discard g.run("kill " & loopPid & "; true")
    # g9d: the stop-start unit idles out between the plan and step 2 (the
    # switch is paused after realise and the service stopped; its socket
    # stays listening). Step 2 pauses the socket, finds the unit not
    # running and step 7 does not start it -- and the socket must still be
    # listening afterwards.
    # Fresh socket (no queued connections), then the service running, as
    # the plan must see it.
    discard g.run("systemctl stop repro-fixture-excl-s.socket; " &
      "systemctl stop repro-fixture-excl-s.service; systemctl start repro-fixture-excl-s.socket; " &
      "systemctl start repro-fixture-excl-s.service")
    let p9d = profile([c1, ("repro-fixture-excl-s.service", exclusiveUnit("s3"))])
    let paused9d = g.startSwitchPausedAt(repro, "g9d-idle", p9d, "step-1")
    step("g9d: the switch paused after realise", paused9d.exitCode == 0,
         paused9d.stdout & paused9d.stderr)
    discard g.run("systemctl stop repro-fixture-excl-s.service; true")
    step("vacuity guard: the service idled out, its socket listens",
         g.exec("systemctl is-active repro-fixture-excl-s.service").stdout.strip() != "active" and
         g.run("systemctl is-active repro-fixture-excl-s.socket").strip() == "active", "")
    let r9d = g.resumeSwitch()
    step("g9d: the switch completes, having planned a stop-start that pauses the socket",
         r9d.exitCode == 0 and "stop-start\trepro-fixture-excl-s.service" in r9d.stdout and
         "pauses repro-fixture-excl-s.socket" in r9d.stdout, r9d.stdout & r9d.stderr)
    step("g9d: the socket step 2 paused is listening again, the idle unit not started",
         g.run("systemctl is-active repro-fixture-excl-s.socket").strip() == "active" and
         g.exec("systemctl is-active repro-fixture-excl-s.service").stdout.strip() != "active",
         g.run("systemctl status --no-pager repro-fixture-excl-s.socket; true"))
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

    discard g.run("mv " & LogPath & " " & LogPath & ".part4; : > " & LogPath)

    # g12: an exclusive unit that is PartOf= another. systemd carries the
    # other unit's restart to it; the plan must carry it too, as a
    # confirmed stop-start, or a SIGTERM-ignoring instance would be left
    # alive beside a fresh one (or a stop-start never restarted).
    let nUnit = ("repro-fixture-excl-n.service", successor)
    proc xUnit(v: string): (string, string) =
      ("repro-fixture-excl-x.service", "[Unit]\nDescription=part-of anchor " & v &
       "\n\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n")
    proc eUnit(id, script: string; extra = ""): (string, string) =
      ("repro-fixture-excl-e.service", "[Unit]\nDescription=part-of exclusive " & id &
       "\nX-Repro-Exclusive=true\nPartOf=repro-fixture-excl-x.service\n\n[Service]\nExecStart=" &
       script & " " & id & "\n" & extra & "\n[Install]\nWantedBy=multi-user.target\n")
    let stubbornE = eUnit("e1", "/usr/local/bin/repro-fixture-stubborn",
                          "TimeoutStopSec=3\nSendSIGKILL=no\n")
    applied("g12a-part-of", profile([c1, nUnit, xUnit("v1"), stubbornE]))
    let ePid = instances("^/bin/sh /usr/local/bin/repro-fixture-stubborn e1$")
    step("vacuity guard: e1 runs, PartOf= the anchor (systemd lists it in ConsistsOf=)",
         ePid.len > 0 and "repro-fixture-excl-e.service" in
           g.run("systemctl show -p ConsistsOf --value repro-fixture-excl-x.service"), ePid)
    let staticBefore12 = g.run("readlink /etc/repro/static").strip()
    let plan12 = g.planProfile(repro, "g12b-plan", profile([c1, nUnit, xUnit("v2"), stubbornE]))
    step("g12b: changing only the anchor plans a confirmed stop-start of its PartOf= exclusive unit",
         "stop-start\trepro-fixture-excl-e.service" in plan12.stdout and
         "propagating dependency" in plan12.stdout, plan12.stdout & plan12.stderr)
    let r12 = g.applyProfile(repro, "g12b-anchor-changes", profile([c1, nUnit, xUnit("v2"), stubbornE]))
    step("g12b: refused with EAddOnExclusiveOverlap while the PartOf= instance will not die",
         r12.exitCode == 2 and "EAddOnExclusiveOverlap" in r12.stderr and
         "repro-fixture-excl-e.service" in r12.stderr, "exit " & $r12.exitCode & "\n" & r12.stdout & r12.stderr)
    step("g12b: the old instance is the same process, alone; nothing was switched",
         instances("^/bin/sh /usr/local/bin/repro-fixture-stubborn e1$") == ePid and
         g.run("readlink /etc/repro/static").strip() == staticBefore12 and
         "v1" in g.run("systemctl show -p Description --value repro-fixture-excl-x.service"),
         g.run("cat " & LogPath))
    forceDown("repro-fixture-excl-e.service")
    discard g.run("mv " & LogPath & " " & LogPath & ".part5; : > " & LogPath)
    let goodE = eUnit("e2", "/usr/local/bin/repro-fixture-exclusive")
    applied("g12c-part-of-cooperative", profile([c1, nUnit, xUnit("v2"), goodE]))
    let plan12d = g.planProfile(repro, "g12d-plan", profile([c1, nUnit, xUnit("v3"), goodE]))
    step("g12d: the anchor's change carries a stop-start of the PartOf= unit, after the anchor",
         "restart\trepro-fixture-excl-x.service" in plan12d.stdout and
         "stop-start\trepro-fixture-excl-e.service" in plan12d.stdout and
         plan12d.stdout.find("restart\trepro-fixture-excl-x.service") <
           plan12d.stdout.find("stop-start\trepro-fixture-excl-e.service"), plan12d.stdout)
    applied("g12d-anchor-changes", profile([c1, nUnit, xUnit("v3"), goodE]))
    noOverlap("g12d-anchor-changes")
    step("g12d: the PartOf= unit was restarted (stopped, then started again) and runs",
         g.run("systemctl is-active repro-fixture-excl-e.service").strip() == "active" and
         g.run("grep -c '^start e2 ' " & LogPath & "; true").strip() == "2" and
         "v3" in g.run("systemctl show -p Description --value repro-fixture-excl-x.service"),
         g.run("cat " & LogPath))
    discard g.run("mv " & LogPath & " " & LogPath & ".part6; : > " & LogPath)

    # g13: an unmanaged predecessor that is static but can be started by
    # an enabled socket refuses the successor too.
    discard g.putProfile("old2", "[Unit]\nDescription=static predecessor\n\n[Service]\n" &
      "ExecStart=/usr/local/bin/repro-fixture-exclusive o2\n")
    discard g.putProfile("old2sock", "[Unit]\nDescription=predecessor socket\n\n[Socket]\n" &
      "ListenStream=127.0.0.1:7998\nService=repro-fixture-excl-old2.service\n\n" &
      "[Install]\nWantedBy=sockets.target\n")
    discard g.run("cp /root/addon/old2.profile /etc/systemd/system/repro-fixture-excl-old2.service && " &
      "cp /root/addon/old2sock.profile /etc/systemd/system/repro-fixture-excl-old2.socket && " &
      "systemctl daemon-reload && systemctl enable --now repro-fixture-excl-old2.socket")
    step("vacuity guard: the predecessor is static, its socket enabled and listening",
         g.run("systemctl show -p UnitFileState --value repro-fixture-excl-old2.service").strip() == "static" and
         g.run("systemctl is-enabled repro-fixture-excl-old2.socket").strip() == "enabled" and
         g.run("systemctl is-active repro-fixture-excl-old2.socket").strip() == "active", "")
    let succ2 = ("repro-fixture-excl-n2.service", "[Unit]\nDescription=exclusive fixture n2\n" &
      "X-Repro-Exclusive=true\nConflicts=repro-fixture-excl-old2.service\n\n[Service]\n" &
      "ExecStart=/usr/local/bin/repro-fixture-exclusive n2\n\n[Install]\nWantedBy=multi-user.target\n")
    let p13 = profile([c1, nUnit, xUnit("v3"), goodE, succ2])
    let f13 = g.takeFingerprint(repro)
    let r13 = g.applyProfile(repro, "g13-socket-predecessor", p13)
    step("g13: refused while a static predecessor's socket is enabled, naming the socket",
         r13.exitCode == 2 and "EAddOnExclusiveOverlap" in r13.stderr and
         "repro-fixture-excl-old2.socket" in r13.stderr, "exit " & $r13.exitCode & "\n" & r13.stdout & r13.stderr)
    let i13 = identityReport(f13, g.takeFingerprint(repro))
    step("g13: the refused apply wrote nothing (fingerprint unchanged)", i13.ok, i13.text)
    step("g13: the successor never started", " n2 " notin g.run("cat " & LogPath), g.run("cat " & LogPath))
    discard g.run("systemctl disable --now repro-fixture-excl-old2.socket")
    applied("g13b-after-the-operator-disabled-the-socket", p13)
    noOverlap("g13b")
    step("g13b: n2 runs", g.run("systemctl is-active repro-fixture-excl-n2.service").strip() == "active", "")

    discard g.run("mv " & LogPath & " " & LogPath & ".part7; : > " & LogPath)

    # g14: Requires= propagates a restart too (systemd's RequiredBy=). An
    # exclusive unit that Requires= the anchor, under KillMode=process
    # with a worker that ignores SIGTERM: changing only the anchor plans
    # a confirmed stop-start of it, which refuses while the worker lives.
    let base14 = @[c1, nUnit, xUnit("v3"), goodE, succ2]
    proc rUnit(id: string): (string, string) =
      ("repro-fixture-excl-r.service", "[Unit]\nDescription=requires exclusive " & id &
       "\nX-Repro-Exclusive=true\nRequires=repro-fixture-excl-xr.service\n" &
       "After=repro-fixture-excl-xr.service\n\n[Service]\nExecStart=" &
       "/usr/local/bin/repro-fixture-withchild " & id &
       "\nKillMode=process\nTimeoutStopSec=3\n\n[Install]\nWantedBy=multi-user.target\n")
    proc xrUnit(v: string): (string, string) =
      ("repro-fixture-excl-xr.service", "[Unit]\nDescription=requires anchor " & v &
       "\n\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n")
    applied("g14a-requires", profile(base14 & @[xrUnit("v1"), rUnit("r1")]))
    step("vacuity guard: r1 and its worker run; the anchor lists it in RequiredBy=",
         instances("^/bin/sh /usr/local/bin/repro-fixture-withchild r1$").len > 0 and
         "repro-fixture-excl-r.service" in
           g.run("systemctl show -p RequiredBy --value repro-fixture-excl-xr.service"),
         g.run("cat " & LogPath))
    let plan14 = g.planProfile(repro, "g14b-plan", profile(base14 & @[xrUnit("v2"), rUnit("r1")]))
    step("g14b: changing only the anchor plans a confirmed stop-start of the Requires= unit",
         "stop-start\trepro-fixture-excl-r.service" in plan14.stdout and
         "propagating dependency" in plan14.stdout, plan14.stdout & plan14.stderr)
    let r14 = g.applyProfile(repro, "g14b-anchor-changes", profile(base14 & @[xrUnit("v2"), rUnit("r1")]))
    step("g14b: refused with EAddOnExclusiveOverlap while the KillMode=process worker lives",
         r14.exitCode == 2 and "EAddOnExclusiveOverlap" in r14.stderr and
         "repro-fixture-excl-r.service" in r14.stderr, "exit " & $r14.exitCode & "\n" & r14.stdout & r14.stderr)
    step("g14b: no second instance was started",
         g.run("grep -c '^start r1 ' " & LogPath & "; true").strip() == "1", g.run("cat " & LogPath))
    forceDown("repro-fixture-excl-r.service")
    discard g.run("mv " & LogPath & " " & LogPath & ".part8; : > " & LogPath)

    # g15: PropagatesStopTo= carries the anchor's restart to the dependent
    # as a stop: the plan says so, the dependent is stopped (confirmed) and
    # not started again, and nothing overlaps.
    proc x2Unit(v: string): (string, string) =
      ("repro-fixture-excl-x2.service", "[Unit]\nDescription=stop-propagating anchor " & v &
       "\nPropagatesStopTo=repro-fixture-excl-e4.service\n\n[Service]\n" &
       "ExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n")
    let e4 = ("repro-fixture-excl-e4.service", exclusiveUnit("e4"))
    applied("g15a-propagates-stop", profile(base14 & @[xrUnit("v2"), x2Unit("v1"), e4]))
    let plan15 = g.planProfile(repro, "g15b-plan", profile(base14 & @[xrUnit("v2"), x2Unit("v2"), e4]))
    step("g15b: changing only the anchor plans a stop of its PropagatesStopTo= unit",
         "restart\trepro-fixture-excl-x2.service" in plan15.stdout and
         "stop\trepro-fixture-excl-e4.service" in plan15.stdout, plan15.stdout & plan15.stderr)
    applied("g15b-anchor-changes", profile(base14 & @[xrUnit("v2"), x2Unit("v2"), e4]))
    noOverlap("g15b-anchor-changes")
    step("g15b: the dependent is stopped, as systemd's own propagation leaves it",
         g.exec("systemctl is-active repro-fixture-excl-e4.service").stdout.strip() != "active" and
         g.run("grep -c '^stop e4 ' " & LogPath & "; true").strip() == "1", g.run("cat " & LogPath))

    applied("g11-remove", profile([]))
    discard g.run("rm -f /etc/systemd/system/repro-fixture-excl-c.service " &
      "/etc/systemd/system/repro-fixture-excl-old.service " &
      "/etc/systemd/system/repro-fixture-excl-old2.service " &
      "/etc/systemd/system/repro-fixture-excl-old2.socket; systemctl daemon-reload; true")
    discard g.run("pkill -f '^/bin/sh /usr/local/bin/repro-fixture-withchild'; true")
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
