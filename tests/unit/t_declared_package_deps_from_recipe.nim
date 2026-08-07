## Declared package dependencies (`uses "<name>"`) read out of a recipe.
##
## ## Why this is read textually
##
## The `uses` declarations live INSIDE `repro.nim`, but the `--path:` flags
## they imply are needed to COMPILE that same file. Nothing here may depend on
## having evaluated the recipe first, so the reader is a line scanner — the
## same bootstrap `discoverNimSources` already uses to build the
## provider-compile source closure without a semantic pass.
##
## ## What this pins, and why each case exists
##
## 1. **A nested `uses "x"` is a package; a bare version string is not.**
##    A `uses:` block mixes both — `"nim >=2.0"` and `"ffmpeg >=7.0"` are
##    tool/version requirements naming no Nim package. Treating one as a
##    package would put `ffmpeg` on the Nim path, and the resulting failure
##    ("cannot open file: ffmpeg") points nowhere near the cause.
## 2. **Comments are not declarations.** A commented-out `uses` line, or a
##    trailing comment after a real one, must not change the result. Recipes
##    are edited by humans and both forms occur.
## 3. **Order and uniqueness.** Declaration order is preserved (it decides
##    `--path:` precedence) and a repeated declaration contributes once.
## 4. **An absent checkout is skipped, not an error.** `declaredPackageRoots`
##    resolves against the workspace and drops what is not there, so the
##    recipe compile reports the unresolved import with a real file and line
##    instead of this layer failing with a directory name.
##
## NO MOCKS: a real recipe file written to a real temp workspace, with real
## sibling directories created and omitted on disk.

import std/[os, unittest, strutils]
import repro_interface_artifacts

proc writeRecipe(dir, body: string) =
  createDir(dir)
  writeFile(dir / "repro.nim", body)

suite "declared package dependencies":

  test "nested uses entries are packages; version requirements are not":
    let root = getTempDir() / "repro-declared-deps-mixed"
    removeDir(root)
    let proj = root / "consumer"
    writeRecipe(proj, """
package consumer:
  uses:
    "nim >=2.0"
    "ffmpeg >=7.0"
    "python3 >=3.10"
    uses: "GuiAssert"
    uses: "vm-harness"
""")
    let deps = declaredPackageDeps(proj)
    # The two nested entries, in declaration order.
    check deps == @["GuiAssert", "vm-harness"]
    # ...and emphatically NOT the tool requirements: a bare version string
    # names no importable Nim package.
    check "ffmpeg" notin deps
    check "nim" notin deps
    check "python3" notin deps
    removeDir(root)

  test "a version constraint written without spaces is still not a package":
    # DISCRIMINATING CASE, and it took two attempts to write.
    #
    # Bare strings in a `uses:` block ("nim >=2.0") never reach the
    # version-operator guard at all -- the scanner only examines lines
    # beginning with `uses`. And the spaced NESTED form is rejected by the
    # no-space rule first. So the guard is reachable ONLY through a nested
    # entry carrying a version and no space, which is what this pins:
    # mutating the operator guard away leaves every other case in this
    # suite green.
    let root = getTempDir() / "repro-declared-deps-tightversion"
    removeDir(root)
    let proj = root / "consumer"
    writeRecipe(proj, """
package consumer:
  uses:
    uses: "nim>=2.0"
    uses: "zstd<2"
    uses: "openssl=3.0.0"
    uses: "RealPackage"
""")
    let deps = declaredPackageDeps(proj)
    check deps == @["RealPackage"]
    check "nim>=2.0" notin deps
    check "zstd<2" notin deps
    check "openssl=3.0.0" notin deps
    removeDir(root)

  test "comments never contribute a dependency":
    let root = getTempDir() / "repro-declared-deps-comments"
    removeDir(root)
    let proj = root / "consumer"
    writeRecipe(proj, """
package consumer:
  uses:
    # uses: "CommentedOut"
    uses: "Real"   # a trailing comment must not hide the real one
""")
    let deps = declaredPackageDeps(proj)
    check deps == @["Real"]
    check "CommentedOut" notin deps
    removeDir(root)

  test "a repeated declaration contributes once, in first-seen order":
    let root = getTempDir() / "repro-declared-deps-dup"
    removeDir(root)
    let proj = root / "consumer"
    writeRecipe(proj, """
package consumer:
  uses:
    uses: "Alpha"
    uses: "Beta"
    uses: "Alpha"
""")
    check declaredPackageDeps(proj) == @["Alpha", "Beta"]
    removeDir(root)

  test "roots resolve checked-out siblings and skip absent ones":
    let root = getTempDir() / "repro-declared-deps-roots"
    removeDir(root)
    let proj = root / "consumer"
    writeRecipe(proj, """
package consumer:
  uses:
    uses: "PresentPkg"
    uses: "AbsentPkg"
""")
    # Only one of the two is actually checked out next to the consumer.
    createDir(root / "PresentPkg")

    let roots = declaredPackageRoots(proj)
    check roots.len == 1
    check roots[0].endsWith("PresentPkg")
    # The absent one is dropped HERE on purpose: the recipe compile that
    # follows names the unresolved import with a file and line, which is a
    # far better diagnostic than a path-assembly error naming a directory.
    for r in roots:
      check not r.endsWith("AbsentPkg")
    removeDir(root)

  test "a recipe-less directory declares nothing":
    let root = getTempDir() / "repro-declared-deps-norecipe"
    removeDir(root)
    createDir(root)
    check declaredPackageDeps(root).len == 0
    check declaredPackageRoots(root).len == 0
    removeDir(root)
