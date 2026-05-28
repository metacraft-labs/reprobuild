## Mode 3 DSL surface: the ``depends_on`` macro records workspace
## dep edges into ``registeredWorkspaceDeps()`` per
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"`depends_on`
## is a new DSL construct".
##
## The macro is a thin sugar over an in-memory registry — the engine
## does NOT yet consume these edges for graph wiring. The test pins
## the registry shape so a future engine integration has a stable
## contract to bind against.
##
## Compile with ``-d:reproProviderMode`` so the provider-mode runtime
## glue is on the link line (same convention as test_library_macro.nim).

import std/[unittest]

import repro_project_dsl

# Clear the registry so prior package declarations in the link unit
# (or other tests sharing this binary) don't leak edges into this
# suite's assertions.
resetWorkspaceDepRegistry()

# Single-package declaration so we have a stable target for the
# ``depends_on`` calls below. The package itself doesn't need to
# import anything — we're testing the ``depends_on`` macro in
# isolation.
package depsOnTestPackage:
  uses:
    "nim >=2.2 <3.0"
  library depsOnLib

# Inline form: one dep.
depends_on depsOnTestPackage: someDep

# Block form: deps on separate indented lines (one per line).
depends_on depsOnTestPackage:
  delta
  epsilon

# Block form with string literals (mirrors a scanner-generated file
# that prefers quoted dep names for visual clarity).
depends_on depsOnTestPackage:
  "stringDep"

suite "DSL depends_on macro (Mode 3 pilot)":

  test "registers one edge per declared dep":
    let edges = registeredWorkspaceDeps()
    var seenDeps: seq[string] = @[]
    for edge in edges:
      if edge.package == "depsOnTestPackage":
        seenDeps.add(edge.dependency)
    check "someDep" in seenDeps
    check "delta" in seenDeps
    check "epsilon" in seenDeps
    check "stringDep" in seenDeps

  test "all entries name the originating package":
    for edge in registeredWorkspaceDeps():
      check edge.package == "depsOnTestPackage"
      check edge.dependency.len > 0

  test "resetWorkspaceDepRegistry empties the registry":
    # Defensive: the engine's test harness resets between scenarios.
    # We don't want THIS test to wipe state the suite relies on, so
    # we snapshot, reset, check, and restore.
    let snapshot = registeredWorkspaceDeps()
    resetWorkspaceDepRegistry()
    check registeredWorkspaceDeps().len == 0
    # Restore so the rest of the test binary's assertions still see
    # the registry. (Inline-call shape mirrors what the macro emits.)
    for edge in snapshot:
      registerWorkspaceDep(edge.package, edge.dependency)
    check registeredWorkspaceDeps().len == snapshot.len
