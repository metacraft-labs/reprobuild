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

  # Bootstrap-And-Self-Build B4: the three macOS-arm64 HCR tests
  # previously had their special compile flags emitted by
  # ``scripts/run_tests.sh``'s ``compile_hcr_workaround`` direct
  # ``nim c`` re-compile loop. The flags now live in the typed-tool's
  # ``extraPassC`` / ``extraPassL`` slots (see ct-test's
  # ``buildNimUnittest.build`` extension); the generator stamps the
  # per-test entries with both lists. The ``targetOs`` field guards
  # the flags so a non-Apple-Silicon host doesn't activate the macOS-
  # specific linker hint (on Linux/gcc the flags are typically ignored
  # with a warning, so the fallback path is "emit unconditionally" —
  # the runtime guard sits in ``repro.nim``'s test-spec loop).
  HcrTestStems = [
    "t_hcr_agent_process_target",
    "t_e2e_repro_watch_hcr_multi_target_independent_patches",
    "t_e2e_repro_watch_hcr_one_target_agent_inject_failure",
  ]

  HcrExtraPassC = "-fpatchable-function-entry=16,0"
  HcrExtraPassL = "-Wl,-segprot,__HCR,rwx,rwx"

type
  TargetOs = enum
    ## Bootstrap-And-Self-Build B4: per-test target-OS guard. ``soAny``
    ## (the default) means the test compiles on every supported host;
    ## ``soMacosArm64`` means the test carries platform-conditional
    ## flags (today: the HCR codesign workaround) that the build edge's
    ## runtime body activates only when the cross-target is
    ## aarch64-darwin. The runtime guard sits in ``repro.nim``; the
    ## generator only stamps the field.
    soAny, soMacosArm64

  TestEdge = object
    source: string        # repo-relative path to the .nim file
    binary: string        # repo-relative output path
    identName: string     # Nim identifier for the let-binding
    needsProviderMode: bool
    requiresReproBinary: bool
      ## Bootstrap-And-Self-Build B3: ``true`` when the test spawns
      ## ``./build/bin/repro`` as a subprocess. The generator detects
      ## this by scanning the test source for the ``build/bin/repro``
      ## literal. When set, ``repro.nim`` declares the engine-built
      ## ``build/bin/repro`` artifact as a typed input on the test's
      ## EXECUTE edge so (a) the engine builds ``repro`` before the
      ## test runs and (b) touching a source under ``libs/repro_*/``
      ## invalidates the test's execute-edge cache.
    extraPassC: seq[string]
      ## Bootstrap-And-Self-Build B4: per-test ``--passC:`` flags. The
      ## generator emits one entry per ``--passC:<value>`` flag the
      ## build edge should pass to ``nim c`` (and on through to the
      ## C backend). Today this covers the macOS-arm64 HCR codesign
      ## workaround on three specific tests; the field is empty for
      ## everything else.
    extraPassL: seq[string]
      ## Bootstrap-And-Self-Build B4: per-test ``--passL:`` flags;
      ## same shape and semantics as ``extraPassC`` but for the
      ## linker side.
    targetOs: TargetOs
      ## Bootstrap-And-Self-Build B4: per-test target-OS guard for the
      ## ``extraPassC`` / ``extraPassL`` activation. See ``TargetOs``.

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

proc acceptRecipesTree(rel: string): bool =
  # M9.N from-source recipes ship a ``test_<pkg>_source.nim`` next to each
  # recipe under ``recipes/packages/source/<pkg>/``. They are real
  # reprobuild unittest binaries (built + run as part of the ``test``
  # collection), so they need a build edge like any other test — they
  # simply live outside the tests/ ∙ libs/ ∙ tools/ roots.
  let parts = rel.split('/')
  if parts.len < 5: return false
  if parts[1] != "packages" or parts[2] != "source": return false
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

proc detectReproBinaryUsage(repoRoot, rel: string): bool =
  ## Bootstrap-And-Self-Build B3: returns ``true`` when the test source
  ## at ``repoRoot/rel`` contains the literal ``build/bin/repro`` (or
  ## the ``reproBin`` convention used by the integration suite). The
  ## scan is a cheap substring match against the test file — false
  ## positives (e.g. tests that reference the path in a string only
  ## for diagnostics) are acceptable here: declaring an unused typed
  ## input on the execute edge is harmless beyond a small action-cache
  ## key change.
  let abs = repoRoot / rel
  try:
    let content = readFile(abs)
    return ("build/bin/repro" in content) or
           ("build\\bin\\repro" in content)
  except IOError, OSError:
    return false

