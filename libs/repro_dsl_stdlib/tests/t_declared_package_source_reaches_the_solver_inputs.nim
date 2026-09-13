## A recipe can declare WHERE a dependency's realized artifact comes from,
## and that declaration reaches the solver inputs the committed lock is
## written from.
##
## THE GAP THIS CLOSES, MEASURED. `repro_lock` has carried MO-11's lift since
## MO-11 landed: a solved package whose `source` is `"store"` is lifted into
## `deps` as a `LockedDep` with `ckStore` coordinates and a `blake3:<addr>`
## integrity, and `parseExplainFixture` reads a `source:` directive out of a
## `repro.solver` sidecar into `PackageDecl.source`. But `buildPackageDecls`
## — the path EVERY compiled recipe takes — built its `PackageDecl`s with
## `newPackage` / `newPinnedPackage` and never set `source` at all. So the
## lock format could express a store coordinate, the lift could produce one,
## the sidecar could ask for one, and the recipe language could not. A
## project could say `uses: "reprobuild >=0.1.4"` and the resulting lock
## recorded a version with no coordinate, which is not something a resolver
## can act on.
##
## `packageSource` is the recipe-side spelling. This suite pins both halves:
## the declaration reaches the rendered solver inputs, and WITHOUT it the
## same declarations render without a `source:` line — so the assertion is
## about the declaration rather than about a renderer that always emits one.
##
## Test-double policy: no mocks. The real `registerSolverDependency` /
## `packageSource` registration surface and the real
## `currentSolverInputsFixture`, which renders through the same
## `renderSolverInputsFixture` that `finalizeVariants()` writes to
## `REPRO_EMIT_SOLVER_INPUTS` and that `repro lock refresh` parses back.

import std/[strutils, unittest]

import repro_dsl_stdlib/configurables

proc blockFor(fixture, packageName: string): string =
  ## The `package <name>` block of a rendered fixture, or "" when absent.
  var collecting = false
  for line in fixture.splitLines():
    if line.startsWith("package "):
      collecting = line.strip() == "package " & packageName
      if collecting:
        result.add(line & "\n")
      continue
    if collecting:
      if line.strip().len == 0:
        break
      result.add(line & "\n")

suite "a declared package source reaches the solver inputs":

  setup:
    resetVariantState()

  teardown:
    resetVariantState()

  test "without a declaration the dependency renders no source line":
    registerSolverDependency("app", "reprobuild", "reprobuild >=0.1.4")
    let rendered = currentSolverInputsFixture()
    let blk = blockFor(rendered, "reprobuild")
    check blk.contains("versions: 0.1.4")
    check not blk.contains("source:")

  test "packageSource store renders `source: store` on that package":
    registerSolverDependency("app", "reprobuild", "reprobuild >=0.1.4")
    packageSource("reprobuild", "store")
    let rendered = currentSolverInputsFixture()
    let blk = blockFor(rendered, "reprobuild")
    check blk.contains("versions: 0.1.4")
    check blk.contains("source: store")

  test "the declaration is per-package, not global":
    registerSolverDependency("app", "reprobuild", "reprobuild >=0.1.4")
    registerSolverDependency("app", "nim", "nim >=2.2 <3.0")
    packageSource("reprobuild", "store")
    let rendered = currentSolverInputsFixture()
    check blockFor(rendered, "reprobuild").contains("source: store")
    check not blockFor(rendered, "nim").contains("source:")

  test "a registry provenance renders in its directive form":
    registerSolverDependency("app", "libfoo", "libfoo >=1.2")
    packageSource("libfoo", "registry:crates")
    check blockFor(currentSolverInputsFixture(), "libfoo").contains(
      "source: registry crates")

  test "a provenance reprobuild cannot pin is refused at the declaration":
    ## The failure this must not have is a mis-typed provenance that
    ## silently produces an unliftable package several layers away.
    var refused = false
    try:
      packageSource("reprobuild", "stor")
    except ValueError as err:
      refused = true
      check err.msg.contains("store")
      check err.msg.contains("registry:")
    check refused

  test "an empty package name is refused":
    var refused = false
    try:
      packageSource("", "store")
    except ValueError:
      refused = true
    check refused

  test "the declaration does not survive a state reset":
    ## `resetVariantState` clears the declaration registry alongside the
    ## dependency registry, so one scenario cannot inherit another's.
    registerSolverDependency("app", "reprobuild", "reprobuild >=0.1.4")
    packageSource("reprobuild", "store")
    check blockFor(currentSolverInputsFixture(), "reprobuild").contains(
      "source: store")
    resetVariantState()
    registerSolverDependency("app", "reprobuild", "reprobuild >=0.1.4")
    check not blockFor(currentSolverInputsFixture(), "reprobuild").contains(
      "source:")
