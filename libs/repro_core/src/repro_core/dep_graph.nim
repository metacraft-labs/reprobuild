## Generic dependency-graph algorithms over integer node indices.
##
## This module is the SHARED kernel for the M82 Phase B dependency
## ordering used by BOTH the system-scope planner
## (`libs/repro_infra/src/repro_infra/planner.nim`) and the home-scope
## planner (`libs/repro_home_apply/src/repro_home_apply/dep_graph.nim`).
##
## The module is INTENTIONALLY domain-blind: it knows nothing about
## `SystemProfile`, `Resource`, `ProducerConsumerMap`, resource addresses,
## or `depends_on` syntax. Nodes are identified by INTEGER INDICES that
## the caller assigns; the caller keeps a parallel `addresses: seq[string]`
## (or whatever per-node payload it needs) and translates between indices
## and that payload at the adapter boundary.
##
## This split — generic kernel + per-scope adapter — replaces the
## previously-duplicated Kahn's + cycle-trace implementations in the two
## planners, which were nearly line-for-line identical and tracking the
## same fixes in lockstep.
##
## API:
##
##   * `EdgeKind`         — provenance enum (explicit `depends_on` vs.
##                          implicit producer / consumer fact); preserved
##                          here because cycle diagnostics need to tell
##                          the operator which kind of edge closed the
##                          cycle.
##   * `GraphEdge`        — `(fromIdx, toIdx, kind)`. Producer to consumer.
##   * `Graph`            — `nodeCount` + `edges`. Plain value type.
##   * `EGraphCycle`      — raised by `topologicallyOrder` when the graph
##                          contains a multi-node cycle. `cyclePath` is a
##                          closed sequence of node indices
##                          `@[n0, n1, ..., n0]` so the adapter can map
##                          it to the scope's per-node address strings.
##   * `addEdge`          — record `(fromIdx, toIdx, kind)` into the
##                          graph with explicit-promotion + dedupe; the
##                          caller is responsible for self-edge handling
##                          (see "self-edges" below).
##   * `topologicallyOrder` — Kahn's algorithm with declaration-index
##                          stable secondary order. Raises `EGraphCycle`
##                          (with `cyclePath` populated) on a multi-node
##                          cycle.
##   * `traceCycle`       — DFS returning a closed cycle path; `@[]` if
##                          the graph is acyclic. Reusable by adapters
##                          that want to surface a cycle without
##                          attempting an ordering.
##
## Self-edges:
## A self-edge (`A -> A`) is the caller's responsibility — the adapter
## resolves the source/destination indices and so already knows the
## offending node's address, which is the diagnostic the operator wants.
## `addEdge` therefore does NOT silently accept a self-edge: it would
## participate in the cycle but the caller has a strictly better
## diagnostic available BEFORE the index leaves the adapter layer.
## (Both existing scope adapters refuse self-edges at edge-build time
## with a typed exception naming the resource address; this module's
## generic exception is the wrong tool for that case.)

import std/[algorithm, sets, tables]

type
  EdgeKind* = enum
    ## Why an edge exists — surfaced in cycle diagnostics. The names
    ## come from the M82 Phase B planner contract (the original
    ## per-scope copies used the same names).
    edkExplicit = "explicit"             ## user-declared `depends_on`
    edkImplicit = "implicit"             ## producer / consumer map fact

  GraphEdge* = object
    ## A single producer-to-consumer ordering constraint.
    fromIdx*: int                        ## producer (apply earlier)
    toIdx*: int                          ## consumer (apply later)
    kind*: EdgeKind                      ## why this edge exists

  Graph* = object
    ## A dependency graph over `nodeCount` nodes identified by their
    ## integer index. Edges are kept in a flat seq; `addEdge` keeps the
    ## seq deduplicated by `(fromIdx, toIdx)` with explicit promotion,
    ## so iteration is well-defined regardless of the table's hash
    ## order. `topologicallyOrder` re-sorts edges by `(fromIdx, toIdx)`
    ## for deterministic adjacency-list construction.
    nodeCount*: int
    edges*: seq[GraphEdge]

  EGraphCycle* = object of CatchableError
    ## Raised by `topologicallyOrder` when a multi-node cycle prevents
    ## ordering every node. `cyclePath` is a CLOSED sequence of node
    ## indices — `@[n0, n1, ..., n0]` — so the adapter can render the
    ## scope-specific address strings for the operator-facing
    ## diagnostic. The exception's `msg` is intentionally generic
    ## ("dependency graph has a cycle"); the adapter typically rewraps
    ## with a scope-specific exception type carrying a string
    ## `cyclePath`.
    cyclePath*: seq[int]

