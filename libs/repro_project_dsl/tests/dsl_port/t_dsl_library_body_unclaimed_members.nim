## A `library` body member that NO pass consumes is now reported.
##
## The body is walked more than once, so "parseLibrary ignores it" was never
## the same as "nobody consumes it" — which is why this arm could not simply be
## turned into an error. The cross-pass inventory:
##
##   kind, exportedPath, discard  → parseLibrary (macros_a)
##   build                        → emitM4ArtifactBuildLowering, which
##                                  re-classifies the body and claims soM4Build
##   cli                          → emitM6CliLowering, which head-matches `cli`
##                                  on any M3 artifact body, library included
##
## Nothing else is claimed by anything, so anything else now warns.
##
## Measured across the whole tree with an indentation-aware scan (the earlier
## figure in the docs came from a `grep -A4` that spilled into neighbouring
## lines and was wrong by two orders of magnitude): library bodies contain
## 307 `discard`, 7 `kind`, 4 `build`, 3 `exportedPath` — and nothing else.
## Only three real recipes put a `build:` in a library body (boost, clingo,
## nss); every other real body is a bare `discard`.
##
## This file pins the members that MUST stay silent. The warning itself is
## verified separately by compiling a probe and reading the compiler output —
## a `warning()` cannot be observed from inside the program it is compiled
## into, so asserting it here would prove nothing.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

package libClaimedMembersPkg:
  # Every claimed member, in the shapes real declarations use. None of these
  # may warn: a warning on a valid member is as bad as silence on an invalid
  # one, because it trains readers to ignore the signal.
  library lib_bare

  library lib_discard:
    discard

  library lib_kind_only:
    kind: shared

  library lib_kind_and_path:
    kind: shared
    exportedPath: "custom/dir"

  library lib_with_build:
    ## A doc comment inside the body must not warn either.
    kind: static
    build:
      discard

suite "library bodies: claimed members still parse":
  let packages = registeredPackages()
  var pkg: PackageDef
  for p in packages:
    if p.packageName == "libClaimedMembersPkg":
      pkg = p
      break

  proc libByName(name: string): LibraryDef =
    for lib in pkg.libraries:
      if lib.name == name:
        return lib
    raise newException(ValueError, "library not found: " & name)

  test "all five declarations reached the registry":
    check pkg.libraries.len == 5

  test "a bare declaration still defaults to lkStatic":
    check libByName("lib_bare").kind == lkStatic

  test "a discard body still defaults to lkStatic":
    check libByName("lib_discard").kind == lkStatic

  test "kind: still parses":
    check libByName("lib_kind_only").kind == lkShared

  test "kind: and exportedPath: still parse together":
    let lib = libByName("lib_kind_and_path")
    check lib.kind == lkShared
    check lib.exportedPath == "custom/dir"

  test "a build: body coexists with the parser's own members":
    # `build:` is claimed by the M4 pass, not this one. The parser must skip
    # it without disturbing the members it does own.
    check libByName("lib_with_build").kind == lkStatic
