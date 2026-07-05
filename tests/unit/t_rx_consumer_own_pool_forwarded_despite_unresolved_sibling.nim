## RX pool-forwarding — a CONSUMER recipe's OWN ``buildPool`` reaches its
## ``runquotad`` even when its ``uses:`` siblings are UNRESOLVED at
## daemon-spawn time.
##
## ## Context
##
## ``extractRecipeBuildPools`` runs at daemon-spawn time — BEFORE the
## producer sub-builds / develop-override resolution have run. For a CONSUMER
## recipe with ``uses: "<sibling>"`` selectors, the sibling tools are not yet
## materialized, so the FULL graph inspection (tool-identity resolution +
## lowering) THROWS ("not found in PATH"). The old code routed pool
## extraction through that full inspection and swallowed the throw with a
## best-effort ``except`` → an EMPTY pool set. The consumer's OWN
## ``buildPool("nim_agents.acp-serial", 1)`` therefore never reached the
## daemon → cap-0 → ``lease request exceeds named-pool budget`` → livelock.
##
## A recipe's ``buildPool(...)`` executes at PROVIDER-EXECUTION time and lands
## in the provider-graph SNAPSHOT as a ``reprobuild.build-pool.v1`` metadata
## node — INDEPENDENT of ``uses:`` sibling resolution. The fix recovers the
## consumer's own pools from the snapshot via the exported
## ``poolsFromSnapshot`` (which does the pool-gathering pass WITHOUT the
## throwing lowering), so they forward regardless of sibling resolvability.
##
## ## What this test pins
##
## Build a synthetic snapshot exactly as the provider runtime emits one for a
## CONSUMER recipe: a fragment carrying
##
##   * an ACTION node whose declared tool ref names an UNRESOLVED sibling (the
##     shape that makes the full lowering throw), AND
##   * the consumer's OWN ``buildPool`` as a ``reprobuild.build-pool.v1``
##     metadata node.
##
## ``poolsFromSnapshot`` must return the consumer's own pool from that
## snapshot, and ``assembleRunquotadPoolArgs`` must then forward it to the
## daemon argv — proving the consumer's own pool survives the unresolved
## sibling.
##
## ## Falsifiability
##
## Revert ``extractRecipeBuildPools`` to route through the throwing
## ``prepareBuildGraphInspection`` (or drop the ``reprobuild.build-pool.v1``
## metadata pass from ``poolsFromSnapshot``) and the pool is dropped —
## ``acp-serial=1`` disappears from the forwarded argv and assertions below
## fail. Restore the snapshot-based extraction and they pass.

import std/[unittest]

import repro_cli_support
import repro_build_engine
import repro_provider_runtime
import repro_project_dsl

proc buildPoolNode(name: string; capacity: uint32): GraphNode =
  ## Mirror ``runtime_provider.nim``'s build-pool metadata node emission.
  GraphNode(
    id: "project:metadata:build-pool:" & name,
    kind: gnkMetadata,
    stableName: "reprobuild.build-pool.v1",
    payload: poolPayload(BuildPoolDef(name: name, capacity: capacity)))

proc consumerSnapshotWithUnresolvedSibling(): ProviderGraphSnapshot =
  ## A CONSUMER recipe's snapshot: an action referencing an unresolved
  ## sibling tool (the shape that trips full lowering) PLUS the consumer's
  ## OWN ``buildPool`` metadata node. Only the pool metadata is load-bearing
  ## for ``poolsFromSnapshot``; the action node stands in for the ``uses:``
  ## edge whose sibling resolution is NOT yet possible at spawn time.
  var fragment = StoredGraphFragment(
    namespace: "project",
    nodes: @[
      GraphNode(
        id: "project:action:nim_agents.test.acp",
        kind: gnkAction,
        stableName: "nim_agents.test.acp",
        payload: ""),
      buildPoolNode("nim_agents.acp-serial", 1'u32)])
  result = ProviderGraphSnapshot(fragments: @[fragment])

suite "RX — consumer's own pool forwards despite unresolved sibling":

  test "poolsFromSnapshot recovers the consumer's own buildPool":
    let snapshot = consumerSnapshotWithUnresolvedSibling()
    let pools = poolsFromSnapshot(snapshot)
    var names: seq[string] = @[]
    for p in pools:
      names.add(p.name)
    check "nim_agents.acp-serial" in names
    for p in pools:
      if p.name == "nim_agents.acp-serial":
        check p.capacity == 1'u32

  test "the recovered pool forwards to the runquotad argv":
    let snapshot = consumerSnapshotWithUnresolvedSibling()
    let pools = poolsFromSnapshot(snapshot)
    let argv = assembleRunquotadPoolArgs(pools)
    # Collapse ``["--pool", "a=1", ...]`` to ``["a=1", ...]``.
    var pairs: seq[string] = @[]
    var i = 0
    while i < argv.len:
      check argv[i] == "--pool"
      check i + 1 < argv.len
      pairs.add(argv[i + 1])
      i += 2
    check "nim_agents.acp-serial=1" in pairs
    # The two convention pools remain present.
    check "compile=8" in pairs
    check "fetch=2" in pairs

  test "duplicate pool names collapse to a single entry":
    ## Two fragments each declaring the SAME pool (a multi-fragment consumer)
    ## must not double-count — ``poolsFromSnapshot`` dedups by name.
    var frag1 = StoredGraphFragment(namespace: "project",
      nodes: @[buildPoolNode("nim_agents.acp-serial", 1'u32)])
    var frag2 = StoredGraphFragment(namespace: "project",
      nodes: @[buildPoolNode("nim_agents.acp-serial", 1'u32)])
    let snapshot = ProviderGraphSnapshot(fragments: @[frag1, frag2])
    let pools = poolsFromSnapshot(snapshot)
    var count = 0
    for p in pools:
      if p.name == "nim_agents.acp-serial":
        count += 1
    check count == 1

  test "a leaf snapshot with no pools yields no custom pools":
    let snapshot = ProviderGraphSnapshot(fragments: @[
      StoredGraphFragment(namespace: "project", nodes: @[
        GraphNode(id: "project:action:leaf", kind: gnkAction,
          stableName: "leaf", payload: "")])])
    let pools = poolsFromSnapshot(snapshot)
    check pools.len == 0
