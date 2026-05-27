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
## STRUCTURAL parallel of `libs/repro_infra/src/repro_infra/planner.nim`
## (the system-scope graph code). The two modules are DELIBERATELY
## parallel rather than DRY: the home graph operates on a
## `seq[Resource]` (home-scope addresses, six kinds), the system graph
## on a `SystemProfile` (eleven kinds), and the cycle-exception types
## differ. A future refactor can lift the common Kahn's-sort kernel
## into a shared library once both halves stabilize; today the
## duplication keeps this PR's change surface inside home-scope files.

import std/[algorithm, sets, tables]

import repro_home_resources

import ./errors
import ./home_producer_consumer_map

type
  DependencyEdgeKind* = enum
    ## Why an edge was added — surfaced in diagnostics so a cycle
    ## error can tell the operator whether the offending edge came
    ## from a user-declared `depends_on` or from the producer/consumer
    ## map.
    edkExplicit = "explicit"             ## from a stanza's `depends_on`
    edkImplicit = "implicit"             ## from `ProducerConsumerMap`

  DependencyEdge* = object
    fromIdx*: int                        ## producer index (apply earlier)
    toIdx*: int                          ## consumer index (apply later)
    sourceKind*: DependencyEdgeKind

  DependencyGraph* = object
    ## Resolved dependency graph over a sequence of home resources.
    ## Nodes are identified by DECLARATION INDEX (the position in the
    ## input seq), so the stable secondary order falls out of the
    ## indices without an extra address-comparison step.
    edges*: seq[DependencyEdge]

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

proc buildDependencyGraph*(resources: seq[Resource]): DependencyGraph =
  ## Resolve every explicit `depends_on` entry + every implicit
  ## producer/consumer fact into an edge set over the input
  ## resources. Pure — no observation, no I/O. Raises
  ## `EHomePlanCyclicDependency` on a self-edge; raises
  ## `EApplyPlanFailed` if an explicit `depends_on` entry refers to a
  ## `(kind, name)` no resource in the input satisfies. (The cycle
  ## check for multi-node cycles runs in `topologicallyOrder`.)
  # De-duplicate edges so a user who both declares a `depends_on` AND
  # benefits from an implicit producer/consumer entry sees one edge,
  # not two. The dedupe key is `(fromIdx, toIdx)`; the explicit
  # source-kind wins so a cycle diagnostic still names the user's
  # edge.
  var seen = initTable[(int, int), DependencyEdgeKind]()

  proc record(fromIdx, toIdx: int; src: DependencyEdgeKind) =
    if fromIdx == toIdx:
      # A self-edge would always cycle; refuse it at construction
      # time with clear attribution — the cycle-detection path below
      # handles deeper loops.
      raiseHomePlanCyclicDependency(@[
        resources[fromIdx].address,
        resources[fromIdx].address])
    let key = (fromIdx, toIdx)
    if key notin seen:
      seen[key] = src
    elif src == edkExplicit:
      # Promote an implicit entry to explicit when the user has also
      # declared it (so cycle diagnostics name the user's source).
      seen[key] = edkExplicit

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
      record(producerIdx, consumerIdx, edkExplicit)

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
        record(producerIdx, consumerIdx, edkImplicit)

  for key, src in seen.pairs:
    result.edges.add(DependencyEdge(fromIdx: key[0], toIdx: key[1],
                                    sourceKind: src))
  # Stable iteration order: sort edges by (fromIdx, toIdx) so the
  # graph is deterministic regardless of the table's hash iteration.
  result.edges.sort(proc(a, b: DependencyEdge): int =
    if a.fromIdx != b.fromIdx: cmp(a.fromIdx, b.fromIdx)
    else: cmp(a.toIdx, b.toIdx))

proc traceCycle(resources: seq[Resource];
                graph: DependencyGraph;
                inDegree: seq[int]): seq[string] =
  ## When Kahn's algorithm leaves nodes unprocessed, run a DFS over
  ## the surviving subgraph (nodes with `inDegree > 0` OR a node
  ## still reachable from one) to find a concrete cycle and return
  ## its resource-address sequence with the entry node repeated at
  ## the end. Diagnostic-only; the cycle DETECTION is Kahn's "did we
  ## consume every node?" check.
  var adj: Table[int, seq[int]]
  for e in graph.edges:
    if e.fromIdx notin adj: adj[e.fromIdx] = @[]
    adj[e.fromIdx].add(e.toIdx)
  for k in adj.mvalues: k.sort()
  var start = -1
  for i in 0 ..< resources.len:
    if inDegree[i] > 0:
      start = i
      break
  if start < 0:
    return @[]                           # defensive — Kahn miscounted
  var stack: seq[int] = @[start]
  var path: seq[int] = @[start]
  var onStack: HashSet[int]
  onStack.incl(start)
  var iters: Table[int, int]
  iters[start] = 0
  while stack.len > 0:
    let node = stack[^1]
    let nexts = adj.getOrDefault(node, @[])
    var i = iters.getOrDefault(node, 0)
    var advanced = false
    while i < nexts.len:
      let nxt = nexts[i]
      inc i
      iters[node] = i
      if nxt in onStack:
        var cycleStart = 0
        for k in 0 ..< path.len:
          if path[k] == nxt:
            cycleStart = k
            break
        var cyclePath: seq[string]
        for k in cycleStart ..< path.len:
          cyclePath.add(resources[path[k]].address)
        cyclePath.add(resources[nxt].address)
        return cyclePath
      if inDegree[nxt] > 0 and nxt notin onStack:
        stack.add(nxt)
        path.add(nxt)
        onStack.incl(nxt)
        iters[nxt] = 0
        advanced = true
        break
    if not advanced:
      discard stack.pop()
      discard path.pop()
      onStack.excl(node)
  return @[]

proc topologicallyOrder*(resources: seq[Resource];
                         graph: DependencyGraph): seq[int] =
  ## Return the resource declaration-indices in apply order: every
  ## producer before every consumer; ties broken by declaration
  ## index (stable secondary key). Kahn's algorithm with a
  ## min-priority "ready set" keyed by declaration index —
  ## independent resources keep their declaration order, which makes
  ## the emitted action stream byte-comparable across runs of the
  ## same profile text. Raises `EHomePlanCyclicDependency` (via
  ## `traceCycle`) when a cycle prevents ordering every node.
  let n = resources.len
  var inDegree = newSeq[int](n)
  var outAdj = newSeq[seq[int]](n)
  for e in graph.edges:
    outAdj[e.fromIdx].add(e.toIdx)
    inc inDegree[e.toIdx]
  var ready: seq[int]
  for i in 0 ..< n:
    if inDegree[i] == 0:
      ready.add(i)
  while ready.len > 0:
    let node = ready[0]
    ready.delete(0)
    result.add(node)
    for nxt in outAdj[node]:
      dec inDegree[nxt]
      if inDegree[nxt] == 0:
        var pos = ready.len
        for j in 0 ..< ready.len:
          if ready[j] > nxt:
            pos = j
            break
        ready.insert(nxt, pos)
  if result.len < n:
    raiseHomePlanCyclicDependency(traceCycle(resources, graph, inDegree))

proc orderResourcesTopologically*(resources: seq[Resource]):
                                  seq[Resource] =
  ## Convenience wrapper: build the graph + topologically sort + emit
  ## the resources in apply order. Used by `pipeline.composePlan`'s
  ## caller to drive a stable, dependency-correct apply sequence.
  let graph = buildDependencyGraph(resources)
  let order = topologicallyOrder(resources, graph)
  for idx in order:
    result.add(resources[idx])
