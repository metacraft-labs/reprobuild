## Spec-Implementation M5 — build-report ``targetResolution`` carries
## the new ``targetKind`` field for ``trkResolved`` records.
##
## Per Build-Graph-Collections.md §"Persistence and the Target-Export
## Table" and the registry split documented in this milestone, the
## CLI resolver's ``TargetResolutionRecord`` now records which
## ``TargetExportKind`` the row was — one of ``implicit`` /
## ``explicit`` / ``aggregate`` / ``collection``. The build report
## (``writeBuildReport`` in ``repro_cli_support.nim``) serialises the
## field under ``"targetKind"`` on each ``trkResolved`` entry.
##
## Asserts:
##   1. ``resolveTargetExportSelector`` returns the matching entry's
##      ``kind`` in the ``targetKind`` field for each of the four
##      kinds.
##   2. The ``trkResolved`` record's ``targetKind`` is propagated even
##      when the resolver picked a ``tekCollection`` row that shadows
##      a same-name implicit entry (the bare-name path's shadowing
##      rule per Build-Graph-Collections.md §"Naming").
##   3. Pass-through action-id / explicit-name resolutions report
##      ``tekImplicit`` / ``tekExplicit`` respectively so the field is
##      always populated for ``trkResolved`` outcomes.

import std/unittest

import repro_project_dsl
import repro_cli_support

suite "Spec-Implementation M5: build report targetResolution kind":

  test "resolver returns targetKind for each export-row kind":
    let table = TargetExportTable(
      entries: @[
        TargetExportEntry(
          name: "implicit-out",
          kind: tekImplicit,
          owningPackage: "pkg",
          actionId: "act-1"),
        TargetExportEntry(
          name: "release",
          kind: tekExplicit,
          owningPackage: "pkg",
          actionId: "act-2"),
        TargetExportEntry(
          name: "docs",
          kind: tekAggregate,
          owningPackage: "pkg",
          actionId: "act-3"),
        TargetExportEntry(
          name: "test",
          kind: tekCollection,
          owningPackage: "pkg",
          actionId: "act-4"),
      ])

    let r1 = resolveTargetExportSelector(table, @[], @[], "implicit-out")
    let r2 = resolveTargetExportSelector(table, @[], @[], "release")
    let r3 = resolveTargetExportSelector(table, @[], @[], "docs")
    let r4 = resolveTargetExportSelector(table, @[], @[], "test")

    check r1.kind == trkResolved
    check r1.targetKind == tekImplicit
    check r1.actionId == "act-1"

    check r2.kind == trkResolved
    check r2.targetKind == tekExplicit
    check r2.actionId == "act-2"

    check r3.kind == trkResolved
    check r3.targetKind == tekAggregate
    check r3.actionId == "act-3"

    check r4.kind == trkResolved
    check r4.targetKind == tekCollection
    check r4.actionId == "act-4"

  test "collection row shadows same-name implicit row":
    # Build-Graph-Collections.md §"Naming": a bare name that resolves
    # to BOTH a collection and a same-name implicit edge resolves to
    # the collection.
    let table = TargetExportTable(
      entries: @[
        TargetExportEntry(
          name: "test",
          kind: tekImplicit,
          owningPackage: "pkg",
          actionId: "act-impl"),
        TargetExportEntry(
          name: "test",
          kind: tekCollection,
          owningPackage: "pkg",
          actionId: "act-coll"),
      ])

    let r = resolveTargetExportSelector(table, @[], @[], "test")
    check r.kind == trkResolved
    check r.targetKind == tekCollection
    check r.actionId == "act-coll"

  test "qualified resolution preserves targetKind":
    let table = TargetExportTable(
      entries: @[
        TargetExportEntry(
          name: "test",
          kind: tekCollection,
          owningPackage: "myFrontend",
          actionId: "act-fe"),
        TargetExportEntry(
          name: "test",
          kind: tekCollection,
          owningPackage: "myBackend",
          actionId: "act-be"),
      ])

    let r = resolveTargetExportSelector(table, @[], @[], "myFrontend:test")
    check r.kind == trkResolved
    check r.owningPackage == "myFrontend"
    check r.targetKind == tekCollection
    check r.actionId == "act-fe"

  test "pass-through action-id reports tekImplicit, explicit name reports tekExplicit":
    let table = TargetExportTable()
    let r1 = resolveTargetExportSelector(table,
      @["my-action"], @[], "my-action")
    let r2 = resolveTargetExportSelector(table,
      @[], @["my-explicit-target"], "my-explicit-target")

    check r1.kind == trkResolved
    check r1.targetKind == tekImplicit  # action-id pass-through default
    check r1.actionId == "my-action"

    check r2.kind == trkResolved
    check r2.targetKind == tekExplicit
    check r2.actionId == "my-explicit-target"
