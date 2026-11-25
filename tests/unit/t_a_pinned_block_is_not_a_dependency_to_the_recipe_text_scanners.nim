## The two places that read a recipe's `uses:` lines as TEXT do not mistake a
## `pinned:` block for dependencies (Unified-Locking-And-Hooks.md §14.2 item 4).
##
##   * `scanReproUsesDeclarations` (recipe/lock consistency, `repro add` /
##     `remove`): reads version constraints of dependency blocks. A pinned
##     entry is a repository name with no constraint; read as a `uses:` entry
##     it would be compared against a lock's resolved versions and reported as
##     "resolves no package for codetracer".
##   * `declaredPackageDeps` (the `--path:` flags of a recipe compile): reads
##     nested `uses "<name>"` entries as Nim packages to put on the path. A
##     pinned sibling is cloned, not imported, so it must not appear there.
##
## Both are pure text readers, so the test drives the real procs over real
## recipe text and real files. No mocks.

import std/[os, unittest]

import repro_cli_support/recipe_constraints
import repro_interface_artifacts

const Recipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.2 <3.0"
  pinned:
    "codetracer"
    "codetracer-vscode-extension"
"""

suite "a pinned block among the recipe's text scanners":

  test "the constraint scan sees the uses entry and none of the pins":
    let entries = scanReproUsesDeclarations(Recipe)
    check entries.len == 1
    check entries[0].rawConstraint == "nim >=2.2 <3.0"
    check entries[0].blockHead == "uses"

  test "the package-path scan names no pinned sibling":
    let root = getTempDir() / ("pinned-scan-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let recipe = root / "repro.nim"
    writeFile(recipe, Recipe)
    check declaredPackageDeps(recipe).len == 0
