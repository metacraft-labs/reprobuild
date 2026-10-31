## Service transition planning (ReproOS Add-On Mode §7.3).
##
## Pure: the facts about each unit are gathered by the apply (what the
## ledger recorded, what systemd reports, what the composed profile
## declares) and handed here; the result is the plan's **transition
## list**, the third add-on section of ``repro infra plan`` (§7.1): every
## unit to stop, start, restart or reload, or deliberately left as it is,
## with the reason, so the operator reads what the switch will do to the
## running services before it does it, and the gate
## ``e2e_addon_switch_is_planned_exactly`` checks that what systemd then
## reports equals this list.
##
## The switch executes it in two steps (§7.2): the ``stop`` and
## ``stop-start`` entries in step 2, before any file changes (a removed
## unit, an exclusive unit whose definition changes), and the ``start``,
## ``restart`` and ``reload`` entries in step 7, after the files, in
## dependency order. ``leave`` entries are reported, never acted on.

import std/[algorithm, strutils, tables]

import ./mutations

type
  TransitionVerb* = enum
    tvStart = "start"
    tvStop = "stop"
    tvRestart = "restart"
    tvReload = "reload"
    tvStopStart = "stop-start"
      ## An exclusive unit whose definition changed: stopped and
      ## confirmed exited in step 2, started in step 7; never two
      ## instances at once.
    tvLeave = "leave"
      ## Reported, not acted on: a pending restart (`restartIfChanged =
      ## false`), or a removed unit kept running (`stopOnRemoval = false`).

  Transition* = object
    unit*: string
    verb*: TransitionVerb
    reason*: string
    exclusive*: bool
      ## The stop must be confirmed (the unit's cgroup empty) before the
      ## switch goes on; a stop that cannot be confirmed refuses the apply
      ## (`EAddOnExclusiveOverlap`).
    predecessors*: seq[string]
      ## Exclusive starts only: the units whose control groups must be
      ## empty, besides the unit's own, before it starts -- every
      ## exclusive unit this generation removes (a rename's old name) and
      ## the `.service` units the unit's own `Conflicts=` names (an
      ## adoption under a new name). Not part of the rendered record: the
      ## reason names them.
    triggers*: seq[string]
      ## `stop-start` only: the units that can activate this one (systemd's
      ## `TriggeredBy=`: sockets, timers, paths) and were active at plan
      ## time. Step 2 stops them before the unit, step 7 starts them again
      ## after it, so an activation between the two steps cannot start the
      ## old definition again. Named in the reason, not rendered apart.

  UnitAliveness* = enum
    ## What the unit's control group says (cgroup v2 ``cgroup.events``
    ## ``populated``, which covers every child group of the unit).
    uaEmpty = "empty"
    uaPopulated = "populated"
    uaUnknown = "unknown"
      ## Could not be read (no unified hierarchy, a read error, systemd
      ## not answering): an exclusive check treats it as alive.

  UnitFacts* = object
    ## One unit as the planner sees it, in dependency order.
    unit*: string
    address*: string
    owned*: bool          ## the profile writes the unit (else a distribution
                          ## unit the profile only drops into or requires)
    removed*: bool        ## leaves the profile in this apply
    isNew*: bool          ## not in the previous ledger
    active*: bool         ## ActiveState=active now
    activeState*: string  ## the ActiveState observed (the plan pins it)
    alive*: UnitAliveness ## the control group's population, observed for
                          ## exclusive units (and their predecessors):
                          ## ActiveState alone misses an instance left
                          ## alive by a stop that timed out (`failed`)
    enabled*: bool        ## desired: enabled (an inactive enabled unit is
                          ## started when it is (re)applied)
    desiredActive*: bool  ## unitState: desired active (owned = false)
    unitState*: bool      ## a `systemd.unitState` requirement
    exclusive*: bool
    restartHeld*: bool    ## restartIfChanged = false
    reloadIfChanged*: bool
    stopHeld*: bool       ## stopOnRemoval = false
    fileChanged*: bool    ## the rendered unit file (or its closure) changed
    dropInsChanged*: bool ## a drop-in of the unit was created, changed or removed
    depsChanged*: bool    ## a resource it depends_on changed in this apply
    credentialsChanged*: bool
                          ## the secrets it loads (`credentials`) change in
                          ## this apply (ReproOS Add-On Mode §10.3): a unit
                          ## reads them when it starts, so this is a change
                          ## a reload cannot deliver
    predecessors*: seq[string]
                          ## exclusive units: the `.service` units the
                          ## unit's own `Conflicts=` names
    triggers*: seq[string] ## active units that can activate it (TriggeredBy)
    dependents*: seq[string]
                          ## the units a stop or restart of this one
                          ## propagates to as a stop or restart: systemd's
                          ## ``RequiredBy=``, ``RequisiteOf=``, ``BoundBy=``
                          ## and ``ConsistsOf=``. Each must have facts of its
                          ## own in the same list.
    stopDependents*: seq[string]
                          ## the units a stop (or restart) of this one stops:
                          ## its ``PropagatesStopTo=``
    reloadDependents*: seq[string]
                          ## its ``PropagatesReloadTo=``: a reload of this
                          ## unit reloads them (no instance starts; named in
                          ## the reason, not planned)

