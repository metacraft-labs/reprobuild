## DSL-port M8 acceptance — single-contributor ``fs.managedBlock``.
##
## Pins:
##
##   1. A single ``fs.managedBlock(...)`` call records a contribution in
##      the runtime sidecar keyed by ``path`` with the verbatim blockId,
##      scope, priority, and packageName.
##
##   2. ``mergedManagedBlockFile(path)`` renders the contribution with
##      the spec'd triple-form sentinels (``# >>> repro:<scope>:
##      <packageName>:<blockId> >>>``) per Generated-Configuration-Files.md
##      §"Sentinel uniqueness".
##
## The single-contributor case is the spec-shape-compatible base for the
## multi-contributor merge pinned by the sister fixture
## ``t_dsl_fs_managedblock_multi.nim``.

import std/[strutils, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

suite "DSL-port M8 — fs.managedBlock single contributor":

  test "managedBlock records contribution":
    resetDslPortFsState()

    fs.managedBlock(
      path = "/etc/ld.so.conf.d/00-test.conf",
      blockId = "libpaths",
      scope = bsSystem,
      content = "/opt/test/lib\n",
      priority = 500,
      packageName = "test-pkg"
    )

    let blocks = registeredManagedBlocks("/etc/ld.so.conf.d/00-test.conf")
    check blocks.len == 1
    check blocks[0].blockId == "libpaths"
    check blocks[0].scope == bsSystem
    check blocks[0].priority == 500
    check blocks[0].packageName == "test-pkg"

  test "merged file content has sentinel triple":
    resetDslPortFsState()

    fs.managedBlock(
      path = "/tmp/test.conf",
      blockId = "block1",
      scope = bsSystem,
      content = "line1\n",
      priority = 100,
      packageName = "pkg-a"
    )

    let merged = mergedManagedBlockFile("/tmp/test.conf")
    # Spec §"Sentinel uniqueness": triple-form open + close sentinels.
    check "# >>> repro:system:pkg-a:block1 >>>" in merged
    check "line1" in merged
    check "# <<< repro:system:pkg-a:block1 <<<" in merged
