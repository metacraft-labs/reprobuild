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

proc alivenessFrom*(unit: string; props: Table[string, string];
                    cgroupRoot: string): UnitAliveness =
  ## The decision of ``unitAliveness`` over what systemd reported
  ## (``ControlGroup``, ``Slice``, ``LoadState``) and the hierarchy at
  ## ``cgroupRoot``; pure apart from reading that tree, for the tests.
  ##
  ## - no unified (v2) hierarchy, or no ``LoadState`` reported: unknown;
  ## - systemd names a group whose directory is missing: unknown -- the
  ##   group may have been moved or the hierarchy remounted, and "missing"
  ##   is not evidence that nothing runs (fail closed);
  ## - systemd names no group (a unit with nothing running): the group it
  ##   would use (its slice plus its name) is checked, in case one
  ##   outlived the unit's state; that one missing means empty;
  ## - otherwise ``cgroup.events`` ``populated``; anything else unknown.
  if not fileExists(cgroupRoot / "cgroup.controllers"):
    return uaUnknown
  if "LoadState" notin props: return uaUnknown
  let named = props.getOrDefault("ControlGroup").strip(chars = {'/'})
  var rel = named
  if rel.len == 0:
    let slice = props.getOrDefault("Slice")
    rel = sliceCgroupPath(if slice.len > 0: slice else: "system.slice")
    rel = (if rel.len > 0: rel & "/" else: "") & unit
  let dir = cgroupRoot / rel
  if not dirExists(dir):
    return (if named.len > 0: uaUnknown else: uaEmpty)
  try:
    for line in readFile(dir / "cgroup.events").splitLines():
      let f = line.splitWhitespace()
      if f.len == 2 and f[0] == "populated":
        return (if f[1] == "0": uaEmpty elif f[1] == "1": uaPopulated
                else: uaUnknown)
  except IOError, OSError:
    discard
  uaUnknown

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
  var props: Table[string, string]
  try:
    let r = runSystemctl(["show", "-p", "ControlGroup", "-p", "Slice",
                          "-p", "LoadState", "--", unit])
    if r.exitCode != 0: return uaUnknown
    props = parseShowProperties(r.output)
  except CatchableError:
    return uaUnknown
  alivenessFrom(unit, props, CgroupRoot)

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

proc unitListProperty*(unit, property: string): seq[string] =
  ## A space-separated list property (``ConsistsOf``, ``BoundBy``,
  ## ``TriggeredBy``, ``Conflicts``) as systemd reports it for the loaded
  ## unit, drop-ins included. Empty for a unit systemd does not know.
  unitProperty(unit, property).splitWhitespace()

proc unitDependents*(unit: string): seq[string] =
  ## The units a stop or restart of ``unit`` propagates to: those with
  ## ``PartOf=`` it (systemd reports them as its ``ConsistsOf=``) and
  ## those with ``BindsTo=`` it (``BoundBy=``).
  for p in ["ConsistsOf", "BoundBy"]:
    for d in unitListProperty(unit, p):
      if d notin result: result.add(d)

proc resolveUnitName*(name: string): string =
  ## The unit an alias names (``systemctl show -p Id``); the name itself
  ## for a unit systemd does not know. Raises ``SwitchError`` when systemd
  ## cannot be asked: a predecessor that cannot be resolved is not
  ## assumed to be something else.
  let r = runSystemctl(["show", "-p", "Id", "--value", "--", name])
  if r.exitCode != 0:
    raise newException(SwitchError, "cannot resolve unit " & name & ": " &
      r.output.strip())
  let id = r.output.strip()
  if id.len == 0: name else: id

const UnitDropInDirs* = ["/etc/systemd/system", "/run/systemd/system",
                         "/usr/local/lib/systemd/system",
                         "/usr/lib/systemd/system", "/lib/systemd/system"]

proc dropInTextsOnDisk*(unit: string): seq[string] =
  ## The ``<unit>.d/*.conf`` drop-ins on disk, in systemd's order (by file
  ## name; a name in an earlier directory hides the same name later). A
  ## template instance also reads its template's drop-ins.
  var names: seq[(string, string)]
  var seen: seq[string]
  var units = @[unit]
  let at = unit.find('@')
  let dot = unit.rfind('.')
  if at > 0 and dot > at + 1:
    units.add(unit[0 .. at] & unit[dot .. ^1])
  for u in units:
    for d in UnitDropInDirs:
      let dir = d / (u & ".d")
      if not dirExists(dir): continue
      for kind, path in walkDir(dir):
        let n = extractFilename(path)
        if not n.endsWith(".conf") or n in seen: continue
        seen.add(n)
        names.add((n, path))
  names.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
  for (_, path) in names:
    try: result.add(readFile(path))
    except IOError, OSError: discard