proc running*(f: UnitFacts): bool =
  ## Is an instance of the unit alive? For an exclusive unit the control
  ## group decides, not ``ActiveState``: a SIGTERM-ignoring instance under
  ## ``SendSIGKILL=no`` leaves its unit ``failed`` and its process alive,
  ## and planning a plain ``start`` (or skipping a removed unit) would run
  ## the successor beside it. An unknown population counts as alive.
  when mutated("exclusive-planned-by-active-state"):
    f.active
  else:
    f.active or (f.exclusive and f.alive != uaEmpty)

type ConflictsParseError* = object of ValueError
  ## A ``Conflicts=`` value the parser cannot resolve on its own (a
  ## specifier it does not expand): the caller refuses rather than guess.

proc expandUnitSpecifiers*(value, unitName: string): string =
  ## The unit-name specifiers of systemd.unit(5) "Specifiers" that a
  ## ``Conflicts=`` list can sensibly use -- ``%n`` (full name), ``%N``
  ## (name without type suffix), ``%p`` (prefix), ``%i`` / ``%I``
  ## (instance; unescaped is the same for the plain names this accepts),
  ## ``%j`` / ``%J`` (final dash component of the prefix) and ``%%``.
  ## Any other specifier raises ``ConflictsParseError``.
  let dot = unitName.rfind('.')
  let stem = if dot > 0: unitName[0 ..< dot] else: unitName
  let at = stem.find('@')
  let prefix = if at >= 0: stem[0 ..< at] else: stem
  let instance = if at >= 0: stem[at + 1 .. ^1] else: ""
  let dash = prefix.rfind('-')
  let lastDash = if dash >= 0: prefix[dash + 1 .. ^1] else: prefix
  var i = 0
  while i < value.len:
    if value[i] == '%' and i + 1 < value.len:
      case value[i + 1]
      of 'n': result.add(unitName)
      of 'N': result.add(stem)
      of 'p': result.add(prefix)
      of 'i', 'I': result.add(instance)
      of 'j', 'J': result.add(lastDash)
      of '%': result.add('%')
      else:
        raise newException(ConflictsParseError, "unsupported specifier %" &
          value[i + 1] & " in Conflicts= of " & unitName)
      i += 2
    else:
      result.add(value[i])
      inc i

proc conflictsServices*(content, unitName: string;
                        dropIns: openArray[string] = []): seq[string] =
  ## The ``.service`` units a unit's ``[Unit]`` section names in
  ## ``Conflicts=`` across the unit file and then its drop-ins, in the
  ## order systemd reads them: an exclusive unit's declared predecessors
  ## (spec §7.3). Follows systemd's syntax -- a trailing backslash
  ## continues a line, an empty assignment resets the list, ``%``
  ## specifiers are expanded against ``unitName`` -- and raises
  ## ``ConflictsParseError`` on a specifier it cannot expand. Implicit
  ## conflicts systemd adds (``shutdown.target``) are not in the files and
  ## not services. The caller also asks systemd (``systemctl show -p
  ## Conflicts``) for a unit it has loaded, and resolves aliases.
  proc scan(text: string; acc: var seq[string]) =
    var inUnit = false
    var pending = ""
    for raw in text.splitLines():
      var line = raw.strip(leading = false)
      if pending.len > 0:
        line = pending & " " & line.strip()
        pending = ""
      let t = line.strip()
      if t.endsWith("\\"):
        pending = t[0 ..< t.len - 1]
        continue
      if t.startsWith("["):
        inUnit = t == "[Unit]"
        continue
      if not inUnit or t.len == 0 or t[0] in {'#', ';'}:
        continue
      let eq = t.find('=')
      if eq < 0 or t[0 ..< eq].strip() != "Conflicts": continue
      let value = t[eq + 1 .. ^1].strip()
      if value.len == 0:
        acc.setLen(0)            # an empty assignment resets the list
        continue
      for name in expandUnitSpecifiers(value, unitName).splitWhitespace():
        if name.endsWith(".service") and name notin acc:
          acc.add(name)
  scan(content, result)
  for d in dropIns: scan(d, result)

