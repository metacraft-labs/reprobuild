## The generic reconciler: given a desired `seq[ResourceInstance]`, the
## recorded bindings from the previous generation, and options, drive
## each resource through its registered driver in dependency order.
##
## The seven-step algorithm of `Resources-And-State.md` is unchanged;
## only the per-type leaf operations move behind `driver.*`, dispatched
## by a `typeId` registry lookup rather than a closed `case kind`.
##
## The per-resource decision is a MINIMAL generic re-statement of the
## home lib's `decideAction` (which is coupled to the `Resource` union
## via `state.desired.kind` and `digestOfResource`, so not importable
## for `ResourceInstance`). It reuses the home lib's `ResourceActionKind`
## enum so both lanes emit the same action vocabulary.

import std/[tables, options, sets, algorithm]

from repro_home_generations/pointer import Digest256
from repro_home_resources/types import ObservedState, ResourceActionKind,
  rakNoOp, rakCreate, rakUpdate, rakReplace, rakDestroy, rakAdopt,
  rakDriftBlocked
import repro_resources/instance

type
  ReconcileOptions* = object
    reconcileDrift*: bool
      ## When true, an operator-mutated (drifted) resource is converged
      ## with an update rather than emitting `rakDriftBlocked`.

  ResourceAction* = object
    ## The generic-lane planned action for one resource.
    address*: string
    typeId*: string
    kind*: ResourceActionKind
    summary*: string

  ReconcileResult* = object
    actions*: seq[ResourceAction]         ## in applied (topological) order
    bindings*: seq[ResourceBinding]       ## recorded bindings after apply

proc topoOrder(desired: seq[ResourceInstance]): seq[ResourceInstance] =
  ## Deterministic topological order by `dependsOn` (edges are resource
  ## addresses). Raises on an unknown dependency or a cycle.
  var byAddr = initTable[string, ResourceInstance]()
  for inst in desired:
    if byAddr.hasKey(inst.address):
      raise newException(ValueError,
        "duplicate resource address '" & inst.address & "'")
    byAddr[inst.address] = inst

  var ordered: seq[ResourceInstance] = @[]
  var visited = initHashSet[string]()
  var onStack = initHashSet[string]()

  proc visit(addrKey: string) =
    if addrKey in visited: return
    if addrKey in onStack:
      raise newException(ValueError,
        "dependency cycle involving resource '" & addrKey & "'")
    onStack.incl(addrKey)
    let inst = byAddr[addrKey]
    # Sort deps for a stable, reproducible order independent of the
    # authored `dependsOn` sequence order.
    var deps = inst.dependsOn
    deps.sort()
    for dep in deps:
      if not byAddr.hasKey(dep):
        raise newException(KeyError,
          "resource '" & addrKey & "' depends on unknown address '" &
          dep & "'")
      visit(dep)
    onStack.excl(addrKey)
    visited.incl(addrKey)
    ordered.add(inst)

  # Visit in a stable order (authored order) so independent subgraphs
  # keep their declaration order.
  for inst in desired:
    visit(inst.address)
  ordered

proc decide(desiredDigest: Digest256; observed: ObservedState;
            recorded: Option[ResourceBinding];
            options: ReconcileOptions): ResourceActionKind =
  ## Minimal generic decision, mirroring the home lib's `decideAction`
  ## branch structure for the desired-present case.
  if not observed.present:
    return rakCreate
  if observed.digest == desiredDigest:
    return rakNoOp                       # cache-hit: live state == desired
  # Observed differs from desired. If we recorded writing exactly what
  # is now observed, it is a safe update; if we never wrote it, the
  # diff is the initial-convergence delta (also an update); otherwise
  # it is operator drift.
  if recorded.isSome and recorded.get.present and
     recorded.get.postWriteDigest == observed.digest:
    return rakUpdate
  if recorded.isNone:
    return rakUpdate
  if options.reconcileDrift:
    return rakUpdate
  return rakDriftBlocked

proc reconcileResources*(desired: seq[ResourceInstance];
                         recorded: seq[ResourceBinding] = @[];
                         options: ReconcileOptions = ReconcileOptions()):
                         ReconcileResult =
  ## Drive the desired graph to convergence. Topologically orders by
  ## `dependsOn`, then per resource: look up the driver by `typeId`
  ## (hard error on unknown), `observe` -> `decide` -> `apply`,
  ## recording the returned binding. Pure w.r.t. process state — all
  ## real-world effect is confined to the driver callbacks, so it is
  ## unit-testable with an in-memory driver.
  result.actions = @[]
  result.bindings = @[]

  var recordedByAddr = initTable[string, ResourceBinding]()
  for b in recorded:
    recordedByAddr[b.address] = b

  for inst in topoOrder(desired):
    let def = lookupResourceProvider(inst.typeId)   # hard error on unknown
    let drv = def.driver
    let prior =
      if recordedByAddr.hasKey(inst.address): some(recordedByAddr[inst.address])
      else: none(ResourceBinding)

    let observed = drv.observe(inst, prior)
    let desiredDigest = drv.digest(inst)
    let action = decide(desiredDigest, observed, prior, options)

    result.actions.add(ResourceAction(
      address: inst.address,
      typeId: inst.typeId,
      kind: action,
      summary: $action & " " & inst.address & " (" & inst.typeId & ")"))

    case action
    of rakCreate, rakUpdate, rakReplace, rakDestroy:
      let binding = drv.apply(inst, action, observed)
      result.bindings.add(binding)
      recordedByAddr[inst.address] = binding
    of rakNoOp, rakAdopt, rakDriftBlocked:
      # No apply. Carry the prior binding forward if we had one so a
      # subsequent reconcile still sees the recorded post-write digest.
      if prior.isSome:
        result.bindings.add(prior.get)