proc predecessorsOf*(unit, content: string; extraDropIns: openArray[string]):
    seq[string] =
  ## An exclusive unit's predecessors (spec §7.3): the ``.service`` units
  ## its ``Conflicts=`` names -- read from the content the generation
  ## writes and the drop-ins (on disk and in the profile) with systemd's
  ## syntax, and, for a unit systemd has loaded, from ``systemctl show -p
  ## Conflicts`` -- each resolved to the unit an alias names. Raises when a
  ## name cannot be resolved (``ConflictsParseError``, ``SwitchError``).
  var names = conflictsServices(content, unit, dropInTextsOnDisk(unit) &
                                @extraDropIns)
  for n in unitListProperty(unit, "Conflicts"):
    if n.endsWith(".service") and n notin names: names.add(n)
  for n in names:
    let id = resolveUnitName(n)
    if id != unit and id notin result: result.add(id)

proc systemctlVerb(verb, unit: string) =
  let r = if unit.len > 0: runSystemctl([verb, "--", unit])
          else: runSystemctl([verb])
  if r.exitCode != 0:
    raise newException(SwitchError, "systemctl " & verb & " " & unit & ": " &
      r.output.strip())

proc stopUnit*(unit: string) = systemctlVerb("stop", unit)
proc startUnit*(unit: string) = systemctlVerb("start", unit)
proc restartUnit*(unit: string) = systemctlVerb("restart", unit)
proc tryRestartUnit*(unit: string) = systemctlVerb("try-restart", unit)
  ## Restart only if active (§7.3: "a restart applies only to a unit that
  ## is active when the apply reaches it").
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
    notRunning*: seq[string]
                            ## stop-start units step 2 found not running
                            ## (they ended since the plan): step 7 does not
                            ## start them, as a restart would not have

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
      if t.verb == tvStopStart and not unitIsActive(t.unit) and
          unitAliveness(t.unit) == uaEmpty:
        result.notRunning.add(t.unit)
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

proc runStart*(ts: seq[Transition]; paused: openArray[string] = [];
               notRunning: openArray[string] = []) =
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
      if t.verb == tvStopStart and t.unit in notRunning:
        continue          # ended before step 2: a restart would not start it
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
    of tvRestart: tryRestartUnit(t.unit)
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

type
  RunningUnit* = object
    ## A unit whose definition the add-on manages (its unit file, or a
    ## drop-in of a distribution unit) that is running now (§5.2).
    unit*: string
    definition*: string      ## its definition in the current ledger
                             ## (``unitDefinition``); "" for an instance a
                             ## removal left running
    invocationId*: string    ## systemd's ``InvocationID`` of the running
                             ## instance; "" when systemd did not say

  GenerationUnitLookup* = proc(generationId, unit: string):
      tuple[ledgerFound, unitFound: bool; definition: string] {.closure.}
    ## The unit's definition (``unitDefinition``) in a generation's own
    ## ledger.

  InvocationTable* = Table[string, string]
    ## ``InvocationID`` -> the generation whose definition that instance
    ## of its unit runs. systemd gives every start of a unit a new
    ## invocation id (systemd.exec(5) ``$INVOCATION_ID``), so the record
    ## is exact and needs no clock: a host without a real-time clock (a
    ## Raspberry Pi before NTP) can register generations with timestamps
    ## that go backwards, which a time comparison would misread.

proc unitDefinition*(l: Ledger; unit: string): string =
  ## What defines ``unit`` in ledger ``l``: its unit file's digest and
  ## every drop-in's path and digest, in a canonical order. "" when the
  ## ledger has neither.
  var parts: seq[string]
  for e in l.entries:
    if e.unit != unit and not (e.class == lcUnit and e.path.endsWith("/" & unit)):
      continue
    if e.class == lcUnit and e.resource.len > 0:
      parts.add("unit " & e.sha256)
    elif e.class == lcDropIn and e.resource.len > 0:
      parts.add("dropIn " & e.path & " " & e.sha256)
  parts.sort()
  parts.join("\n")

