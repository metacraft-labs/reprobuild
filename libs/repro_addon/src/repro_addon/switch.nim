## The host-side steps of the add-on switch (ReproOS Add-On Mode §7.2)
## that act on systemd and the kernel: stopping, starting, restarting and
## reloading units (steps 2 and 7), confirming an exclusive unit has
## exited, running the fragment tools (step 6), and the generation
## retention policy that follows a commit (§5.2).
##
## Everything here goes through the host's own tools by absolute path
## (``host_exec``) and never through a shell.
##
## **Exclusive units** (§7.3). ``systemctl stop`` returns when the unit's
## job is done, but a unit whose process ignores SIGTERM and declares
## ``SendSIGKILL=no`` ends in ``failed`` with the process still alive in
## its cgroup. "Confirmed exited" therefore means the unit's control
## group -- with every child group below it, which a ``Delegate=yes``
## unit may create and move its processes into -- holds no process: the
## cgroup v2 ``populated`` flag of ``cgroup.events``
## (https://docs.kernel.org/admin-guide/cgroup-v2.html#core-interface-files),
## not ``ActiveState`` and not the top-level ``cgroup.procs``. Anything
## that cannot be read -- no unified hierarchy, ``systemctl`` failing, a
## missing ``cgroup.events`` -- is "not confirmed", never "exited". A unit
## that cannot be confirmed makes the apply refuse with
## ``EAddOnExclusiveOverlap`` before step 3, so nothing was switched and
## the successor is never started; the same check runs again immediately
## before every start of an exclusive unit in step 7, over the unit and
## its predecessors.
##
## **Sysctl** (§7.2 step 6, threat model G35). A ``net.*`` key is per
## network namespace, so a ``sysctl -w`` from inside the apply unit's
## ``PrivateNetwork=yes`` would set a throwaway namespace's copy and read
## it back as success. Each changed fragment is applied by the host's own
## ``systemd-sysctl <fragment>``, run as a transient unit in the host
## namespaces, and the effective values are observed by a transient unit
## the host's systemd runs for us (``systemd-run --wait --pipe``).

import std/[algorithm, os, sets, strutils, tables, times]

import repro_infra/addon_diagnostics
import repro_local_store/store

import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./store_root
import ./transitions

type
  SwitchError* = object of CatchableError

const
  SystemdSysctlCandidates* = ["/usr/lib/systemd/systemd-sysctl",
                              "/lib/systemd/systemd-sysctl"]
  CgroupRoot* = "/sys/fs/cgroup"
  ExclusiveStopGraceSeconds* = 5
    ## After `systemctl stop` returns, how long the control group may
    ## still drain before the unit counts as not confirmed.

# ---------------------------------------------------------------------------
# Units.
# ---------------------------------------------------------------------------

proc unitProperty*(unit, property: string): string =
  ## One ``systemctl show -p`` value, "" when unknown.
  let r = runSystemctl(["show", "-p", property, "--value", "--", unit])
  if r.exitCode != 0: "" else: r.output.strip()

proc unitIsActive*(unit: string): bool =
  unitProperty(unit, "ActiveState") == "active"

proc sliceCgroupPath*(slice: string): string =
  ## The cgroup directory of a slice, relative to the hierarchy's root:
  ## systemd nests ``a-b.slice`` inside ``a.slice``
  ## (https://www.freedesktop.org/software/systemd/man/latest/systemd.slice.html);
  ## the root slice ``-.slice`` is the root itself.
  if slice.len == 0 or slice == "-.slice": return ""
  let base = slice[0 ..< slice.len - ".slice".len]
  var acc = ""
  for i, part in pairs(base.split('-')):
    acc = (if i == 0: part else: acc & "-" & part)
    if result.len > 0: result.add('/')
    result.add(acc & ".slice")

proc parseShowProperties(text: string): Table[string, string] =
  for line in text.splitLines():
    let eq = line.find('=')
    if eq > 0: result[line[0 ..< eq]] = line[eq + 1 .. ^1].strip()

