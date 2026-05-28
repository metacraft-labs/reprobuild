## Resource dependency graph + topological sort for HOME-SCOPE
## resources (M82 home-scope follow-up).
##
## The home planner orders the emitted resource actions so a CONSUMER
## action always runs AFTER its PRODUCER. Two edge sources feed the
## graph:
##
##   1. EXPLICIT — the user's `depends_on = ["kind:name", ...]` on a
##      `home.nim` `resources:` stanza. Each entry resolves to a
##      producer resource present in the same `DesiredSet`; the
##      producer -> consumer edge is added. Unresolved entries fail
##      closed at plan time (typo / stale reference surface).
##
##   2. IMPLICIT — the `home_producer_consumer_map.ProducerConsumerMap`.
##      Empty today (no known home-scope producer/consumer pairs).
##      The planner still consults it so the first implicit edge added
##      later is picked up automatically without a planner change.
##
## The sort is Kahn's algorithm with a STABLE secondary key
## (declaration index) — independent actions keep their declaration
## order, which keeps the emitted action stream byte-comparable across
## runs of the same profile text.
##
## Cycles are refused with `EHomePlanCyclicDependency` naming the
## cycle path. Self-edges are refused at edge-build time with a clear
## attribution; multi-node cycles are refused after Kahn's pass when
## nodes remain with non-zero in-degree.
##
## This module is the HOME-SCOPE ADAPTER over the generic graph
## kernel in `repro_core/dep_graph.nim`. The kernel owns Kahn's
## algorithm, the explicit-vs-implicit edge dedupe, and the
## cycle-trace DFS; this adapter owns the `seq[Resource]`-to-graph
## translation, the `depends_on`-to-edge resolution, the implicit
## producer / consumer edge inference, and the cycle-index-to-address
## translation when a cycle is detected. The system-scope adapter
## lives in `libs/repro_infra/src/repro_infra/planner.nim`.

import repro_core
import repro_home_resources

import ./errors
import ./home_producer_consumer_map

proc findResourceIndex(resources: seq[Resource];
                       depKind, depName: string): int =
  ## Return the declaration index of the resource matching
  ## `(depKind, depName)`, or `-1` if none. Matching is by
  ## `resourceKindTag` + `resourceName` — the same pair the
  ## `depends_on` syntax names. The match is EXACT (no prefix
  ## semantics for explicit edges — the user wrote a literal address
  ## and the planner respects it; the prefix logic is reserved for
  ## the implicit `ProducerConsumerMap` matching).
  for i in 0 ..< resources.len:
    let r = resources[i]
    if resourceKindTag(r) == depKind and resourceName(r) == depName:
      return i
  return -1

proc buildDependencyGraph*(resources: seq[Resource]): Graph =
  ## Resolve every explicit `depends_on` entry + every implicit
  ## producer/consumer fact into an edge set over the input
  ## resources. Pure — no observation, no I/O. Raises
  ## `EHomePlanCyclicDependency` on a self-edge (with the offending
  ## resource address named directly); raises `EApplyPlanFailed` if
  ## an explicit `depends_on` entry refers to a `(kind, name)` no
  ## resource in the input satisfies. (The cycle check for multi-node
  ## cycles runs in `topologicallyOrder`.)
  result = Graph(nodeCount: resources.len)

  proc record(g: var Graph; fromIdx, toIdx: int; src: EdgeKind) =
    if fromIdx == toIdx:
      # A self-edge would always cycle; refuse it at construction
      # time with clear attribution that names the offending address
      # directly. The shared kernel's generic `EGraphCycle` is the
      # wrong tool here — we have a strictly better diagnostic
      # available at the adapter layer.
      raiseHomePlanCyclicDependency(@[
        resources[fromIdx].address,
        resources[fromIdx].address])
    addEdge(g, fromIdx, toIdx, src)

  # 1. EXPLICIT edges from each stanza's `depends_on`.
  for consumerIdx in 0 ..< resources.len:
    let r = resources[consumerIdx]
    for dep in r.dependsOn:
      let producerIdx = findResourceIndex(resources, dep.kind, dep.name)
      if producerIdx < 0:
        raisePlanFailed("resource '" & r.address &
          "' depends_on '" & dep.kind & ":" & dep.name &
          "' but no resource in the profile satisfies that " &
          "(kind, name) pair")
      record(result, producerIdx, consumerIdx, edkExplicit)

  # 2. IMPLICIT edges from the shared producer/consumer map. For
  # every resource we treat it as a candidate producer; if any
  # consumer it would register is present in the desired set, link
  # producer -> consumer. The home table is empty today, so this
  # loop is a no-op until a home producer is added.
  for producerIdx in 0 ..< resources.len:
    let r = resources[producerIdx]
    let consumers = lookupProducedResources(resourceKindTag(r),
                                            resourceName(r))
    for c in consumers:
      let consumerIdx = findResourceIndex(resources, c.kind, c.name)
      if consumerIdx >= 0:
        record(result, producerIdx, consumerIdx, edkImplicit)

proc topologicallyOrder*(resources: seq[Resource]; graph: Graph): seq[int] =
  ## Return the resource declaration-indices in apply order: every
  ## producer before every consumer; ties broken by declaration
  ## index (stable secondary key). Delegates to the shared kernel's
  ## `topologicallyOrder`; on a multi-node cycle the kernel's
  ## `EGraphCycle.cyclePath` (a seq of node indices) is translated
  ## here into a `seq[string]` of home-scope resource addresses and
  ## rewrapped as `EHomePlanCyclicDependency` — the operator-facing
  ## exception type the M82 home-scope contract names.
  try:
    repro_core.topologicallyOrder(graph)
  except EGraphCycle as e:
    var addressPath: seq[string]
    for idx in e.cyclePath:
      addressPath.add(resources[idx].address)
    raiseHomePlanCyclicDependency(addressPath)

proc orderResourcesTopologically*(resources: seq[Resource]):
                                  seq[Resource] =
  ## Convenience wrapper: build the graph + topologically sort + emit
  ## the resources in apply order. Used by `pipeline.composePlan`'s
  ## caller to drive a stable, dependency-correct apply sequence.
  let graph = buildDependencyGraph(resources)
  let order = topologicallyOrder(resources, graph)
  for idx in order:
    result.add(resources[idx])