proc isHcrTestStem(stem: string): bool =
  for known in HcrTestStems:
    if stem == known:
      return true
  false

proc discoverTests(repoRoot: string): seq[TestEdge] =
  result = @[]
  var seenBinaries = initHashSet[string]()

  var candidates: seq[string] = @[]
  candidates.add(walkRoot(repoRoot, "tests", acceptTestsTree))
  candidates.add(walkRoot(repoRoot, "libs", acceptLibsTree))
  candidates.add(walkRoot(repoRoot, "tools", acceptToolsTree))
  candidates.add(walkRoot(repoRoot, "recipes", acceptRecipesTree))

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
    var extraPassC: seq[string] = @[]
    var extraPassL: seq[string] = @[]
    var targetOs = soAny
    if isHcrTestStem(stem):
      extraPassC = @[HcrExtraPassC]
      extraPassL = @[HcrExtraPassL]
      targetOs = soMacosArm64
    result.add(TestEdge(
      source: rel,
      binary: binary,
      identName: identFromBasename(stem),
      needsProviderMode: isProviderModePath(rel),
      requiresReproBinary: detectReproBinaryUsage(repoRoot, rel),
      extraPassC: extraPassC,
      extraPassL: extraPassL,
      targetOs: targetOs))

proc acceptPythonTest(rel: string): bool =
  ## Bootstrap-And-Self-Build B4: discover Python tests participating in
  ## the ``test`` collection. The pre-B4 ``scripts/run_tests.sh`` Python
  ## loop walked ``tests/`` with ``find -name 'test_*.py'``; this
  ## generator preserves the same discovery rule.
  if not rel.endsWith(".py"):
    return false
  let stem = rel.splitFile().name
  stem.startsWith("test_")

proc discoverPythonTests(repoRoot: string): seq[string] =
  ## Bootstrap-And-Self-Build B4: returns repo-relative paths to every
  ## ``test_*.py`` file under ``tests/``. Sorted alphabetically for
  ## deterministic output.
  result = @[]
  let absRoot = repoRoot / "tests"
  if not dirExists(absRoot):
    return
  for path in walkDirRec(absRoot, relative = true):
    let rel = ("tests" / path).toForward()
    if acceptPythonTest(rel):
      result.add(rel)
  result.sort()

proc seqLiteral(values: seq[string]): string =
  if values.len == 0:
    return "@[]"
  result = "@["
  for i, v in values:
    if i > 0:
      result.add(", ")
    result.add('"' & v & '"')
  result.add("]")