proc isEffective*(t: Transition): bool =
  ## Does the switch act on it (every verb but `leave`)?
  t.verb != tvLeave

proc preStopEntries*(ts: seq[Transition]): seq[Transition] =
  ## What step 2 runs: exclusive stops first (a refusal there happens
  ## before any other unit was touched), then the rest.
  for t in ts:
    if t.verb in {tvStop, tvStopStart} and t.exclusive: result.add(t)
  for t in ts:
    if t.verb in {tvStop, tvStopStart} and not t.exclusive: result.add(t)

proc startEntries*(ts: seq[Transition]): seq[Transition] =
  ## What step 7 runs, in the order given (dependency order).
  for t in ts:
    if t.verb in {tvStart, tvRestart, tvReload, tvStopStart}: result.add(t)

proc isProcessUnit*(unit: string): bool =
  ## A unit that runs processes of its own and so can overlap: a service
  ## or a scope. Targets, sockets, timers, paths, mounts and devices carry a
  ## propagation on to their own dependents but are not themselves planned.
  unit.endsWith(".service") or unit.endsWith(".scope")

proc propagateStops*(ts: seq[Transition]; facts: seq[UnitFacts]):
    seq[Transition] =
  ## systemd carries an explicit stop or restart of a unit along its
  ## propagating dependencies (systemd.unit(5); the atoms of
  ## ``src/core/unit-dependency-atom.c``, systemd 252-260):
  ##
  ## - ``RequiredBy=`` (``Requires=`` it), ``RequisiteOf=`` (``Requisite=``
  ##   it), ``BoundBy=`` (``BindsTo=`` it) and ``ConsistsOf=`` (``PartOf=``
  ##   it): a stop as a stop, a restart as a restart (``dependents``);
  ## - ``PropagatesStopTo=`` (systemd 249+): a stop, and the stop half of a
  ##   restart, as a stop (``stopDependents``);
  ##
  ## and a start is carried along none of them. Left implicit, an exclusive
  ## dependent would be stopped and restarted by systemd with nothing
  ## confirming that its old instance exited, and a dependent of a
  ## ``stop-start`` unit would be stopped in step 2 and never started
  ## again. So the propagation is computed here, transitively, through
  ## units of every type, and every running service or scope it reaches
  ## gets an entry of its own: ``stop`` when what reaches it stops,
  ## ``stop-start`` when it restarts -- stopped (and, if exclusive,
  ## confirmed exited) in step 2 and started in step 7 after its cause. A
  ## dependent's own ``restart``, ``reload``, ``start`` or ``leave`` (a
  ## ``restartIfChanged = false`` hold cannot hold a restart systemd
  ## propagates) is replaced; a planned ``stop`` stays, and a stop
  ## reaching a planned ``stop-start`` makes it a ``stop``.
  result = ts
  var byUnit = initTable[string, int]()
  for i, f in facts: byUnit[f.unit] = i
  proc indexOf(r: seq[Transition]; unit: string): int =
    for i, t in r:
      if t.unit == unit: return i
    -1
  # The work list carries what reaches a unit: whether it restarts, the
  # entry the propagation started from (step 7 orders a dependent after
  # it), and the chain for the reason.
  var work: seq[tuple[unit: string; restarts: bool; anchor, chain: string]]
  for t in result:
    if t.verb in {tvStop, tvRestart, tvStopStart}:
      work.add((t.unit, t.verb in {tvRestart, tvStopStart}, t.unit, t.unit))
  var seen = initTable[string, bool]()   # unit -> restarts, as visited
  var guard = 0
  while work.len > 0 and guard < 100_000:
    inc guard
    let (cause, restarts, anchor, chain) = work.pop()
    if cause notin byUnit: continue
    let cf = facts[byUnit[cause]]
    var edges: seq[tuple[unit: string; restarts: bool]]
    for d in cf.dependents: edges.add((d, restarts))
    for d in cf.stopDependents: edges.add((d, false))
    for (d, r) in edges:
      if d notin byUnit or d == cause: continue
      let df = facts[byUnit[d]]
      if df.removed or not df.running: continue
      # Visit each unit once per kind; a stop dominates a restart.
      if d in seen and (seen[d] == r or not seen[d]): continue
      seen[d] = r
      let link = chain & " -> " & d
      if isProcessUnit(d):
        let di = result.indexOf(d)
        if di >= 0 and result[di].verb == tvStop:
          discard                  # already stopped: stays stopped
        elif di >= 0 and result[di].verb == tvStopStart and r:
          discard                  # already a confirmed stop-start
        elif not (di >= 0 and result[di].verb == tvStart):
          let why = (if r: "restarted along " else: "stopped along ") &
            link & " (propagating dependency)" &
            (if df.exclusive: "; exclusive: confirmed exited in step 2" else: "")
          let entry = Transition(unit: d, verb: (if r: tvStopStart else: tvStop),
            reason: why, exclusive: df.exclusive,
            predecessors: (if di >= 0: result[di].predecessors else: @[]),
            triggers: (if r: df.triggers else: @[]))
          if di >= 0: result.delete(di)
          # After the entry the propagation started from, so step 7 starts
          # it after that unit.
          let at = result.indexOf(anchor)
          result.insert(entry, at + 1)
      work.add((d, r, (if isProcessUnit(d): d else: anchor), link))

