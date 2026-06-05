## generate_test_edges.nim — discover Nim test files and emit
## ``repro.tests.nim`` so each test becomes a declared typed-output
## build edge instead of a ``find`` + ``nim c -r`` shell loop entry.
##
## Run from the repo root::
##
##   nim r scripts/generate_test_edges.nim
##
## The output (``repro.tests.nim``) is checked into git so the diff is
## review-visible.  ``repro.nim`` ``include``s the file inside its
## ``package reprobuild:`` body; the include lands inside a ``build:``
## block emitted by this generator so the typed-tool calls land in the
## right macro-collection scope (see ``macros_b.nim``'s
## ``collectBuildStatements``).
##
## Idempotency: a second invocation against the same source tree
## produces byte-identical output. The discovered file list is sorted
## alphabetically by full relative path so any addition/removal
## generates a clean diff.
##
## Per-file metadata carry-forward
## --------------------------------
## A small number of tests need ``--define:reproProviderMode`` at
## compile time. The ``ct_test_nim_unittest`` adapter's ``cli:`` block
## does NOT yet accept a ``defines:`` parameter (see
## Test-Edges-And-Parallel-Runner M1 in the spec) so we cannot route
## the define through the typed-tool call at this milestone. Instead:
##
##   * The generator recognises the per-path rules below and tags the
##     emitted call with a ``# REPRO_PROVIDER_MODE`` comment.
##   * ``scripts/run_tests.sh`` keeps the path-based
##     ``--define:reproProviderMode`` injection for the affected tests
##     until a follow-on milestone teaches the adapter the
##     ``defines:`` parameter and reroutes the carry-forward through
##     the typed call.
##
## The path rules mirror ``scripts/run_tests.sh`` lines ~128-167.

import std/[algorithm, os, sequtils, strutils, sets]

const
  GeneratedFile = "repro.tests.nim"
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
  result.add("# Each block declares one Nim unittest test binary as a " &
    "typed-output\n")
  result.add("# build edge. ``buildNimUnittest.build(...)`` is supplied " &
    "by\n")
  result.add("# ``ct_test_nim_unittest`` (the framework adapter at\n")
  result.add("# ``../ct-test/libs/ct_test_nim_unittest/``); the let-binding\n")
  result.add("# captures the returned ``BuildNimUnittestBuildEdge`` so the " &
    "aggregate\n")
  result.add("# ``test`` target at the bottom can reference every edge's " &
    "action id.\n")
  result.add("#\n")
  result.add("# Tests marked ``REPRO_PROVIDER_MODE`` need\n")
  result.add("# ``--define:reproProviderMode`` at compile time. The " &
    "adapter's\n")
  result.add("# ``cli:`` block does not currently accept a ``defines:`` " &
    "parameter\n")
  result.add("# (see Test-Edges-And-Parallel-Runner M1 in the spec); for " &
    "now\n")
  result.add("# ``scripts/run_tests.sh`` carries the define forward via " &
    "its\n")
  result.add("# path-based injection rules. A follow-on milestone will " &
    "teach\n")
  result.add("# the adapter a ``defines:`` parameter and reroute the " &
    "carry-forward\n")
  result.add("# through the typed call.\n")
  result.add("\n")
  result.add("build:\n")
  for edge in edges:
    if edge.needsProviderMode:
      result.add("  # REPRO_PROVIDER_MODE: " & edge.source & "\n")
    result.add("  let " & edge.identName &
      " = buildNimUnittest.build(\n")
    result.add("    source = \"" & edge.source & "\",\n")
    result.add("    binary = \"" & edge.binary & "\")\n")
    result.add("\n")

  result.add("  # Aggregate ``test`` target — `repro build test` selects " &
    "every\n")
  result.add("  # declared test edge in one engine pass. Each entry is " &
    "the edge's\n")
  result.add("  # ``.action`` field (the engine-side ``BuildActionDef`` " &
    "handle).\n")
  result.add("  discard aggregate(\"test\", @[\n")
  for i, edge in edges:
    let sep = if i == edges.high: "" else: ","
    result.add("    " & edge.identName & ".action" & sep & "\n")
  result.add("  ])\n")

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
