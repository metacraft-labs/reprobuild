## Structural verifier for the spec-example fixtures under
## ``tests/fixtures/spec-examples/``.
##
## The fixtures are spec exhibits. The two M1 fixtures
## (``simple-test-collection`` and ``variant-feature-flag``) compile
## under ``nim check`` against the live engine — that sibling check
## lives in ``t_spec_example_fixtures_compile.nim``. The third
## fixture (``selectable-toolchain``) still references DSL constructs
## not yet implemented (constraint expressions ``requires:`` /
## ``conflicts:`` / ``propagates:`` and the ``Toolchain``
## cross-cutting interface) and is M2+ work.
##
## This test performs structural checks: it walks each fixture's
## ``repro.nim`` and asserts the expected DSL surface markers are
## present so the fixtures cannot drift silently from the spec. A
## sibling driver gated on ``REPRO_SPEC_EXAMPLES_RUN=1`` is planned
## once the M3+ ``TestRunner`` interface lands and the fixtures can
## run end-to-end. The structural verifier stays in place as the
## cheap always-on backstop.
##
## Specs covered:
## - reprobuild-specs/Build-Graph-Collections.md
## - reprobuild-specs/Configurable-System.md §"Solver-Participating
##   Configurables (Variants)"
## - reprobuild-specs/Reprobuild-Standard-Library.md
## - reprobuild-specs/CLI/test.md, CLI/bench.md, CLI/lint.md

import std/[os, strutils, unittest]

const FixturesRoot = currentSourcePath().parentDir.parentDir /
                     "fixtures" / "spec-examples"

proc readFixture(relPath: string): string =
  let path = FixturesRoot / relPath
  doAssert fileExists(path),
    "spec-example fixture missing: " & relPath &
    " (expected at " & path & ")"
  readFile(path)

template requireSurface(body: string, marker: string,
                        fixture: string) =
  ## Assert that `marker` appears in `body`; failure points at the
  ## fixture so the diagnostic is actionable.
  check marker in body
  if marker notin body:
    echo "spec-example fixture ", fixture,
         " missing expected DSL marker: ", marker

suite "spec-example fixtures: simple-test-collection":
  let repro = readFixture("simple-test-collection/repro.nim")

  test "declares a package":
    requireSurface repro, "package simple_test_collection:",
                   "simple-test-collection/repro.nim"

  test "uses the buildNimUnittest typed-tool (M1 long-form shape)":
    requireSurface repro, "buildNimUnittest.build(",
                   "simple-test-collection/repro.nim"

  test "registers the `test` build graph collection":
    requireSurface repro, "collect(\"test\", ",
                   "simple-test-collection/repro.nim"

  test "exercises at least two test edges so the collection has multiple members":
    check repro.count("buildNimUnittest.build(") >= 2

  test "library and test sources are present":
    discard readFixture("simple-test-collection/src/lib.nim")
    discard readFixture("simple-test-collection/tests/t_smoke.nim")
    discard readFixture("simple-test-collection/tests/t_arithmetic.nim")

suite "spec-example fixtures: variant-feature-flag":
  let repro = readFixture("variant-feature-flag/repro.nim")

  test "declares a variant Configurable":
    requireSurface repro, "enableTLS: variant bool = true",
                   "variant-feature-flag/repro.nim"

  test "variant-conditioned uses: arm":
    requireSurface repro, "if enableTLS.value: \"openssl",
                   "variant-feature-flag/repro.nim"

  test "variant-conditioned build edge (typed-tool call under control flow)":
    requireSurface repro, "if enableTLS.value:",
                   "variant-feature-flag/repro.nim"
    # The TLS test edge sits inside the variant-guarded block.
    check "buildNimUnittest.build(" in repro
    check "source = \"tests/t_tls.nim\"" in repro

  test "registers the `test` build graph collection":
    requireSurface repro, "collect(\"test\", ",
                   "variant-feature-flag/repro.nim"

  test "both test sources and the server source are present":
    discard readFixture("variant-feature-flag/src/server.nim")
    discard readFixture("variant-feature-flag/tests/t_basic.nim")
    discard readFixture("variant-feature-flag/tests/t_tls.nim")

suite "spec-example fixtures: selectable-toolchain":
  let repro = readFixture("selectable-toolchain/repro.nim")

  test "declares an enum variant":
    # M2d landed the fixture with the long-form ``variant string`` shape
    # so the unified solver can build its universe from the variant
    # contributions without the enum sugar. The original spec exhibit
    # (``variant enum["gcc", "clang"]`` with constraint-style
    # ``requires:``/``conflicts:`` and the ``Toolchain`` cross-cutting
    # interface) lands once M3+ ships the enum-sugar lowering and the
    # cross-cutting interface layer; at that point this assertion
    # tightens back to the enum form.
    requireSurface repro,
      "compiler: variant string = \"gcc\"",
      "selectable-toolchain/repro.nim"

  test "variant-driven uses: case expression":
    requireSurface repro, "case compiler.value:",
                   "selectable-toolchain/repro.nim"
    requireSurface repro, "of \"gcc\":",
                   "selectable-toolchain/repro.nim"
    requireSurface repro, "of \"clang\":",
                   "selectable-toolchain/repro.nim"

  test "abstract cc.compile typed-tool call (Toolchain cross-cutting interface)":
    # M2d routes both arms through the concrete ``gcc(...)`` typed-tool
    # wrapper so the fixture compiles end-to-end through the unified
    # solver. The original spec exhibit's abstract ``cc.compile(...)``
    # call (dispatched via the ``Toolchain`` cross-cutting interface)
    # lands when M3+ ships the cross-cutting interface layer and the
    # clang adapter's typed-tool surface; this assertion will tighten
    # to ``cc.compile(`` at that point.
    requireSurface repro, "gcc(",
                   "selectable-toolchain/repro.nim"

  test "C source is present":
    discard readFixture("selectable-toolchain/src/main.c")

suite "spec-example fixtures: directory hygiene":
  test "spec-examples README links the canonical specs":
    let readme = readFixture("README.md")
    check "Build-Graph-Collections.md" in readme
    check "Configurable-System.md" in readme
    check "Reprobuild-Standard-Library.md" in readme

  test "each fixture has its own README explaining what it exercises":
    for project in ["simple-test-collection", "variant-feature-flag",
                    "selectable-toolchain"]:
      discard readFixture(project / "README.md")
