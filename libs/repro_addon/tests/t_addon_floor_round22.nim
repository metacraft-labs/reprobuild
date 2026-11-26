## The add-on after the A9 review's round 22 (ReproOS Add-On Mode spec
## §10.1; §13 decision 155; A9 review rounds 16 and 17, findings 5 and 7):
## what a revert records as stopping, and when that record goes.
##
## - A revert that stops a held template records each of its running
##   instances by name (``revertUnitsToStop``), so the switch that clears
##   the holds starts exactly those again.
## - The switch that clears the holds plans the starts from the record
##   (``planRevertStoppedStarts``) and leaves the record in place; the
##   record goes only once step 7's starts have succeeded
##   (``finishRevertStopped``). A failed start, or a crash before step 7
##   ends, leaves it for the next switch.
##
## These are the procedures the switch calls at those two points
## (``addon_apply`` step 3's revert and steps 6 to 7 of the passing
## switch); round 17's header recorded that no test discriminated them.
##
## Falsifying builds, red here: ``revert-stopped-instances-unrecorded``,
## ``revert-stopped-cleared-early``.
##
## *Mocking.* ``isActive`` and ``runningInstances`` are closures over a
## table instead of ``systemctl``: the selection is a function of what
## systemd reports, and the VM gates drive the switch on real hosts. The
## record is the real file in a temporary state directory.

import std/[sets, tempfiles, os, unittest]

import repro_addon/addon_apply

suite "A9 review round 22: what a revert stops is recorded, and kept until started":
  test "a held template's running instances are recorded by name":
    let running = @["a@1.service", "a@2.service"]
    let rec = revertUnitsToStop(["a@.service", "b.service", "c.service"],
      proc (u: string): bool = u == "b.service",
      proc (t: string): seq[string] =
        if t == "a@.service": running else: @[])
    checkpoint $rec
    check "a@1.service" in rec
    check "a@2.service" in rec
    check "b.service" in rec
    check "c.service" notin rec       # held, but not running
    check "a@.service" notin rec      # the template itself never runs
  test "planning the starts leaves the record; it goes only after they succeed":
    let d = createTempDir("a9r22-", "-state")
    defer: removeDir(d)
    writeRevertStopped(d, ["x.service", "y.socket"])
    var gen = initHashSet[string]()
    gen.incl("x.service")
    gen.incl("y.socket")
    let plan = planRevertStoppedStarts(d, gen, [],
      proc (u: string): bool = false)
    check plan.problems.len == 0
    check "x.service" in plan.starts and "y.socket" in plan.starts
    # The record is there through step 7 ...
    check readRevertStopped(d) == @["x.service", "y.socket"]
    # ... stays when a start failed (or nothing was planned) ...
    check finishRevertStopped(d, planned = true, startsSucceeded = false).len == 0
    check readRevertStopped(d) == @["x.service", "y.socket"]
    check finishRevertStopped(d, planned = false, startsSucceeded = true).len == 0
    check readRevertStopped(d) == @["x.service", "y.socket"]
    # ... and goes once every planned start succeeded.
    check finishRevertStopped(d, planned = true, startsSucceeded = true).len == 0
    check readRevertStopped(d).len == 0
