## DSL-port M8 acceptance — multi-contributor ``fs.managedBlock`` merge
## ordering + deletion semantics.
##
## Pins the load-bearing NDE-spec-block discipline from
## Generated-Configuration-Files.md:
##
##   1. **Multi-contributor sort order** (§"Block ordering rule"):
##      blocks emit in sorted ``(priority, packageName, blockId)`` order
##      ascending. The materialiser sorts at read time so the output is
##      INVARIANT to insertion order. The test deliberately registers
##      contributions in REVERSE sort order to prove the merger sorts
##      independently — a regression in the comparator would surface as
##      the recorded insertion order leaking into the merged output.
##
##   2. **Deletion semantics** (§"Deletion semantics"): removing one
##      contributor leaves the remaining contributions byte-identical in
##      the merged output. The test verifies BOTH:
##        (a) the removed contributor's bytes are absent, AND
##        (b) the surviving contributor's bytes are unchanged.
##
##      The "byte-identical" guarantee is what permits the spec'd cache
##      story — the surviving block's contribution hash hits the cache
##      after a sibling is deleted, so re-application is a no-op for the
##      unchanged contributors.

import std/[strutils, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

suite "DSL-port M8 — fs.managedBlock multi-contributor merge":

  test "multi-contributor sort order: priority asc, packageName asc":
    resetDslPortFsState()

    # Contributors deliberately added in REVERSE sort order to prove
    # the merger sorts independently of insertion order. Expected
    # post-sort order: graphics-stack (priority 100) FIRST, then the
    # three priority-500 contributors in packageName-ascending order
    # — gnome, plasma, sway.
    fs.managedBlock(
      path = "/tmp/multi.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "sway-paths\n",
      priority = 500,
      packageName = "sway"
    )
    fs.managedBlock(
      path = "/tmp/multi.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "plasma-paths\n",
      priority = 500,
      packageName = "plasma"
    )
    fs.managedBlock(
      path = "/tmp/multi.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "gnome-paths\n",
      priority = 500,
      packageName = "gnome"
    )
    fs.managedBlock(
      path = "/tmp/multi.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "foundation-paths\n",
      priority = 100,  # foundation -> earlier
      packageName = "graphics-stack"
    )

    let merged = mergedManagedBlockFile("/tmp/multi.conf")

    # Verify sort order: graphics-stack (priority 100) before all the
    # priority-500 contributors; the three priority-500 contributors in
    # packageName-ascending order.
    let idxGfx = merged.find("graphics-stack")
    let idxGnome = merged.find("gnome")
    let idxPlasma = merged.find("plasma")
    let idxSway = merged.find("sway")

    check idxGfx >= 0
    check idxGnome >= 0
    check idxPlasma >= 0
    check idxSway >= 0
    check idxGfx < idxGnome
    check idxGnome < idxPlasma
    check idxPlasma < idxSway

  test "deletion semantics: contributor removal preserves others":
    resetDslPortFsState()

    fs.managedBlock(
      path = "/tmp/del.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "A-content\n",
      priority = 500,
      packageName = "A"
    )
    fs.managedBlock(
      path = "/tmp/del.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "B-content\n",
      priority = 500,
      packageName = "B"
    )

    # Verify both present in the pre-delete merge.
    let mergedBoth = mergedManagedBlockFile("/tmp/del.conf")
    check "A-content" in mergedBoth
    check "B-content" in mergedBoth

    # Capture B's chunk from the pre-delete merge so the post-delete
    # output can be byte-compared against it (regression guard for the
    # spec §"Deletion semantics" "surviving blocks are byte-identical"
    # rule).
    let bOpen = managedBlockOpenSentinel(bsSystem, "B", "libpaths")
    let bClose = managedBlockCloseSentinel(bsSystem, "B", "libpaths")
    let bOpenIdx = mergedBoth.find(bOpen)
    let bCloseIdx = mergedBoth.find(bClose)
    check bOpenIdx >= 0
    check bCloseIdx > bOpenIdx
    let bChunkBefore = mergedBoth[bOpenIdx .. bCloseIdx + bClose.len - 1]

    # Remove A; B should be byte-identical to its prior chunk.
    removeManagedBlockContributor("/tmp/del.conf", scope = bsSystem,
                                  packageName = "A", blockId = "libpaths")
    let mergedAfterDelete = mergedManagedBlockFile("/tmp/del.conf")
    check "A-content" notin mergedAfterDelete
    check "B-content" in mergedAfterDelete

    # Byte-identical guarantee — B's chunk (sentinels + content) is
    # exactly the substring it occupied before A's removal. Spec
    # §"Deletion semantics".
    let bOpenIdx2 = mergedAfterDelete.find(bOpen)
    let bCloseIdx2 = mergedAfterDelete.find(bClose)
    check bOpenIdx2 >= 0
    check bCloseIdx2 > bOpenIdx2
    let bChunkAfter = mergedAfterDelete[bOpenIdx2 .. bCloseIdx2 + bClose.len - 1]
    check bChunkAfter == bChunkBefore
