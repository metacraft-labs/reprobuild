## Structural verifier for the spec-example fixtures under
## ``tests/fixtures/spec-examples/``.
##
## The fixtures are spec exhibits that reference DSL constructs not yet
## implemented (build graph collections, solver-participating
## Configurables / variants, the `Toolchain` cross-cutting interface,
## the `test` template's auto-enrollment). They cannot be compiled by
## the current engine. This test therefore performs structural checks:
## it walks each fixture's ``repro.nim`` and asserts the expected DSL
## surface markers are present so the fixtures cannot drift silently
## from the spec.
##
## Once the implementation milestones land, a sibling driver gated on
## ``REPRO_SPEC_EXAMPLES_RUN=1`` will compile + run each fixture and
## assert behavioural contracts (verb-alias dispatch, variant override
## effects, conditional collection enrollment). The structural verifier
## stays in place as the cheap always-on backstop.
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

  test "uses the `test` template (Package-Model §The `test` template)":
    requireSurface repro, "test buildNimUnittest(",
                   "simple-test-collection/repro.nim"

  test "exercises at least two test edges so the collection has multiple members":
    check repro.count("test buildNimUnittest(") >= 2

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

  test "variant-conditioned build edge (test template under control flow)":
    requireSurface repro, "if enableTLS.value:",
                   "variant-feature-flag/repro.nim"
    # The TLS test edge sits inside the variant-guarded block.
    check "test buildNimUnittest(source = \"tests/t_tls.nim\"" in repro

  test "both test sources and the server source are present":
    discard readFixture("variant-feature-flag/src/server.nim")
    discard readFixture("variant-feature-flag/tests/t_basic.nim")
    discard readFixture("variant-feature-flag/tests/t_tls.nim")

suite "spec-example fixtures: selectable-toolchain":
  let repro = readFixture("selectable-toolchain/repro.nim")

  test "declares an enum variant":
    requireSurface repro,
      "compiler: variant enum[\"gcc\", \"clang\"] = \"gcc\"",
      "selectable-toolchain/repro.nim"

  test "variant-driven uses: case expression":
    requireSurface repro, "case compiler.value:",
                   "selectable-toolchain/repro.nim"
    requireSurface repro, "of \"gcc\":",
                   "selectable-toolchain/repro.nim"
    requireSurface repro, "of \"clang\":",
                   "selectable-toolchain/repro.nim"

  test "abstract cc.compile typed-tool call (Toolchain cross-cutting interface)":
    requireSurface repro, "cc.compile(",
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
