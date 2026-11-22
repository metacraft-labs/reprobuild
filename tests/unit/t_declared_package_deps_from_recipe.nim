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
## 5. **The declarations are the COMPILED recipe's, never the work
##    directory's.** The engine compiles a consumer's recipe with its work
##    directory at reprobuild's checkout, and the reader used to scan
##    `<workDir>/repro.nim` -- reprobuild's recipe -- so a consumer's
##    `uses "<pkg>"` never reached the compile.
##    The flag routine is driven with a work directory whose own recipe
##    declares a DIFFERENT package, from a process cwd that is neither, and
##    must take the recipe's.
## 6. **The declared packages' sources join the recipe's source closure**, so
##    an edit to a module the recipe imports from a package re-keys every
##    compile of the recipe; and a recipe-relative compile names the
##    packages' directories relative to the recipe, so the workspace stays
##    relocatable.
##
## NO MOCKS: a real recipe file written to a real temp workspace, with real
## sibling directories created and omitted on disk.

import std/[os, unittest, strutils]
import repro_interface_artifacts

proc writeRecipe(dir, body: string; name = "repro.nim"): string =
  ## Writes the recipe and returns its path -- the reader's input is the
  ## recipe MODULE, not a directory.
  createDir(dir)
  result = dir / name
  writeFile(result, body)

