## DSL-port M1 acceptance — empty-body `package` declarations.
##
## This is the first acceptance file for the v8-prototype port of
## `transformPackageBody` into production. The minimum contract M1
## must uphold: a `package <name>:` declaration with NO recognised DSL
## section in its body (just `discard` or a trivial Nim statement) must
## still compile, register the package, and emit the standard
## `<packageValueIdent>* = <Title>Package()` const that downstream
## consumers use to address the package's typed-tool surface.
##
## Why this is interesting:
##   * The legacy `parsePackageDef` walker (in `macros_a.nim`) iterates
##     the body and only consumes recognised section heads (executable,
##     library, uses, …). An empty body and a body containing only
##     `discard 42` both produce an empty parse result. The downstream
##     `wrapperCode` + `buildCode` emitters must still produce a
##     well-formed const + (zero-state) build proc.
##   * The v8 `transformPackageBody` design walks unknown nodes in place
##     and preserves them. The "add-alongside" production port (see
##     `cross_project.nim:preservedTopLevelNodes`) emits non-section
##     statements at module top level. M1 verifies that pathway lights
##     up for the simplest case: `discard` placeholder + a plain
##     `discard <expr>`.
##
## No special compile defines required — this test exercises macro
## expansion + the runtime registry, neither of which needs
## `reproProviderMode` or any other gate.

import std/[unittest]

import repro_project_dsl

# Case A — `package` with a pure `discard` placeholder body. This is the
# "valid Nim empty block" shape the language requires (a stmt-list cannot
# be syntactically empty). `parsePackageDef` should see zero sections.
package myEmptyPkg:
  discard

# Case B — `package` with a non-trivial Nim discard. This statement is
# NOT a recognised DSL section head; the v8 contract is "preserve in
# place" (production's add-alongside emits it at module top level).
package anotherPkg:
  discard 42

suite "DSL-port M1 — package empty body":

  test "myEmptyPkg registers with no executables and no libraries":
    let packages = registeredPackages()
    var pkg: PackageDef
    var found = false
    for p in packages:
      if p.packageName == "myEmptyPkg":
        pkg = p
        found = true
        break
    check found
    check pkg.packageName == "myEmptyPkg"
    check pkg.executables.len == 0
    check pkg.libraries.len == 0

  test "myEmptyPkg emits the standard <selector>* const":
    # `wrapperCode` unconditionally emits
    #   const <selectorModuleName>* = <TitleIdent>Package()
    # regardless of section count. `selectorModuleName("myEmptyPkg")`
    # is `my_empty_pkg`. Asserting `declared(...)` proves the const
    # made it through.
    check declared(my_empty_pkg)

  test "anotherPkg registers with `discard 42` body":
    let packages = registeredPackages()
    var pkg: PackageDef
    var found = false
    for p in packages:
      if p.packageName == "anotherPkg":
        pkg = p
        found = true
        break
    check found
    check pkg.packageName == "anotherPkg"
    check pkg.executables.len == 0
    check pkg.libraries.len == 0

  test "anotherPkg also emits the standard <selector>* const":
    check declared(another_pkg)