proc planTransitions*(facts: seq[UnitFacts]): seq[Transition] =
  ## The §7.3 table over every unit, in the order of ``facts``. Stops of
  ## removed units are listed first (the order the switch runs them in).
  ##
  ## | change | action |
  ## |---|---|
  ## | unit added | start if enabled |
  ## | unit removed | stop (`stopOnRemoval = false`: leave) |
  ## | file, drop-in or closure changed | restart if active (`restartIfChanged = false`: leave, pending restart) |
  ## | a `depends_on` resource changed | restart, same opt-out; `reloadIfChanged` and nothing else changed: reload |
  ## | exclusive | stop-start: the old instance stopped and confirmed exited before the new one starts |
  ##
  ## A restart applies only to a unit that is active when the apply
  ## reaches it; an inactive unit is started by a change only when it is
  ## `enabled` (the `enable --now` of a plain apply).
  var stops, starts: seq[Transition]
  # Every exclusive unit this generation removes is a predecessor of every
  # exclusive unit it starts (a rename's old name): its control group must
  # be empty before any of them starts.
  var removedExclusive: seq[string]
  for f in facts:
    if f.removed and f.exclusive: removedExclusive.add(f.unit)
  proc predecessorsOf(f: UnitFacts): seq[string] =
    for u in removedExclusive & f.predecessors:
      if u != f.unit and u notin result: result.add(u)
  proc after(f: UnitFacts): string =
    let p = predecessorsOf(f)
    if p.len == 0: "" else: "; after confirming " & p.join(", ") & " exited"
  for f in facts:
    if f.removed:
      if not f.running:
        continue                        # nothing running: the file goes
      if f.stopHeld:
        starts.add(Transition(unit: f.unit, verb: tvLeave,
          reason: "removed; left running (stopOnRemoval = false)"))
      else:
        stops.add(Transition(unit: f.unit, verb: tvStop,
          reason: (if f.active or not f.exclusive: "removed"
                   else: "removed; " & f.activeState & " but its control " &
                     "group is " & $f.alive),
          exclusive: f.exclusive))
      continue
    if f.unitState:
      # A requirement on a distribution unit: its driver converges it.
      if f.desiredActive and not f.active:
        starts.add(Transition(unit: f.unit, verb: tvStart,
          reason: "unitState requires it active"))
      elif not f.desiredActive and f.active:
        stops.add(Transition(unit: f.unit, verb: tvStop,
          reason: "unitState requires it stopped"))
      continue
    let changed = f.fileChanged or f.dropInsChanged or f.depsChanged or
                  f.credentialsChanged
    if not f.running:
      if f.owned and f.enabled and (f.isNew or changed):
        starts.add(Transition(unit: f.unit, verb: tvStart,
          reason: (if f.isNew: "added (enabled)"
                   else: "enabled and inactive; (re)applied") & after(f),
          exclusive: f.exclusive,
          predecessors: (if f.exclusive: predecessorsOf(f) else: @[])))
      continue
    if not changed:
      continue
    var what: seq[string]
    if f.fileChanged: what.add("unit file")
    if f.dropInsChanged: what.add("drop-in")
    if f.depsChanged: what.add("depends_on resource")
    if f.credentialsChanged: what.add("credentials")
    let why = what.join(", ") & " changed"
    if f.restartHeld:
      starts.add(Transition(unit: f.unit, verb: tvLeave,
        reason: why & "; pending restart (restartIfChanged = false)"))
    elif f.exclusive:
      starts.add(Transition(unit: f.unit, verb: tvStopStart,
        reason: why & "; exclusive: stopped and confirmed exited before " &
          "the new instance starts" &
          (if f.active: "" else: " (" & f.activeState &
             ", control group " & $f.alive & ")") &
          (if f.triggers.len > 0: "; pauses " & f.triggers.join(", ")
           else: "") & after(f),
        exclusive: true, predecessors: predecessorsOf(f),
        triggers: f.triggers))
    elif f.reloadIfChanged and not f.fileChanged and not f.dropInsChanged and
        not f.credentialsChanged:
      starts.add(Transition(unit: f.unit, verb: tvReload,
        reason: why & " (reloadIfChanged)" &
          (if f.reloadDependents.len > 0: "; systemd also reloads " &
             f.reloadDependents.join(", ") & " (PropagatesReloadTo=)" else: "")))
    else:
      starts.add(Transition(unit: f.unit, verb: tvRestart, reason: why))
  when mutated("partof-not-propagated"):
    # The falsifying mutation of the propagation: the plan leaves what
    # systemd carries along PartOf=/BindsTo= implicit.
    stops & starts
  else:
    propagateStops(stops & starts, facts)

