## Spec-Implementation M5 — registry split verification.
##
## The M0 ``collect`` primitive landed as a thin alias over
## ``aggregate``; both wrote to the same ``BuildTargetDef`` registry.
## M5 splits the registries so the target-export-table v2 rows carry
## the right ``kind`` discriminator end-to-end per
## Build-Graph-Collections.md §"Persistence and the Target-Export
## Table".
##
## This test asserts:
##   1. ``collect("...", ...)`` writes to the parallel
##      ``collectionRegistry`` (visible through
##      ``registeredCollections``) and stamps its return value with
##      ``kind = btkCollection``.
##   2. ``aggregate("...", ...)`` keeps writing to the legacy
##      ``buildTargetRegistry`` (visible through
##      ``registeredAggregates``) and stamps its return value with
##      ``kind = btkAggregate``.
##   3. ``registeredBuildTargets`` returns the unioned view (so
##      downstream consumers that haven't yet opted into the
##      discriminator continue to see both kinds).
##   4. The two registries are independent — registering one does not
##      pollute the other; ``resetBuildTargetRegistry`` clears both
##      halves.
##   5. ``registerExplicitTargetExport`` propagates the discriminator:
##      a ``btkCollection`` ``BuildTargetDef`` writes a
##      ``tekCollection`` export-table row; a ``btkAggregate`` with
##      multiple action handles writes a ``tekAggregate`` row; a
##      ``btkTarget`` row and a decoded one-handle ``btkAggregate`` row
##      both write ``tekExplicit``.
##   6. ``target "name", action`` stamps ``btkTarget``, so a RENAME stays
##      distinguishable from a one-member GROUPING even though the two
##      produce the same ``actions`` / ``targets`` shape.

import std/unittest

import repro_project_dsl

