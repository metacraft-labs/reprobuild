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

  UnitFacts* = object
    ## One unit as the planner sees it, in dependency order.
    unit*: string
    address*: string
    owned*: bool          ## the profile writes the unit (else a distribution
                          ## unit the profile only drops into or requires)
    removed*: bool        ## leaves the profile in this apply
    isNew*: bool          ## not in the previous ledger
    active*: bool         ## ActiveState=active now
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
  for f in facts:
    if f.removed:
      if not f.active:
        continue                        # nothing running: the file goes
      if f.stopHeld:
        starts.add(Transition(unit: f.unit, verb: tvLeave,
          reason: "removed; left running (stopOnRemoval = false)"))
      else:
        stops.add(Transition(unit: f.unit, verb: tvStop,
          reason: "removed", exclusive: f.exclusive))
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
    let changed = f.fileChanged or f.dropInsChanged or f.depsChanged
    if not f.active:
      if f.owned and f.enabled and (f.isNew or changed):
        starts.add(Transition(unit: f.unit, verb: tvStart,
          reason: (if f.isNew: "added (enabled)"
                   else: "enabled and inactive; (re)applied"),
          exclusive: f.exclusive))
      continue
    if not changed:
      continue
    var what: seq[string]
    if f.fileChanged: what.add("unit file")
    if f.dropInsChanged: what.add("drop-in")
    if f.depsChanged: what.add("depends_on resource")
    let why = what.join(", ") & " changed"
    if f.restartHeld:
      starts.add(Transition(unit: f.unit, verb: tvLeave,
        reason: why & "; pending restart (restartIfChanged = false)"))
    elif f.exclusive:
      starts.add(Transition(unit: f.unit, verb: tvStopStart,
        reason: why & "; exclusive: stopped and confirmed exited before " &
          "the new instance starts", exclusive: true))
    elif f.reloadIfChanged and not f.fileChanged and not f.dropInsChanged:
      starts.add(Transition(unit: f.unit, verb: tvReload,
        reason: why & " (reloadIfChanged)"))
    else:
      starts.add(Transition(unit: f.unit, verb: tvRestart, reason: why))
  stops & starts

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
  ## machine-readable like the ledger diff.
  if ts.len == 0:
    return "service transitions: none\n"
  result = "service transitions:\n"
  for t in ts:
    result.add("  " & $t.verb & "\t" & t.unit & "\t" & t.reason & "\n")

proc parseTransitions*(text: string): seq[Transition] =
  ## The inverse of ``renderTransitions`` over a plan's output (the gate
  ## reads the section back).
  var inSection = false
  for raw in text.splitLines():
    if raw.startsWith("service transitions:"):
      inSection = true
      continue
    if not inSection: continue
    if not raw.startsWith("  "):
      inSection = false
      continue
    let f = raw[2 .. ^1].split('\t')
    if f.len < 3: continue
    var verb = tvLeave
    for v in TransitionVerb:
      if $v == f[0]: verb = v
    result.add(Transition(unit: f[1], verb: verb, reason: f[2 .. ^1].join("\t")))
