## generate_test_edges.nim — discover Nim test files and emit
## ``repro_tests.nim`` as a normal Nim module exporting a
## ``reprobuildTestSpecs*`` const table. ``repro.nim`` imports the
## module and iterates the table inside its ``build:`` block, calling
## ``buildNimUnittest.build(...)`` for each entry — the Project-DSL-
## Composition M6 migration shape (Approach A: data + iteration).
##
## Run from the repo root::
##
##   nim r scripts/generate_test_edges.nim
##
## The output (``repro_tests.nim``) is checked into git so the diff is
## review-visible.
##
## Idempotency: a second invocation against the same source tree
## produces byte-identical output. The discovered file list is sorted
## alphabetically by full relative path so any addition/removal
## generates a clean diff.
##
## Per-file metadata
## -----------------
## A small number of tests need ``--define:reproProviderMode`` at
## compile time. The ``ct_test_nim_unittest`` adapter's ``cli:`` block
## accepts a ``defines: seq[string]`` parameter (Test-Edges M2), so the
## generator emits the define directly in each ``TestSpec`` entry's
## ``defines`` field — no path-based shell carry-forward needed.
##
## Migration history (M6)
## ----------------------
## Before M6 this generator emitted a ``build:`` block directly, which
## was ``include``-d into ``repro.nim`` inside its ``package reprobuild:``
## body. The package macro's ``collectBuildStatements`` did not see
## through ``include`` nodes, so ``repro build test`` saw no edges.
## Project-DSL-Composition M5 added the active-build-context handle and
## confirmed that ``for`` loops survive inside ``build:``; this generator
## now emits a data table and iteration happens at the call site.

import std/[algorithm, os, strutils, sets]

const
  GeneratedFile = "repro_tests.nim"
  BinaryRoot = "build/test-bin"

type
  TestEdge = object
    source: string        # repo-relative path to the .nim file
    binary: string        # repo-relative output path
    identName: string     # Nim identifier for the let-binding
    needsProviderMode: bool

proc isProviderModePath(path: string): bool =
  ## Mirrors ``scripts/run_tests.sh`` lines ~128-167. ``path`` is a
  ## repo-relative path with forward slashes.
  let p = path
  if p.startsWith("libs/repro_standard_provider/tests/") or
     "/libs/repro_standard_provider/tests/" in p:
    return true
  # Named-Targets M1 + Typed-Outputs M1 engine-test gates: any
  # t_engine_implicit_*, t_engine_multiple_outputs_*,
  # t_engine_target_export_*, t_engine_typed_output_*, or
  # t_engine_method_call_on_typed_field_* file under
  # libs/repro_build_engine/tests/ needs the define.
  for prefix in [
    "libs/repro_build_engine/tests/t_engine_implicit_",
    "libs/repro_build_engine/tests/t_engine_multiple_outputs_",
    "libs/repro_build_engine/tests/t_engine_target_export_",
    "libs/repro_build_engine/tests/t_engine_typed_output_",
    "libs/repro_build_engine/tests/t_engine_method_call_on_typed_field_",
  ]:
    if p.startsWith(prefix):
      return true
  # The Named-Targets M2 and M5 e2e ambiguity / qualified-target tests
  # also drive ``buildPackageFragment`` directly.
  for exact in [
    "tests/e2e/local-build-engine/t_repro_build_ambiguous_target_diagnostic.nim",
    "tests/e2e/local-build-engine/t_repro_build_qualified_target_resolves.nim",
  ]:
    if p == exact:
      return true
  return false

proc toForward(path: string): string =
  result = path.replace('\\', '/')

proc identFromBasename(stem: string): string =
  ## Map a test-file stem (e.g. ``t_engine_action_create_dyndep``) to a
  ## valid Nim identifier suitable for a ``let _<stem> = ...`` binding.
  ## We prefix with an underscore so the binding doesn't collide with
  ## any user-facing symbol and the unused-warning is muted.
  result = "_"
  for ch in stem:
    if ch.isAlphaNumeric() or ch == '_':
      result.add(ch)
    else:
      result.add('_')

proc acceptTestsTree(rel: string): bool =
  # Fixture trees are spec exhibits / test scaffolding, not reprobuild
  # tests; their per-fixture `tests/t_*.nim` files mimic real test
  # binaries but cannot compile against the live engine. Skip them.
  if rel.startsWith("tests/fixtures/"):
    return false
  let stem = rel.splitFile().name
  rel.endsWith(".nim") and stem.startsWith("t_")

proc acceptLibsTree(rel: string): bool =
  let parts = rel.split('/')
  if parts.len < 4: return false
  if parts[2] != "tests": return false
  let stem = rel.splitFile().name
  rel.endsWith(".nim") and
    (stem.startsWith("t_") or stem.startsWith("test_"))

proc acceptToolsTree(rel: string): bool =
  let parts = rel.split('/')
  if parts.len < 4: return false
  if parts[2] != "tests": return false
  let stem = rel.splitFile().name
  rel.endsWith(".nim") and stem.startsWith("test_")