proc unitAliveness*(unit: string): UnitAliveness =
  ## Does the unit's control group, or any group below it, hold a process?
  ## Fails closed: every error and every hierarchy this cannot read is
  ## ``uaUnknown``, which no exclusive check accepts as exited.
  when mutated("exclusive-exited-by-top-level-procs"):
    # The falsifying mutation of the delegated-subgroup fixture: the
    # pre-round-2 check, the top-level ``cgroup.procs`` only, with every
    # unknown read as empty.
    let cg = unitProperty(unit, "ControlGroup")
    if cg.len == 0: return uaEmpty
    let path = CgroupRoot / cg.strip(chars = {'/'}) / "cgroup.procs"
    if not fileExists(path): return uaEmpty
    try:
      if readFile(path).strip().len > 0: return uaPopulated
    except IOError, OSError:
      discard
    return uaEmpty
  if not fileExists(CgroupRoot / "cgroup.controllers"):
    return uaUnknown                  # not a unified (v2) hierarchy
  var props: Table[string, string]
  try:
    let r = runSystemctl(["show", "-p", "ControlGroup", "-p", "Slice",
                          "-p", "LoadState", "--", unit])
    if r.exitCode != 0: return uaUnknown
    props = parseShowProperties(r.output)
  except CatchableError:
    return uaUnknown
  if "LoadState" notin props: return uaUnknown
  var rel = props.getOrDefault("ControlGroup").strip(chars = {'/'})
  if rel.len == 0:
    # systemd reports no group for a unit with nothing running; the group
    # it would use is still checked, in case it outlived the unit's state.
    let slice = props.getOrDefault("Slice")
    rel = sliceCgroupPath(if slice.len > 0: slice else: "system.slice")
    rel = (if rel.len > 0: rel & "/" else: "") & unit
  let dir = CgroupRoot / rel
  if not dirExists(dir): return uaEmpty     # no group: nothing alive
  try:
    for line in readFile(dir / "cgroup.events").splitLines():
      let f = line.splitWhitespace()
      if f.len == 2 and f[0] == "populated":
        return (if f[1] == "0": uaEmpty elif f[1] == "1": uaPopulated
                else: uaUnknown)
  except IOError, OSError:
    discard
  uaUnknown

proc cgroupProcs*(unit: string): seq[string] =
  ## The PIDs in the unit's control group and every group below it, for
  ## diagnostics only (the decision is ``unitAliveness``).
  let cg = unitProperty(unit, "ControlGroup")
  if cg.len == 0: return @[]
  let root = CgroupRoot / cg.strip(chars = {'/'})
  if not dirExists(root): return @[]
  try:
    for path in walkDirRec(root, yieldFilter = {pcFile}, followFilter = {pcDir}):
      if path.extractFilename == "cgroup.procs":
        for line in readFile(path).splitLines():
          if line.strip().len > 0: result.add(line.strip())
  except IOError, OSError:
    discard

proc systemctlVerb(verb, unit: string) =
  let r = if unit.len > 0: runSystemctl([verb, "--", unit])
          else: runSystemctl([verb])
  if r.exitCode != 0:
    raise newException(SwitchError, "systemctl " & verb & " " & unit & ": " &
      r.output.strip())

proc stopUnit*(unit: string) = systemctlVerb("stop", unit)
proc startUnit*(unit: string) = systemctlVerb("start", unit)
proc restartUnit*(unit: string) = systemctlVerb("restart", unit)
proc reloadUnit*(unit: string) = systemctlVerb("reload", unit)
proc disableUnit*(unit: string) = systemctlVerb("disable", unit)

proc daemonReload*() = systemctlVerb("daemon-reload", "")

proc describeAlive(unit: string): string =
  ## The unit's state for a refusal, naming every active unit that can
  ## activate it again (a socket the add-on does not own, say): a removed
  ## exclusive unit such a trigger keeps re-starting is refused, never
  ## stopped by stopping a trigger that is not the add-on's (§7.3).
  let procs = cgroupProcs(unit)
  var active: seq[string]
  for t in unitProperty(unit, "TriggeredBy").splitWhitespace():
    if unitIsActive(t): active.add(t)
  "(ActiveState=" & unitProperty(unit, "ActiveState") & ", SubState=" &
    unitProperty(unit, "SubState") &
    (if procs.len > 0: ", process(es) " & procs.join(", ") else: "") & ")" &
    (if active.len > 0: "; it can be activated again by " &
       active.join(", ") & " (active)" else: "")

proc stopExclusive*(unit: string; graceSeconds = ExclusiveStopGraceSeconds) =
  ## Stop ``unit`` and confirm its control group (with every group below
  ## it) is empty; refuse with ``EAddOnExclusiveOverlap`` otherwise (the
  ## successor must not start while the old instance lives).
  try:
    stopUnit(unit)
  except SwitchError as e:
    # `stop` failing (a timeout with SendSIGKILL=no, a job cancelled) is
    # not yet a refusal: what matters is whether anything is still alive.
    discard e
  let deadline = epochTime() + graceSeconds.float
  while true:
    let alive = unitAliveness(unit)
    if alive == uaEmpty:
      return
    if epochTime() >= deadline:
      raise newAddOnExclusiveOverlap(unit, "its control group is " & $alive &
        " after `systemctl stop` " & describeAlive(unit))
    sleep(200)

