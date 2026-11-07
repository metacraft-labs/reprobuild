## Which unit a seccomp audit record belongs to, by process lifetime.
##
## The syscall-trace gate of the ReproOS add-on's A9 milestone
## (``tests/e2e/addon/t_e2e_addon_unit_syscall_filters_cover_their_traces``)
## reads every seccomp audit record (``type=1326``) the kernel wrote while
## the add-on's units worked, and must say which unit made each call. A
## record carries the calling process's pid and the kernel's own time stamp
## (``msg=audit(<epoch>.<ms>:<serial>)``), not its unit. A sampler in the
## guest (``fixtures/cgroup_sampler/a9_cgroup_sampler.c``) watches each
## unit's control group and reports every process it saw as
## ``<unit> <pid> <start> <last-seen>``: the process is (pid, start time),
## so a pid the kernel hands out again later is another process, and it
## lived from ``start`` to some time before ``last-seen + period``.
##
## A record belongs to a unit when its time falls inside the lifetime of
## exactly one process with the record's pid, and that process was in that
## unit's control group. No such process, or more than one (two lifetimes
## of the pid that both cover the time, or one process seen in two
## groups), is ``aoAmbiguous`` / ``aoNone``: never assigned. Matching by pid
## alone -- the first version of this attribution -- assigns a reused pid's
## records to whichever unit had it first (A9 review round 2: the foreign
## unit's records landed in the apply unit on a 32-bit guest, whose 32768
## pids wrapped within the hour); ``t_addon_trace_attribution`` pins both.

import std/[strutils]

type
  ProcLifetime* = object
    unit*: string
    pid*: int
    start*: float      ## seconds since the epoch, from the stat start time
    lastSeen*: float   ## seconds since the epoch, the last sample it was in

  AttributionKind* = enum
    akUnit        ## exactly one process's lifetime covers the record
    akNone        ## no sampled process with the pid lived then
    akAmbiguous   ## more than one did, or one seen in two groups

  Attribution* = object
    kind*: AttributionKind
    unit*: string

const
  StartSlack* = 0.011
    ## The start time is in clock ticks (10 ms at the usual 100 Hz) and is
    ## rounded down: a record can lie up to one tick before it.

proc parseLifetimes*(text: string): seq[ProcLifetime] =
  ## The sampler's output; malformed lines are skipped.
  for l in text.splitLines():
    let f = l.splitWhitespace()
    if f.len != 4: continue
    try:
      result.add(ProcLifetime(unit: f[0], pid: parseInt(f[1]),
        start: parseFloat(f[2]), lastSeen: parseFloat(f[3])))
    except ValueError:
      discard

proc covers(p: ProcLifetime; at, period: float): bool =
  at >= p.start - StartSlack and at <= p.lastSeen + period

proc attribute*(lifetimes: openArray[ProcLifetime]; pid: int; at: float;
                period: float): Attribution =
  ## The unit the call of process ``pid`` at time ``at`` was made in
  ## (``akUnit``), or why it cannot be said. ``period`` is the sampler's,
  ## in seconds: a process lived until some time before its last sighting
  ## plus one period.
  var found: seq[ProcLifetime]
  for p in lifetimes:
    if p.pid == pid and p.covers(at, period): found.add(p)
  if found.len == 0: return Attribution(kind: akNone)
  for p in found[1 .. ^1]:
    if p.unit != found[0].unit or abs(p.start - found[0].start) > StartSlack:
      return Attribution(kind: akAmbiguous)
  Attribution(kind: akUnit, unit: found[0].unit)

proc auditTime*(line: string): float =
  ## The kernel's time stamp of an audit record line
  ## (``... msg=audit(1730000000.123:456): ...`` or ``audit(...)``), or
  ## -1 when the line carries none.
  let i = line.find("audit(")
  if i < 0: return -1
  let j = line.find(':', i)
  if j < 0: return -1
  try: parseFloat(line[i + "audit(".len ..< j])
  except ValueError: -1