proc runningManagedUnits*(l: Ledger): seq[RunningUnit] =
  ## Every unit the ledger defines -- a unit file, or a drop-in of a
  ## distribution unit (a drop-in held by ``restartIfChanged = false``
  ## leaves its unit running the older drop-in) -- and every instance a
  ## removal left running (``stopOnRemoval = false``, a resource-less state
  ## entry), that is running now, with its invocation id.
  var seen = initHashSet[string]()
  for e in l.entries:
    let managed = ((e.class == lcUnit or e.class == lcDropIn) and
                   e.resource.len > 0) or
      (e.class == lcUnitState and e.resource.len == 0 and e.started and
       e.unitState.len == 0)
    if not managed or e.unit.len == 0 or e.unit in seen: continue
    seen.incl(e.unit)
    let running = unitIsActive(e.unit) or unitAliveness(e.unit) != uaEmpty
    if not running: continue
    result.add(RunningUnit(unit: e.unit,
      definition: (if e.class == lcUnitState: "" else: unitDefinition(l, e.unit)),
      invocationId: unitProperty(e.unit, "InvocationID")))

proc invocationsAfterSwitch*(table: InvocationTable;
                             running: seq[RunningUnit];
                             before: Table[string, string];
                             newGeneration, previousGeneration: string):
    InvocationTable =
  ## The invocation table after a switch committed ``newGeneration``.
  ## ``before`` maps each managed unit to the invocation id it had before
  ## step 2. An instance started during the switch (its id changed) runs
  ## the new generation's definition; one that kept its id keeps what the
  ## table said, or -- started outside any switch since the last one --
  ## the previous committed generation's, which was on disk then. Entries
  ## of instances no longer running are dropped.
  for u in running:
    if u.invocationId.len == 0: continue
    if before.getOrDefault(u.unit) != u.invocationId:
      result[u.invocationId] = newGeneration
    elif u.invocationId in table:
      result[u.invocationId] = table[u.invocationId]
    elif previousGeneration.len > 0:
      result[u.invocationId] = previousGeneration

proc readInvocationTable*(path: string): InvocationTable =
  ## ``<invocation id>\t<generation id>`` lines; a missing file is empty.
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    let f = line.split('\t')
    if f.len == 2 and f[0].len > 0 and f[1].len > 0:
      result[f[0]] = f[1]

proc writeInvocationTable*(path: string; t: InvocationTable) =
  var keys: seq[string]
  for k in t.keys: keys.add(k)
  keys.sort()
  var text = ""
  for k in keys: text.add(k & "\t" & t[k] & "\n")
  createDir(parentDir(path))
  let tmp = path & ".tmp"
  writeFile(tmp, text)
  moveFile(tmp, path)

proc generationsHeldBy*(units: seq[RunningUnit]; table: InvocationTable;
                        current: string; lookup: GenerationUnitLookup):
    HashSet[string] =
  ## The generations whose roots running units still need: the generation
  ## an instance runs (``table``), when it is not the current one and its
  ## own ledger gives the unit another definition (or is missing). An
  ## instance the table does not know started after the last switch, from
  ## the definition on disk: the current one, which needs nothing extra.
  for u in units:
    let g = table.getOrDefault(u.invocationId)
    if g.len == 0 or g == current: continue
    let found = if lookup != nil: lookup(g, u.unit)
                else: (ledgerFound: false, unitFound: false, definition: "")
    if not found.ledgerFound or found.definition != u.definition:
      result.incl(g)

proc pruneGenerationRoots*(current, previous: string;
                           policy = DefaultRetention;
                           now = getTime().toUnix();
                           held: HashSet[string] = initHashSet[string]()):
    seq[string] =
  ## Drop the ``profile`` store roots of add-on generations outside the
  ## policy, so ``repro store gc`` can collect what only they held. Never
  ## the current or the previous generation (spec §5.2: collecting what
  ## they hold would turn the next reboot into an outage), and never one in
  ## ``held`` -- the generations running managed units still run from
  ## (``generationsHeldBy``). Returns the generation ids whose roots were
  ## dropped.
  if not dirExists(StoreRoot): return
  enterWritableStoreView()
  var s = openStore(StoreRoot)
  defer: s.close()
  var rows: seq[RootRow]
  for r in s.listRoots():
    if r.rootId.startsWith(RootIdPrefix) and r.kind == $rkProfile:
      rows.add(r)
  let inUse = held
  # Newest first by registration time.
  rows.sort(proc(a, b: RootRow): int = cmp(b.createdAtUnix, a.createdAtUnix))
  var kept = 0
  for r in rows:
    let id = r.rootId[RootIdPrefix.len .. ^1]
    # By age only when an age was asked for: `--keep-days 0` keeps nothing
    # by age, even a generation whose registration time lies in the
    # future of a clock that stepped back (a host without a real-time
    # clock). With a positive age such a generation counts as young --
    # erring towards keeping.
    let young = policy.keepDays > 0 and
      now - r.createdAtUnix < int64(policy.keepDays) * 86400
    if id == current or id == previous or kept < max(policy.keepGenerations, 0) or
        young or id in inUse:
      inc kept
      continue
    s.deleteRoot(r.rootId)
    result.add(id)
