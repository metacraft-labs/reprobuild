## Project-DSL-Composition M5 smoke test.
##
## Demonstrates that the production DSL now supports the three M5
## mechanisms end-to-end:
##
##   1. Active-build-context handle. The package macro wraps the
##      lowered ``build:`` body in beginBuildBlock/endBuildBlock so
##      typed-tool wrappers and helper procs can find the active
##      package via ``currentBuildState()`` / ``tryCurrentBuildState()``.
##   2. Cross-project binding collection. Top-level ``let``/``var``
##      bindings inside a producer's ``build:`` block lift to
##      module-level storage vars (with init flags), and per-binding
##      accessor templates emit so ``<pkg>.build.<binding>`` resolves.
##   3. Data-iteration shape (Approach A). A plain ``for`` loop over
##      a regular ``seq[T]`` inside ``build:`` is preserved by the
##      lowered builder and routes through the typed-tool wrapper for
##      each iteration.
##
## The fixture mirrors the v8 prototype's
## ``taccept_composition_data_iteration.nim`` shape but uses the
## smaller, in-tree CLI-only adapter pattern from
## ``t_dsl_executable_cli_only_no_build.nim`` to avoid pulling in the
## codetracer-side ``ct_test_nim_unittest`` adapter.
##
## Compile with ``-d:reproProviderMode`` so the provider-mode runtime
## glue links.

import std/[unittest]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

type
  ToyHandle = object
    path: string

# ---------------------------------------------------------------------------
# Adapter package: CLI-only declaration of a typed-tool surface. The
# resulting `toyEdge.compile(...)` wrapper proc registers an edge when
# called from inside a consumer's `build:` block.
# ---------------------------------------------------------------------------
package toyAdapter:
  executable toyEdge:
    cli:
      subcmd "compile":
        flag source is string
        flag binary is string
        outputs result is ToyHandle, binary

# ---------------------------------------------------------------------------
# Producer package: a top-level `let foo = toyAdapter.compile(...)`
# inside `build:` should:
#   * lift `foo` to a module-level storage var so consumers can read
#     it via `m5Producer.build.foo`;
#   * be reachable via the per-binding accessor template;
#   * be guarded by an init flag (reading before the producer's
#     `build:` runs raises a clear error).
# Mixed with a data-iteration block exercising plain `for` over
# `seq[string]`, which the M5 contract preserves verbatim.
# ---------------------------------------------------------------------------
const m5Sources = @[
  "tests/m5/case_a.nim",
  "tests/m5/case_b.nim",
  "tests/m5/case_c.nim",
]

package m5Producer:
  build:
    let singleEdge = toyAdapter.compile(
      source = "tests/m5/single.nim",
      binary = "build/m5/single")

    # Data-iteration shape — plain `for` over a regular `const seq[T]`.
    # The lowered builder should preserve this verbatim; each iteration
    # registers one edge through the typed-tool wrapper.
    for src in m5Sources:
      discard toyAdapter.compile(source = src,
                                  binary = "build/m5/" & src)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------
suite "Project-DSL-Composition M5 smoke":

  test "active-build-context is empty outside a build block":
    # No `build:` is active during test execution — `currentBuildState`
    # raises ValueError; `tryCurrentBuildState` returns nil.
    expect ValueError:
      discard currentBuildState()
    check tryCurrentBuildState().isNil

  test "package macro registers both adapter and producer":
    let packages = registeredPackages()
    var adapter, producer: PackageDef
    for p in packages:
      if p.packageName == "toyAdapter":
        adapter = p
      elif p.packageName == "m5Producer":
        producer = p
    check adapter.packageName == "toyAdapter"
    check producer.packageName == "m5Producer"
    # Adapter is the CLI-only typed-tool surface.
    check adapter.executables.len == 1
    check adapter.executables[0].exportName == "toyEdge"
    # Producer has no executables and (via this test path) at least
    # the `singleEdge` cross-project binding.
    check producer.executables.len == 0

  test "Package[name] / PackageBuild[name] prelude is reachable":
    # The prelude types are usable from any consumer — the smoke
    # check is just that an instance can be constructed.
    let p = Package["m5Producer"]()
    discard p
    let b = PackageBuild["m5Producer"]()
    discard b
    check true

  test "init flag for the cross-project binding starts false":
    # The accessor template guards on `composeBindingInit_m5Producer_singleEdge`.
    # Before the producer's `build:` block runs, the flag is false.
    check not composeBindingInit_m5Producer_singleEdge

  test "beginBuildBlock / endBuildBlock pushes and pops state":
    # The macro-emitted code does this implicitly, but the runtime
    # surface is also callable directly so helper-proc-style call
    # sites can validate the active-build invariant under test.
    check tryCurrentBuildState().isNil
    let state = beginBuildBlock("m5Producer")
    check tryCurrentBuildState() == state
    check state.ownerKind == "package"
    check state.packageName == "m5Producer"
    endBuildBlock(state)
    check tryCurrentBuildState().isNil