proc confirmExited*(units: openArray[string]; successor: string) =
  ## Immediately before ``successor`` (an exclusive unit) starts: every
  ## unit in ``units`` -- the successor itself and its predecessors --
  ## must have an empty control group. Not stopped here: a predecessor
  ## alive now is one the plan did not stop, so the apply refuses.
  for u in units:
    let alive = unitAliveness(u)
    if alive != uaEmpty:
      raise newAddOnExclusiveOverlap(successor, (if u == successor:
        "its own control group is " else: "its predecessor " & u &
        "'s control group is ") & $alive & " " & describeAlive(u))

type
  PreStopResult* = object
    stopped*: seq[string]   ## the units step 2 stopped, in order
    paused*: seq[string]    ## triggers of stop-start units step 2 stopped;
                            ## step 7 starts them again

type
  PreStopObserver* = proc(unit: string) {.closure.}
    ## Told about each unit step 2 is ABOUT to stop (``unit``), each trigger
    ## it is about to pause (``"trigger:" & unit``) and each unit it is about
    ## to disable (``"disable:" & unit``), before it acts, so the pending
    ## marker never misses one that a crash or a refusal interrupts.

proc runPreStop*(ts: seq[Transition]; disable: openArray[string];
                 onStop: PreStopObserver = nil): PreStopResult =
  ## Step 2: the transition list's stops, exclusive ones first and
  ## confirmed, then ``disable`` for the units this generation removes
  ## (their files are about to go, so their [Install] links go with them
  ## while systemd can still read the unit). A ``stop-start`` unit's
  ## active triggers (sockets, timers, paths) are stopped first, so they
  ## cannot start its old definition again before step 7. Last, every
  ## exclusive unit step 7 will start is checked with its predecessors,
  ## so a refusal happens here, before the flip.
  template note(u: string) =
    if onStop != nil: onStop(u)
  when mutated("exclusive-as-plain-restart"):
    # The falsifying mutation: an exclusive unit gets no special step.
    # Its old instance is stopped AFTER the successor starts (`runStart`
    # below) -- "start new, then stop old", the plain order of a
    # rolling restart -- so the two lifetimes overlap, which the gate's
    # lifetime log catches. Nothing is confirmed exited either.
    for t in preStopEntries(ts):
      if t.exclusive: continue
      note(t.unit)
      stopUnit(t.unit)
      result.stopped.add(t.unit)
  else:
    for t in preStopEntries(ts):
      if t.verb == tvStopStart:
        for trig in t.triggers:
          if unitIsActive(trig) and trig notin result.paused:
            note("trigger:" & trig)
            stopUnit(trig)
            result.paused.add(trig)
      note(t.unit)
      if t.exclusive:
        stopExclusive(t.unit)
      else:
        stopUnit(t.unit)
      result.stopped.add(t.unit)
    for t in startEntries(ts):
      if t.exclusive and t.verb in {tvStart, tvStopStart}:
        confirmExited(@[t.unit] & t.predecessors, t.unit)
  for u in disable:
    note("disable:" & u)
    try: disableUnit(u)
    except SwitchError: discard   # already disabled, or static

proc runStart*(ts: seq[Transition]; paused: openArray[string] = []) =
  ## Step 7: start, restart or reload in the order given. A
  ## ``stop-start`` unit was stopped in step 2 and is started here. Every
  ## start of an exclusive unit first confirms the unit and its
  ## predecessors exited -- again: something may have activated it since
  ## step 2 (D-Bus, an operator), and such an instance runs the old
  ## definition, so it is stopped and confirmed before the new one starts.
  ## The triggers step 2 paused start again immediately before their unit.
  for t in startEntries(ts):
    case t.verb
    of tvStart, tvStopStart:
      when mutated("exclusive-as-plain-restart"):
        if t.verb == tvStopStart: restartUnit(t.unit)   # a plain restart
        else: startUnit(t.unit)
      else:
        if t.exclusive:
          if unitAliveness(t.unit) != uaEmpty or unitIsActive(t.unit):
            stopExclusive(t.unit)
          confirmExited(@[t.unit] & t.predecessors, t.unit)
        # The paused triggers start just before their unit: systemd
        # refuses to start an `Accept=no` socket whose service already
        # runs, and the old instance was confirmed exited above, so an
        # activation from here on runs the new definition.
        for trig in t.triggers:
          if trig in paused and unitProperty(trig, "LoadState") == "loaded":
            startUnit(trig)
        startUnit(t.unit)
    of tvRestart: restartUnit(t.unit)
    of tvReload: reloadUnit(t.unit)
    else: discard
  when mutated("exclusive-as-plain-restart"):
    # The deferred stops of the exclusive units this generation removes:
    # after their successors started.
    for t in preStopEntries(ts):
      if t.exclusive and t.verb == tvStop:
        stopUnit(t.unit)

