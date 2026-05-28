## Unit tests for the `repro_core` shared graph kernel (M82 DRY
## refactor). The kernel is domain-blind — it operates over integer
## node indices — so these tests exercise it directly without any
## system-profile / home-profile setup. The scope-specific behaviors
## (cycle exception types, address-string rendering, `depends_on`
## resolution) are pinned by the system and home smoke suites which
## also exercise the kernel transitively through their adapters.

import std/[strutils, unittest]

import repro_core

suite "repro_core.dep_graph: edge dedupe + explicit promotion":

  test "addEdge dedupes a duplicate (fromIdx, toIdx) pair":
    # The shared kernel is the layer that collapses a `(from, to)`
    # pair seen TWICE (once from explicit `depends_on`, once from the
    # producer / consumer map) into ONE edge. Without this the cycle
    # detector would still find the right cycles but the graph's edge
    # count would diverge from the visible-to-the-operator edge count.
    var g = Graph(nodeCount: 3)
    addEdge(g, 0, 1, edkExplicit)
    addEdge(g, 0, 1, edkExplicit)
    addEdge(g, 0, 1, edkImplicit)
    check g.edges.len == 1
    check g.edges[0].fromIdx == 0
    check g.edges[0].toIdx == 1

  test "addEdge promotes implicit to explicit when both kinds exist":
    # Diagnostic-attribution rule: if the user wrote a `depends_on`
    # AND the producer / consumer map would have inferred the same
    # edge, the cycle error should NAME the user's edge (the line
    # they can edit). The shared kernel enforces "explicit wins" so
    # the adapter doesn't have to.
    var g = Graph(nodeCount: 2)
    addEdge(g, 0, 1, edkImplicit)
    check g.edges[0].kind == edkImplicit
    addEdge(g, 0, 1, edkExplicit)
    check g.edges.len == 1
    check g.edges[0].kind == edkExplicit
    # Once explicit, a subsequent implicit must NOT demote it.
    addEdge(g, 0, 1, edkImplicit)
    check g.edges[0].kind == edkExplicit

suite "repro_core.dep_graph: topologicallyOrder":

  test "stable secondary order for independent nodes (declaration order)":
    # Three nodes, no edges — the ready set is the full node set; the
    # sort must emit them in declaration-index order so the per-node
    # downstream stream (e.g. RBIP plan operations) is byte-comparable
    # across runs of the same input.
    var g = Graph(nodeCount: 3)
    let order = topologicallyOrder(g)
    check order == @[0, 1, 2]

  test "respects an explicit multi-hop chain":
    # Edges: 3 -> 2 -> 1 -> 0. Declared backwards on purpose; the
    # topological sort must emit 0, 1, 2, 3 — producer before
    # consumer in EVERY pair.
    var g = Graph(nodeCount: 4)
    addEdge(g, 0, 1, edkExplicit)
    addEdge(g, 1, 2, edkExplicit)
    addEdge(g, 2, 3, edkExplicit)
    let order = topologicallyOrder(g)
    check order == @[0, 1, 2, 3]

  test "two-node cycle: cyclePath reports the closed loop":
    # A -> B -> A. The cycle detector must return @[0, 1, 0]
    # (closed) so the adapter can render the address pair with the
    # closing repetition.
    var g = Graph(nodeCount: 2)
    addEdge(g, 0, 1, edkExplicit)
    addEdge(g, 1, 0, edkExplicit)
    var raised = false
    try:
      discard topologicallyOrder(g)
    except EGraphCycle as e:
      raised = true
      check e.cyclePath.len == 3
      check e.cyclePath[0] == e.cyclePath[^1]
      let firstHalf = e.cyclePath[0 ..< 2]
      check 0 in firstHalf
      check 1 in firstHalf
      check e.msg.toLowerAscii().contains("cycle")
    check raised

  test "three-node cycle: cyclePath reports the closed loop":
    # A -> B -> C -> A. The closed cyclePath has length 4 with first
    # == last; all three node indices appear in the prefix.
    var g = Graph(nodeCount: 3)
    addEdge(g, 0, 1, edkExplicit)
    addEdge(g, 1, 2, edkExplicit)
    addEdge(g, 2, 0, edkExplicit)
    var raised = false
    try:
      discard topologicallyOrder(g)
    except EGraphCycle as e:
      raised = true
      check e.cyclePath.len == 4
      check e.cyclePath[0] == e.cyclePath[^1]
      let firstHalf = e.cyclePath[0 ..< 3]
      check 0 in firstHalf
      check 1 in firstHalf
      check 2 in firstHalf
    check raised

  test "traceCycle returns @[] for an acyclic graph":
    # The DFS helper is exported for adapters that want to test a
    # graph without attempting an ordering. An acyclic graph yields
    # the empty seq — the contract `topologicallyOrder` relies on
    # to distinguish "no cycle survived Kahn's" from "cycle found".
    var g = Graph(nodeCount: 3)
    addEdge(g, 0, 1, edkExplicit)
    addEdge(g, 0, 2, edkImplicit)
    let emptyPath: seq[int] = @[]
    check traceCycle(g) == emptyPath