proc walkRoot(repoRoot, dir: string;
              accept: proc (rel: string): bool): seq[string] =
  result = @[]
  let abs = repoRoot / dir
  if not dirExists(abs):
    return
  for path in walkDirRec(abs, relative = true):
    let rel = (dir / path).toForward()
    if accept(rel):
      result.add(rel)

proc discoverTests(repoRoot: string): seq[TestEdge] =
  result = @[]
  var seenBinaries = initHashSet[string]()

  var candidates: seq[string] = @[]
  candidates.add(walkRoot(repoRoot, "tests", acceptTestsTree))
  candidates.add(walkRoot(repoRoot, "libs", acceptLibsTree))
  candidates.add(walkRoot(repoRoot, "tools", acceptToolsTree))

  # Deterministic sort by source path so the generated file diffs
  # cleanly across runs.
  candidates.sort()

  for rel in candidates:
    let stem = rel.splitFile().name
    let binary = BinaryRoot & "/" & stem
    if binary in seenBinaries:
      # Basename collision — surface to stderr so the operator can
      # disambiguate (the binary file would silently overwrite at
      # runtime). The generator deliberately does NOT mangle the name
      # to preserve the current ``scripts/run_tests.sh`` convention; an
      # explicit failure mode is preferable to a silent overwrite.
      stderr.writeLine("generate_test_edges: collision on '" & stem &
        "' (already seen for binary '" & binary & "'; current source: " &
        rel & ")")
      continue
    seenBinaries.incl(binary)
    result.add(TestEdge(
      source: rel,
      binary: binary,
      identName: identFromBasename(stem),
      needsProviderMode: isProviderModePath(rel)))

proc render(edges: seq[TestEdge]): string =
  result = ""
  result.add("# AUTO-GENERATED by scripts/generate_test_edges.nim — " &
    "do not edit by hand.\n")
  result.add("# Regenerate with: nim r scripts/generate_test_edges.nim\n")
  result.add("#\n")
  result.add("# This module is a plain Nim module exporting a single const,\n")
  result.add("# ``reprobuildTestSpecs*``: a ``seq[TestSpec]`` table of every\n")
  result.add("# discovered Nim ``unittest`` test binary in the repository.\n")
  result.add("#\n")
  result.add("# ``repro.nim`` ``import``s this module and iterates the table\n")
  result.add("# inside its ``package reprobuild: build:`` block, calling\n")
  result.add("# ``buildNimUnittest.build(...)`` once per spec. The returned\n")
  result.add("# build-edge actions are then aggregated into the ``test``\n")
  result.add("# target so ``repro build test`` schedules every test-binary\n")
  result.add("# compilation in one engine pass.\n")
  result.add("#\n")
  result.add("# Tests that need ``--define:reproProviderMode`` at compile\n")
  result.add("# time carry the define in their ``TestSpec.defines`` field.\n")
  result.add("# The adapter wires each entry as ``--define:<name>`` on the\n")
  result.add("# underlying ``nim c`` invocation, so the build is fully routed\n")
  result.add("# through the typed-output edge graph (no path-based shell\n")
  result.add("# carry-forward needed).\n")
  result.add("#\n")
  result.add("# Project-DSL-Composition M6 migration: the previous shape\n")
  result.add("# emitted a ``build:`` block ``include``-d from ``repro.nim``,\n")
  result.add("# which the package macro silently dropped. The data-table\n")
  result.add("# shape lifts the registration into the caller, so the macro\n")
  result.add("# sees every typed-tool call.\n")
  result.add("\n")
  result.add("type\n")
  result.add("  TestSpec* = object\n")
  result.add("    ## One row of the test-suite table. ``source`` is the\n")
  result.add("    ## repo-relative path to the ``.nim`` test file;\n")
  result.add("    ## ``binary`` is the repo-relative output binary path;\n")
  result.add("    ## ``defines`` is the per-test ``-d:`` flag list passed\n")
  result.add("    ## through to ``buildNimUnittest.build``.\n")
  result.add("    source*: string\n")
  result.add("    binary*: string\n")
  result.add("    defines*: seq[string]\n")
  result.add("\n")
  result.add("const reprobuildTestSpecs*: seq[TestSpec] = @[\n")
  for i, edge in edges:
    let sep = if i == edges.high: "" else: ","
    result.add("  TestSpec(\n")
    result.add("    source: \"" & edge.source & "\",\n")
    result.add("    binary: \"" & edge.binary & "\",\n")
    if edge.needsProviderMode:
      result.add("    defines: @[\"reproProviderMode\"])" & sep & "\n")
    else:
      result.add("    defines: @[])" & sep & "\n")
  result.add("]\n")

proc main() =
  let repoRoot = getCurrentDir()
  let edges = discoverTests(repoRoot)
  let outputPath = repoRoot / GeneratedFile
  let content = render(edges)
  let existing =
    if fileExists(outputPath): readFile(outputPath) else: ""
  if existing == content:
    stderr.writeLine("generate_test_edges: " & GeneratedFile &
      " is up to date (" & $edges.len & " tests)")
    return
  writeFile(outputPath, content)
  stderr.writeLine("generate_test_edges: wrote " & GeneratedFile &
    " (" & $edges.len & " tests)")

when isMainModule:
  main()