proc propagateDependencyChanges*(facts: var seq[UnitFacts];
                                 dependsOn: Table[string, seq[string]]) =
  ## `depends_on` to a fixpoint (the infra planner's `markDependencyRestarts`
  ## for the switch): a unit that depends on a unit that is itself
  ## restarted or reloaded because something it runs from changed is
  ## restarted too. ``dependsOn`` maps a unit address to the addresses it
  ## depends on; only unit-to-unit edges matter here (other kinds were
  ## folded into `depsChanged` by the caller).
  var byAddress = initTable[string, int]()
  for i, f in facts: byAddress[f.address] = i
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< facts.len:
      if facts[i].depsChanged or facts[i].removed: continue
      for dep in dependsOn.getOrDefault(facts[i].address):
        if dep notin byAddress: continue
        let d = facts[byAddress[dep]]
        if d.removed or d.fileChanged or d.dropInsChanged or d.depsChanged:
          facts[i].depsChanged = true
          changed = true
          break

proc renderTransitions*(ts: seq[Transition]): string =
  ## The plan's transition section: ``<verb>\t<unit>\t<reason>`` lines,
  ## with a fourth field ``exclusive`` on an entry whose stop must be
  ## confirmed; machine-readable like the ledger diff.
  if ts.len == 0:
    return "service transitions: none\n"
  result = "service transitions:\n"
  for t in ts:
    result.add("  " & $t.verb & "\t" & t.unit & "\t" & t.reason &
               (if t.exclusive: "\texclusive" else: "") & "\n")

type TransitionParseError* = object of ValueError

proc parseTransitions*(text: string): seq[Transition] =
  ## The strict inverse of ``renderTransitions`` over a plan's output (the
  ## gates read the section back): an unknown verb, a record with too few
  ## or too many fields, or a fourth field other than ``exclusive`` is an
  ## error, never read as ``leave``.
  var inSection = false
  for raw in text.splitLines():
    if raw.startsWith("service transitions:"):
      inSection = raw.strip() == "service transitions:"
      continue
    if not inSection: continue
    if not raw.startsWith("  "):
      inSection = false
      continue
    let f = raw[2 .. ^1].split('\t')
    if f.len notin 3 .. 4:
      raise newException(TransitionParseError,
        "malformed transition record: " & raw)
    var verb: TransitionVerb
    var known = false
    for v in TransitionVerb:
      if $v == f[0]:
        verb = v
        known = true
    if not known:
      raise newException(TransitionParseError,
        "unknown transition verb '" & f[0] & "': " & raw)
    if f[1].len == 0:
      raise newException(TransitionParseError,
        "transition record without a unit: " & raw)
    var exclusive = false
    if f.len == 4:
      if f[3] != "exclusive":
        raise newException(TransitionParseError,
          "unknown transition flag '" & f[3] & "': " & raw)
      exclusive = true
    result.add(Transition(unit: f[1], verb: verb, reason: f[2],
                          exclusive: exclusive))