proc addEdge*(g: var Graph; fromIdx, toIdx: int; kind: EdgeKind) =
  ## Record a producer-to-consumer edge. Deduplicates on
  ## `(fromIdx, toIdx)` so a pair that appears as BOTH an explicit
  ## `depends_on` AND an implicit producer / consumer fact is recorded
  ## once. The explicit kind wins when both are seen — a cycle that
  ## involves a user-declared edge should name the user's edge so the
  ## diagnostic guides them to the line they need to change.
  ##
  ## A self-edge (`fromIdx == toIdx`) is REFUSED by the caller's adapter
  ## BEFORE this proc sees it, because the adapter has the
  ## scope-specific address available to name the offender. This proc
  ## DOES accept the self-edge if passed (so the kernel stays
  ## type-blind), but every existing adapter raises before reaching
  ## here.
  for i in 0 ..< g.edges.len:
    if g.edges[i].fromIdx == fromIdx and g.edges[i].toIdx == toIdx:
      if kind == edkExplicit:
        g.edges[i].kind = edkExplicit
      return
  g.edges.add(GraphEdge(fromIdx: fromIdx, toIdx: toIdx, kind: kind))

proc traceCycle*(g: Graph): seq[int] =
  ## Return a CLOSED cycle path `@[n0, n1, ..., n0]` for any cycle in
  ## `g`, or `@[]` if the graph is acyclic. Used by `topologicallyOrder`
  ## to populate `EGraphCycle.cyclePath`, and exposed for adapters that
  ## want to test for a cycle without attempting an ordering.
  ##
  ## Implementation: iterative DFS over the nodes that still have
  ## non-zero in-degree (the survivors of a Kahn's pass — those are the
  ## nodes participating in cycles). The smallest declaration index that
  ## still has in-degree > 0 is the seed; the first edge that revisits a
  ## node on the current path closes the cycle. The path's prefix
  ## preceding that node is trimmed.
  if g.nodeCount == 0 or g.edges.len == 0:
    return @[]
  var inDegree = newSeq[int](g.nodeCount)
  var adj = newSeq[seq[int]](g.nodeCount)
  for e in g.edges:
    inc inDegree[e.toIdx]
    adj[e.fromIdx].add(e.toIdx)
  for i in 0 ..< adj.len:
    adj[i].sort()
  var start = -1
  for i in 0 ..< g.nodeCount:
    if inDegree[i] > 0:
      start = i
      break
  if start < 0:
    return @[]                             # acyclic
  var stack: seq[int] = @[start]
  var path: seq[int] = @[start]
  var onStack: HashSet[int]
  onStack.incl(start)
  var iters: Table[int, int]
  iters[start] = 0
  while stack.len > 0:
    let node = stack[^1]
    let nexts = adj[node]
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
        var cyclePath: seq[int]
        for k in cycleStart ..< path.len:
          cyclePath.add(path[k])
        cyclePath.add(nxt)
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

proc topologicallyOrder*(g: Graph): seq[int] =
  ## Return the node indices in apply order: every producer before
  ## every consumer; ties broken by declaration index (the stable
  ## secondary key). Kahn's algorithm with a sorted "ready set" keyed
  ## by node index — independent nodes keep their declaration order,
  ## which makes any per-node output stream byte-comparable across
  ## runs of the same input.
  ##
  ## Raises `EGraphCycle` with `cyclePath` populated (via `traceCycle`)
  ## when a multi-node cycle prevents ordering every node.
  let n = g.nodeCount
  var inDegree = newSeq[int](n)
  var outAdj = newSeq[seq[int]](n)
  # Sort edges so adjacency lists are deterministic regardless of the
  # caller's insertion order — `addEdge` does NOT enforce a sort.
  var edges = g.edges
  edges.sort(proc(a, b: GraphEdge): int =
    if a.fromIdx != b.fromIdx: cmp(a.fromIdx, b.fromIdx)
    else: cmp(a.toIdx, b.toIdx))
  for e in edges:
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
        # Insertion-sort to keep `ready` ordered by declaration index;
        # the smallest index pops next so secondary order is stable.
        var pos = ready.len
        for j in 0 ..< ready.len:
          if ready[j] > nxt:
            pos = j
            break
        ready.insert(nxt, pos)
  if result.len < n:
    var e = newException(EGraphCycle,
      "dependency graph has a cycle (refusing to order)")
    e.cyclePath = traceCycle(g)
    raise e