# ---------------------------------------------------------------------------
# Sysctl (step 6).
# ---------------------------------------------------------------------------

proc observeSysctlInHostNamespaces*(key: string): string =
  ## The host's effective value of ``key``, read by a transient unit in
  ## the host's namespaces (``host_exec.readHostSysctl``).
  readHostSysctl(key)

proc applySysctlFragments*(changedFragments: openArray[string]) =
  ## Apply the changed sysctl fragments, each by the host's own
  ## ``systemd-sysctl <fragment>`` run as a transient unit in the host's
  ## namespaces (spec §7.2 step 6). Only the changed fragments: restarting
  ## the whole ``systemd-sysctl.service`` would re-apply the distribution's
  ## fragments too and move keys the generation does not own (measured on
  ## Debian 13: ``net.ipv4.conf.all.accept_redirects``), which the
  ## fingerprint-equals-ledger check rightly refuses.
  let exe = resolveHostTool(SystemdSysctlCandidates)
  if exe.len == 0:
    raise newException(SwitchError, "systemd-sysctl not found at " &
      SystemdSysctlCandidates.join(" or "))
  for f in changedFragments:
    if not fileExists(f): continue       # removed: its key was restored
    when mutated("sysctl-in-apply-namespace"):
      # The falsifying mutation: run systemd-sysctl from THIS process --
      # inside the apply unit's PrivateNetwork=yes that is a throwaway
      # namespace, so the host's net.* values do not change.
      discard runHostTool([exe, f])
    else:
      let r = runInHostNamespaces([exe, f])
      if r.exitCode != 0:
        raise newException(SwitchError, "systemd-sysctl " & f & ": " &
          r.output.strip())

proc restoreSysctlValue*(key, value: string) =
  ## Put a key back to the value the ledger recorded before the add-on
  ## set it (a removed sysctl resource), from the host's namespaces.
  if value.len == 0: return
  let r = runInHostNamespaces(["/bin/sh", "-c",
    "printf '%s' \"$1\" > \"$2\"", "repro-addon", value, sysctlKeyPath(key)])
  if r.exitCode != 0:
    raise newException(SwitchError, "restoring sysctl " & key & " = " &
      value & ": " & r.output.strip())

# ---------------------------------------------------------------------------
# Retention (§5.2).
# ---------------------------------------------------------------------------

type
  RetentionPolicy* = object
    keepGenerations*: int   ## keep the newest N retained generations
    keepDays*: int          ## and every generation newer than this
    ## Whichever retains more. The current and the previous generation
    ## are kept whatever the policy says.

const DefaultRetention* = RetentionPolicy(keepGenerations: 5, keepDays: 30)

proc unitStartTimes(unit: string): seq[int64] =
  ## When the unit's running instance was started (``ActiveEnterTimestamp``
  ## and ``ExecMainStartTimestamp``, Unix seconds). Raises when systemd
  ## does not say: retention then keeps everything rather than guess.
  let r = runSystemctl(["show", "--timestamp=unix", "-p",
    "ActiveEnterTimestamp", "-p", "ExecMainStartTimestamp", "--", unit])
  if r.exitCode != 0:
    raise newException(SwitchError, "systemctl show " & unit & ": " &
      r.output.strip())
  for k, v in parseShowProperties(r.output):
    if v.startsWith("@"):
      try: result.add(parseBiggestInt(v[1 .. ^1]).int64)
      except ValueError:
        raise newException(SwitchError, "unreadable " & k & " of " & unit &
          ": " & v)
  if result.len == 0:
    raise newException(SwitchError, "systemd reports no start time for " &
      "the running unit " & unit)

type
  RunningUnit* = object
    ## A unit the add-on manages that is running now (§5.2 retention).
    unit*: string
    sha256*: string          ## its definition in the current ledger; ""
                             ## for an instance a removal left running
    startedAt*: seq[int64]   ## Unix seconds; empty: systemd did not say

  GenerationUnitLookup* = proc(generationId, unit: string):
      tuple[ledgerFound, unitFound: bool; sha256: string] {.closure.}
    ## The unit's definition in a generation's own ledger.