suite "Spec-Implementation M5: collect / aggregate registry split":

  setup:
    resetBuildActionRegistry()
    resetBuildTargetRegistry()
    resetTargetExportRegistry()

  test "collect writes to the collection registry with btkCollection":
    let action = buildAction("act-1", publicCliCall("p", "tool", "", "ep", @[]))
    let collected = collect("test", actions = @[action])

    check collected.kind == btkCollection
    check collected.name == "test"

    check registeredCollections().len == 1
    check registeredCollections()[0].name == "test"
    check registeredCollections()[0].kind == btkCollection

    # The legacy half stays untouched.
    check registeredAggregates().len == 0

  test "aggregate writes to the legacy registry with btkAggregate":
    let actionA = buildAction("act-a", publicCliCall("p", "tool", "", "epA", @[]))
    let actionB = buildAction("act-b", publicCliCall("p", "tool", "", "epB", @[]))
    let aggregated = aggregate("docs", actions = @[actionA, actionB])

    check aggregated.kind == btkAggregate
    check aggregated.name == "docs"

    check registeredAggregates().len == 1
    check registeredAggregates()[0].name == "docs"
    check registeredAggregates()[0].kind == btkAggregate

    # The collection half stays untouched.
    check registeredCollections().len == 0

  test "registeredBuildTargets unions both halves":
    let action = buildAction("act-x", publicCliCall("p", "t", "", "ex", @[]))
    let actionY = buildAction("act-y", publicCliCall("p", "t", "", "ey", @[]))

    discard aggregate("docs", actions = @[action])
    discard collect("test", actions = @[actionY])

    let unioned = registeredBuildTargets()
    check unioned.len == 2

    # Aggregates first, then collections, both in declaration order.
    var sawAggregate = false
    var sawCollection = false
    for entry in unioned:
      if entry.name == "docs":
        check entry.kind == btkAggregate
        sawAggregate = true
      elif entry.name == "test":
        check entry.kind == btkCollection
        sawCollection = true
    check sawAggregate
    check sawCollection

  test "resetBuildTargetRegistry clears both halves":
    let action = buildAction("act-z", publicCliCall("p", "t", "", "ez", @[]))
    discard aggregate("docs", actions = @[action])
    discard collect("test", actions = @[action])

    check registeredAggregates().len == 1
    check registeredCollections().len == 1

    resetBuildTargetRegistry()

    check registeredAggregates().len == 0
    check registeredCollections().len == 0
    check registeredBuildTargets().len == 0

  test "registerExplicitTargetExport propagates the discriminator":
    # btkCollection → tekCollection
    let collectionTarget = BuildTargetDef(
      name: "test",
      actions: @["act-1"],
      kind: btkCollection)
    registerExplicitTargetExport(collectionTarget, "mypkg")

    # btkAggregate over multiple actions → tekAggregate
    let aggregateTarget = BuildTargetDef(
      name: "docs",
      actions: @["act-2", "act-3"],
      kind: btkAggregate)
    registerExplicitTargetExport(aggregateTarget, "mypkg")

    # btkAggregate with a single action / no nested targets is still
    # treated as ``tekExplicit``. This is now the DECODED-PAYLOAD path
    # rather than the registration path: ``BuildTargetKind`` zero-defaults
    # to ``btkAggregate``, so a v1 / v2 build-target payload written
    # before the ``kind`` byte existed arrives here indistinguishable from
    # a fresh ``aggregate`` call, and the shape test is what keeps its row
    # kind stable across a replay.
    let explicitTarget = BuildTargetDef(
      name: "release",
      actions: @["act-4"],
      kind: btkAggregate)
    registerExplicitTargetExport(explicitTarget, "mypkg")

    # btkTarget → tekExplicit. Freshly registered ``target "name", action``
    # rows carry their own discriminator, so the classification no longer
    # depends on a shape that ``aggregate("name", actions = @[one])``
    # produces identically.
    let stampedTarget = BuildTargetDef(
      name: "ship",
      actions: @["act-5"],
      kind: btkTarget)
    registerExplicitTargetExport(stampedTarget, "mypkg")

    let table = registeredTargetExports()
    check table.entries.len == 4

    var sawCollection = false
    var sawAggregate = false
    var sawExplicit = false
    var sawStamped = false
    for entry in table.entries:
      case entry.name
      of "test":
        check entry.kind == tekCollection
        sawCollection = true
      of "docs":
        check entry.kind == tekAggregate
        sawAggregate = true
      of "release":
        check entry.kind == tekExplicit
        sawExplicit = true
      of "ship":
        check entry.kind == tekExplicit
        sawStamped = true
      else: discard
    check sawCollection
    check sawAggregate
    check sawExplicit
    check sawStamped

  test "target stamps btkTarget, distinct from a one-member grouping":
    ## The two call shapes used to produce byte-identical payloads: one
    ## action, no nested targets, ``kind`` at its zero value. A consumer
    ## that has to tell a RENAME from a GROUPING — the graph linker, which
    ## mixes the chosen public name into the action's cache key — could
    ## not, so a recipe carrying both (CodeTracer's
    ## ``target("ct-binary", ct)`` beside
    ## ``aggregate("ct", actions = @[ct], targets = ctStartupAssets)``,
    ## whose startup assets are conditional and may be absent) was refused
    ## outright. The discriminator is what makes the pair decidable.
    let action = buildAction("act-1", publicCliCall("p", "t", "", "e1", @[]))

    let renamed = target("ct-binary", action)
    let grouped = aggregate("ct", actions = @[action])

    check renamed.kind == btkTarget
    check grouped.kind == btkAggregate

    # Same shape, different meaning — which is exactly why the shape
    # cannot be the discriminator.
    check renamed.actions == grouped.actions
    check renamed.targets.len == 0
    check grouped.targets.len == 0

    # Both still land in the legacy registry; the split is on ``kind``,
    # not on where the row is stored.
    check registeredAggregates().len == 2
    check registeredCollections().len == 0
