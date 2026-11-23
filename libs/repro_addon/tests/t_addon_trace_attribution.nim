## The syscall-trace gate's record attribution (ReproOS Add-On Mode milestone
## A9, CONF-3; review round 2): a seccomp record belongs to a unit when it
## falls in the lifetime of exactly one sampled process -- (pid, start
## time) -- of that unit (``repro_test_support/syscall_attribution``).
##
## Positive control: a synthetic pid-reuse sequence, as a 32-bit guest
## produced it, where matching by pid alone (the first version, kept here
## as ``byPidSeen``) assigns a foreign process's records to an add-on unit
## and the lifetime match does not.
##
## Mocks: none. The sampler's output format is written out by hand: it is
## the input under test, not a stand-in for a dependency.

import std/[sets, unittest]

import repro_test_support/syscall_attribution

const Period = 0.001

proc byPidSeen(lifetimes: openArray[ProcLifetime]; pid: int;
               units: openArray[string]): string =
  ## The first attribution (A9 review round 2's finding): every unit a pid
  ## was ever seen in; an add-on unit wins when there is only one.
  var seen = initHashSet[string]()
  for p in lifetimes:
    if p.pid == pid: seen.incl(p.unit)
  var hits: seq[string]
  for u in units:
    if u in seen: hits.add(u)
  if hits.len == 1: hits[0] else: ""

suite "attributing a seccomp record to the unit that made the call":
  # pid 4242 was an apply-unit process at t=100..100.5, then -- after the
  # pid space wrapped -- a foreign unit's `sleep` at t=900..900.05.
  let lifetimes = parseLifetimes(
    "repro-agent-apply.service 4242 100.000000 100.500000\n" &
    "a9-foreign.service 4242 900.000000 900.050000\n" &
    "repro-agent-fetch.service 77 50.000000 60.000000\n")
  let units = ["repro-agent-fetch.service", "repro-agent-apply.service"]

  test "pid reuse: the foreign process's record is not the apply unit's":
    # The positive control: the old code misattributes it.
    check byPidSeen(lifetimes, 4242, units) == "repro-agent-apply.service"
    let a = attribute(lifetimes, 4242, 900.02, Period)
    check a.kind == akUnit
    check a.unit == "a9-foreign.service"

  test "a record inside the apply process's lifetime is the apply unit's":
    let a = attribute(lifetimes, 4242, 100.2, Period)
    check a.kind == akUnit and a.unit == "repro-agent-apply.service"

  test "a record outside every lifetime of its pid is not assigned":
    check attribute(lifetimes, 4242, 500.0, Period).kind == akNone
    check attribute(lifetimes, 9999, 100.2, Period).kind == akNone

  test "two lifetimes covering one time are ambiguous, never assigned":
    let overlap = parseLifetimes(
      "repro-agent-apply.service 5 10.000000 20.000000\n" &
      "a9-foreign.service 5 15.000000 25.000000\n")
    check attribute(overlap, 5, 17.0, Period).kind == akAmbiguous
    # One process seen in two groups (moved) is ambiguous too.
    let moved = parseLifetimes(
      "repro-agent-apply.service 6 10.000000 20.000000\n" &
      "repro-addon-reassert.service 6 10.000000 21.000000\n")
    check attribute(moved, 6, 15.0, Period).kind == akAmbiguous

  test "a record a tick before the rounded-down start time still matches":
    check attribute(lifetimes, 77, 49.995, Period).kind == akUnit
    check attribute(lifetimes, 77, 49.98, Period).kind == akNone

  test "the kernel's own time stamp is read from the record":
    check abs(auditTime("audit: type=1326 audit(1730000000.123:456): " &
      "auid=4294967295 pid=4242 comm=\"sleep\"") - 1730000000.123) < 1e-6
    check abs(auditTime("SECCOMP msg=audit(1730000001.5:9): pid=1") -
      1730000001.5) < 1e-6
    check auditTime("no stamp here") < 0