proc render(edges: seq[TestEdge]; pythonTests: seq[string]): string =
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
  result.add("#\n")
  result.add("# Bootstrap-And-Self-Build B4: the three macOS-arm64 HCR\n")
  result.add("# tests carry ``extraPassC`` / ``extraPassL`` + ``targetOs:\n")
  result.add("# soMacosArm64`` so the build edge emits the codesign\n")
  result.add("# workaround flags conditional on the cross-target. Python\n")
  result.add("# ``test_*.py`` files are enumerated as ``pythonTestPaths*``\n")
  result.add("# and consumed by ``repro.nim``'s ``pythonUnittest.run(...)``\n")
  result.add("# loop, so Python tests participate in the ``test``\n")
  result.add("# collection alongside the Nim tests.\n")
  result.add("\n")
  result.add("type\n")
  result.add("  TargetOs* = enum\n")
  result.add("    ## Bootstrap-And-Self-Build B4: per-test target-OS\n")
  result.add("    ## guard. ``soAny`` (default) — the test compiles on\n")
  result.add("    ## every supported host. ``soMacosArm64`` — the test\n")
  result.add("    ## carries platform-conditional flags (today: the HCR\n")
  result.add("    ## codesign workaround) that the build edge's runtime\n")
  result.add("    ## body activates only when the cross-target is\n")
  result.add("    ## aarch64-darwin.\n")
  result.add("    soAny, soMacosArm64\n")
  result.add("\n")
  result.add("  TestSpec* = object\n")
  result.add("    ## One row of the test-suite table. ``source`` is the\n")
  result.add("    ## repo-relative path to the ``.nim`` test file;\n")
  result.add("    ## ``binary`` is the repo-relative output binary path;\n")
  result.add("    ## ``defines`` is the per-test ``-d:`` flag list passed\n")
  result.add("    ## through to ``buildNimUnittest.build``.\n")
  result.add("    ## ``requiresReproBinary`` (B3): the test spawns\n")
  result.add("    ## ``./build/bin/repro`` as a subprocess, so the engine-\n")
  result.add("    ## built ``repro`` artifact is declared as a typed input\n")
  result.add("    ## on the EXECUTE edge (build edge stays purely a Nim\n")
  result.add("    ## compile).\n")
  result.add("    ## ``extraPassC`` / ``extraPassL`` (B4): per-test\n")
  result.add("    ## ``--passC:`` / ``--passL:`` flag lists, activated by\n")
  result.add("    ## the ``targetOs`` guard.\n")
  result.add("    ## ``targetOs`` (B4): see ``TargetOs``.\n")
  result.add("    source*: string\n")
  result.add("    binary*: string\n")
  result.add("    defines*: seq[string]\n")
  result.add("    requiresReproBinary*: bool\n")
  result.add("    extraPassC*: seq[string]\n")
  result.add("    extraPassL*: seq[string]\n")
  result.add("    targetOs*: TargetOs\n")
  result.add("\n")
  result.add("const reprobuildTestSpecs*: seq[TestSpec] = @[\n")
  for i, edge in edges:
    let sep = if i == edges.high: "" else: ","
    result.add("  TestSpec(\n")
    result.add("    source: \"" & edge.source & "\",\n")
    result.add("    binary: \"" & edge.binary & "\",\n")
    let definesLit =
      if edge.needsProviderMode: "@[\"reproProviderMode\"]"
      else: "@[]"
    let reqLit = if edge.requiresReproBinary: "true" else: "false"
    let targetOsLit = case edge.targetOs
      of soAny: "soAny"
      of soMacosArm64: "soMacosArm64"
    result.add("    defines: " & definesLit & ",\n")
    result.add("    requiresReproBinary: " & reqLit & ",\n")
    result.add("    extraPassC: " & seqLiteral(edge.extraPassC) & ",\n")
    result.add("    extraPassL: " & seqLiteral(edge.extraPassL) & ",\n")
    result.add("    targetOs: " & targetOsLit & ")" & sep & "\n")
  result.add("]\n")
  result.add("\n")
  result.add("## Bootstrap-And-Self-Build B4: Python tests discovered\n")
  result.add("## under ``tests/`` whose stem starts with ``test_``. The\n")
  result.add("## ``repro.nim`` ``build:`` block iterates this list and\n")
  result.add("## emits one ``pythonUnittest.run(...)`` execute edge per\n")
  result.add("## entry. Those edges are appended to the same\n")
  result.add("## ``reprobuildTestExecuteActions`` accumulator as the Nim\n")
  result.add("## test execute edges, so the ``test`` collection covers\n")
  result.add("## both languages in one engine pass.\n")
  result.add("const pythonTestPaths*: seq[string] = @[\n")
  for i, path in pythonTests:
    let sep = if i == pythonTests.high: "" else: ","
    result.add("  \"" & path & "\"" & sep & "\n")
  result.add("]\n")

proc main() =
  let repoRoot = getCurrentDir()
  let edges = discoverTests(repoRoot)
  let pythonTests = discoverPythonTests(repoRoot)
  let outputPath = repoRoot / GeneratedFile
  let content = render(edges, pythonTests)
  let existing =
    if fileExists(outputPath): readFile(outputPath) else: ""
  if existing == content:
    stderr.writeLine("generate_test_edges: " & GeneratedFile &
      " is up to date (" & $edges.len & " Nim tests, " &
      $pythonTests.len & " Python tests)")
    return
  writeFile(outputPath, content)
  stderr.writeLine("generate_test_edges: wrote " & GeneratedFile &
    " (" & $edges.len & " Nim tests, " & $pythonTests.len &
    " Python tests)")

when isMainModule:
  main()