proc runningManagedUnits*(l: Ledger): seq[RunningUnit] =
  ## Every unit the add-on manages that is running now: the ledger's
  ## units, and the instances a removal left running (``stopOnRemoval =
  ## false``, a resource-less state entry), with when they started.
  var seen = initHashSet[string]()
  for e in l.entries:
    let managed = (e.class == lcUnit and e.resource.len > 0) or
      (e.class == lcUnitState and e.resource.len == 0 and e.started and
       e.unitState.len == 0)
    if not managed or e.unit.len == 0 or e.unit in seen: continue
    seen.incl(e.unit)
    let running = unitIsActive(e.unit) or unitAliveness(e.unit) != uaEmpty
    if not running: continue
    var ru = RunningUnit(unit: e.unit,
                         sha256: (if e.class == lcUnit: e.sha256 else: ""))
    try:
      ru.startedAt = unitStartTimes(e.unit)
    except CatchableError:
      ru.startedAt = @[]
    result.add(ru)

proc generationsUsedAt*(rows: seq[RootRow]; startedAt: int64): seq[string] =
  ## The generations a unit started at ``startedAt`` may run from: the
  ## last one committed at or before that moment (a start by the operator,
  ## a boot or a later apply that did not touch it loads the committed
  ## definition) and the first one committed at or after it (step 7 of a
  ## generation starts its units before step 9 commits it). Both are kept:
  ## which of the two it was is not recorded, and keeping one too many
  ## costs disk while keeping one too few breaks the service's next start.
  var before, after: RootRow
  var haveBefore, haveAfter = false
  for r in rows:
    if r.createdAtUnix <= startedAt and
        (not haveBefore or r.createdAtUnix > before.createdAtUnix):
      before = r
      haveBefore = true
    if r.createdAtUnix >= startedAt and
        (not haveAfter or r.createdAtUnix < after.createdAtUnix):
      after = r
      haveAfter = true
  if haveBefore: result.add(before.rootId[RootIdPrefix.len .. ^1])
  if haveAfter: result.add(after.rootId[RootIdPrefix.len .. ^1])

proc generationsHeldBy*(rows: seq[RootRow]; units: seq[RunningUnit];
                        lookup: GenerationUnitLookup): HashSet[string] =
  ## The generations whose roots running units still need: for each
  ## running unit, the generations it may run from (``generationsUsedAt``)
  ## whose own ledger gives it a definition other than the current one --
  ## a unit held by ``restartIfChanged = false`` or left running by
  ## ``stopOnRemoval = false`` runs from such a generation's closure. A
  ## generation that carried the same definition (or none: it did not
  ## start the unit) holds nothing the current one does not. A unit whose
  ## start time is unknown, or a generation whose ledger is missing, keeps
  ## the generation (every one, for an unknown start).
  for u in units:
    if u.startedAt.len == 0:
      for r in rows: result.incl(r.rootId[RootIdPrefix.len .. ^1])
      continue
    for t in u.startedAt:
      for id in generationsUsedAt(rows, t):
        let found = lookup(id, u.unit)
        if not found.ledgerFound or
            (found.unitFound and found.sha256 != u.sha256):
          result.incl(id)

proc pruneGenerationRoots*(current, previous: string;
                           policy = DefaultRetention;
                           now = getTime().toUnix();
                           running: seq[RunningUnit] = @[];
                           lookup: GenerationUnitLookup = nil): seq[string] =
  ## Drop the ``profile`` store roots of add-on generations outside the
  ## policy, so ``repro store gc`` can collect what only they held. Never
  ## the current or the previous generation (spec §5.2: collecting what
  ## they hold would turn the next reboot into an outage), and never a
  ## generation a running managed unit may still run from
  ## (``generationsHeldBy`` over ``running``, from ``runningManagedUnits``).
  ## Returns the generation ids whose roots were dropped.
  if not dirExists(StoreRoot): return
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  var rows: seq[RootRow]
  for r in s.listRoots():
    if r.rootId.startsWith(RootIdPrefix) and r.kind == $rkProfile:
      rows.add(r)
  let inUse = if running.len > 0 and lookup != nil:
                generationsHeldBy(rows, running, lookup)
              elif running.len > 0:
                # No way to read the generations' ledgers: keep them all.
                generationsHeldBy(rows, @[RunningUnit()], nil)
              else: initHashSet[string]()
  # Newest first by registration time.
  rows.sort(proc(a, b: RootRow): int = cmp(b.createdAtUnix, a.createdAtUnix))
  var kept = 0
  for r in rows:
    let id = r.rootId[RootIdPrefix.len .. ^1]
    let young = now - r.createdAtUnix < int64(max(policy.keepDays, 0)) * 86400
    if id == current or id == previous or kept < max(policy.keepGenerations, 0) or
        young or id in inUse:
      inc kept
      continue
    s.deleteRoot(r.rootId)
    result.add(id)
