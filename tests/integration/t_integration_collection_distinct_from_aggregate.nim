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
##      plain ``target "name", action`` (one handle, no nested
##      targets, default ``btkAggregate``) writes ``tekExplicit``.

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

    # btkAggregate with a single action / no nested targets — the
    # zero-value of the discriminator for plain ``target "name", action``
    # — is still treated as ``tekExplicit`` so the on-disk row shape
    # matches the M0 / M1 record convention.
    let explicitTarget = BuildTargetDef(
      name: "release",
      actions: @["act-4"],
      kind: btkAggregate)
    registerExplicitTargetExport(explicitTarget, "mypkg")

    let table = registeredTargetExports()
    check table.entries.len == 3

    var sawCollection = false
    var sawAggregate = false
    var sawExplicit = false
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
      else: discard
    check sawCollection
    check sawAggregate
    check sawExplicit