suite "declared package dependencies":

  test "nested uses entries are packages; version requirements are not":
    let root = getTempDir() / "repro-declared-deps-mixed"
    removeDir(root)
    let proj = root / "consumer"
    let recipe = writeRecipe(proj, """
package consumer:
  uses:
    "nim >=2.0"
    "ffmpeg >=7.0"
    "python3 >=3.10"
    uses: "GuiAssert"
    uses: "gosti"
""")
    let deps = declaredPackageDeps(recipe)
    # The two nested entries, in declaration order.
    check deps == @["GuiAssert", "gosti"]
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
    let recipe = writeRecipe(proj, """
package consumer:
  uses:
    uses: "nim>=2.0"
    uses: "zstd<2"
    uses: "openssl=3.0.0"
    uses: "RealPackage"
""")
    let deps = declaredPackageDeps(recipe)
    check deps == @["RealPackage"]
    check "nim>=2.0" notin deps
    check "zstd<2" notin deps
    check "openssl=3.0.0" notin deps
    removeDir(root)

  test "comments never contribute a dependency":
    let root = getTempDir() / "repro-declared-deps-comments"
    removeDir(root)
    let proj = root / "consumer"
    let recipe = writeRecipe(proj, """
package consumer:
  uses:
    # uses: "CommentedOut"
    uses: "Real"   # a trailing comment must not hide the real one
""")
    let deps = declaredPackageDeps(recipe)
    check deps == @["Real"]
    check "CommentedOut" notin deps
    removeDir(root)

  test "a repeated declaration contributes once, in first-seen order":
    let root = getTempDir() / "repro-declared-deps-dup"
    removeDir(root)
    let proj = root / "consumer"
    let recipe = writeRecipe(proj, """
package consumer:
  uses:
    uses: "Alpha"
    uses: "Beta"
    uses: "Alpha"
""")
    check declaredPackageDeps(recipe) == @["Alpha", "Beta"]
    removeDir(root)

  test "roots resolve checked-out siblings and skip absent ones":
    let root = getTempDir() / "repro-declared-deps-roots"
    removeDir(root)
    let proj = root / "consumer"
    let recipe = writeRecipe(proj, """
package consumer:
  uses:
    uses: "PresentPkg"
    uses: "AbsentPkg"
""")
    # Only one of the two is actually checked out next to the consumer.
    createDir(root / "PresentPkg")

    let roots = declaredPackageRoots(recipe)
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
    check declaredPackageDeps(root / "repro.nim").len == 0
    check declaredPackageRoots(root / "repro.nim").len == 0
    check declaredPackagePathDirs(root / "repro.nim").len == 0
    removeDir(root)

  test "the compiled recipe's declarations reach the flags, not the work directory's":
    # DISCRIMINATING CASE for the issue. The work directory carries a recipe
    # of its own that declares `WrongPkg` (checked out), and the recipe being
    # compiled -- in another directory, under a name that is not repro.nim
    # -- declares `RightPkg`. The process cwd is a third directory. Reading
    # `<workDir>/repro.nim` (the defect) puts WrongPkg on the path and not
    # RightPkg; reading the recipe relative to the cwd finds nothing.
    let root = getTempDir() / "repro-declared-deps-recipe-not-workdir"
    removeDir(root)
    let work = root / "engine-work"
    discard writeRecipe(work, """
package engine:
  uses:
    uses: "WrongPkg"
""")
    createDir(root / "WrongPkg" / "src")
    let consumer = root / "ws" / "consumer"
    let recipe = writeRecipe(consumer, """
import right_module
package consumer:
  uses:
    uses: "RightPkg"
""", name = "recipe_module.nim")
    createDir(root / "ws" / "RightPkg" / "src")
    writeFile(root / "ws" / "RightPkg" / "src" / "right_module.nim",
      "const rightValue* = 1\n")
    let elsewhere = root / "cwd"
    createDir(elsewhere)
    let saved = getCurrentDir()
    setCurrentDir(elsewhere)
    defer: setCurrentDir(saved)

    let flags = consumerCompilePathFlags(work, recipe)
    let rightRoot = os.normalizedPath(root / "ws" / "RightPkg")
    check ("--path:" & rightRoot) in flags
    check ("--path:" & rightRoot / "src") in flags
    for flag in flags:
      check "WrongPkg" notin flag
    # Without a recipe nothing is declared: the work directory's own recipe
    # is never consulted.
    for flag in consumerCompilePathFlags(work):
      check "WrongPkg" notin flag
      check "RightPkg" notin flag
    # The directories, in declaration order: root, then its src.
    check declaredPackagePathDirs(recipe) == @[rightRoot, rightRoot / "src"]
    removeDir(root)

  test "the declared packages' sources are in the recipe's source closure":
    let root = getTempDir() / "repro-declared-deps-closure"
    removeDir(root)
    let pkg = root / "sharedpkg"
    createDir(pkg / "src" / "nested")
    createDir(pkg / "policy")
    # The package's own recipe imports a module outside src: the workspace
    # producer import brings that recipe into the consumer, so its closure
    # counts too.
    writeFile(pkg / "repro.nim", "import ./policy/pkg_policy\npackage sharedpkg:\n  discard\n")
    writeFile(pkg / "policy" / "pkg_policy.nim", "const p* = 1\n")
    writeFile(pkg / "src" / "shared_module.nim",
      "import nested/helper\nconst greeting* = helperValue\n")
    writeFile(pkg / "src" / "nested" / "helper.nim", "const helperValue* = \"v1\"\n")
    # Not under src and not imported: not something the recipe compiles.
    createDir(pkg / "tests")
    writeFile(pkg / "tests" / "t_shared.nim", "discard\n")
    let recipe = writeRecipe(root / "consumer", """
import shared_module
package consumer:
  uses:
    uses: "sharedpkg"
""")
    let closure = recipeSourceClosure(recipe)
    proc has(path: string): bool =
      os.normalizedPath(path).replace('\\', '/') in closure
    check has(recipe)
    check has(pkg / "src" / "shared_module.nim")
    check has(pkg / "src" / "nested" / "helper.nim")
    check has(pkg / "repro.nim")
    check has(pkg / "policy" / "pkg_policy.nim")
    check not has(pkg / "tests" / "t_shared.nim")
    # Without the declaration the package is not part of the closure: the
    # membership comes from the declaration, not from a directory census.
    let undeclared = writeRecipe(root / "other", "import shared_module\n" &
      "package other:\n  discard\n")
    let otherClosure = recipeSourceClosure(undeclared)
    check (os.normalizedPath(pkg / "src" / "shared_module.nim").replace(
      '\\', '/')) notin otherClosure
    removeDir(root)

  test "a recipe-relative compile names the declared packages relative to the recipe":
    let root = getTempDir() / "repro-declared-deps-relative"
    removeDir(root)
    createDir(root / "sharedpkg" / "src")
    let recipe = writeRecipe(root / "consumer", """
package consumer:
  uses:
    uses: "sharedpkg"
""")
    let pkgRoot = os.normalizedPath(root / "sharedpkg")
    let command = @["nim", "c", "--path:/nix/store/x-lib",
      "--path:" & parentDir(recipe), "--path:" & pkgRoot,
      "--path:" & pkgRoot / "src", recipe]
    check recipeRelativeCompileArgs(command, recipe) == @["nim", "c",
      "--path:/nix/store/x-lib", "--path:.", "--path:../sharedpkg",
      "--path:../sharedpkg/src", "repro.nim"]
    removeDir(root)
