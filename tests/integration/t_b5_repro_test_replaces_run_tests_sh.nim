## Bootstrap-And-Self-Build B5: ``scripts/run_tests.sh`` is slimmed
## down so the engine does the heavy lifting, and ``just test``
## continues to call it as the entry point.
##
## Structural verification only — this test reads the on-disk source
## of ``Justfile`` + ``scripts/run_tests.sh`` and asserts the B5
## migration shape:
##
##   1. ``scripts/run_tests.sh`` still exists (the original B5 spec
##      said "5-line shim or deletion"; the engine's tool-resolver gap
##      blocks the 5-line form, so the slimmed-but-substantial form is
##      what landed). Slimmed means under ~150 lines vs. the original
##      ~250.
##
##   2. The script delegates the apps + test-helpers + test-builds
##      compilation to the engine via ``repro ... build .#apps
##      .#test-helpers .#test-builds`` — the single biggest reduction.
##
##   3. The script invokes ``just bootstrap`` so a fresh checkout
##      without ``./build/bin/repro`` boots from nim before the engine
##      call.
##
##   4. The macOS-arm64 HCR direct-``nim c`` rebuild loop is gone —
##      B4 baked the ``extraPassC`` / ``extraPassL`` flags into the
##      build edges, so the engine handles the HCR specials in the
##      same pass as every other test.
##
##   5. The Justfile's ``test`` recipe + ``t`` alias still point at
##      ``scripts/run_tests.sh``. (B5 intentionally keeps the script
##      as the entry point because the engine cannot execute test
##      edges today — the ``test`` collection's execute halves are
##      registered in the graph but block on a typed-tool resolver
##      profile for ``ct_test_nim_unittest.buildNimUnittest``.)
##
##   6. The Justfile declares a ``bootstrap`` recipe.

import std/[os, strutils, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc lineCount(text: string): int =
  result = 0
  for line in text.splitLines:
    discard line
    inc result

suite "Bootstrap-And-Self-Build B5: run_tests.sh is slimmed and engine-driven":

  test "structural: scripts/run_tests.sh exists, is slimmed, and delegates to the engine":
    let repoRoot = findRepoRoot()
    let runTests = repoRoot / "scripts" / "run_tests.sh"
    check fileExists(runTests)

    let text = readFile(runTests)
    let lines = lineCount(text)
    checkpoint("scripts/run_tests.sh line count: " & $lines)

    # The original ran ~250 lines. B5 slimmed it; assert under 200
    # so a regression that re-introduces the legacy HCR loop or the
    # per-helper build_test_helper calls is caught. The threshold is
    # 200 (not 150) because two CI-survival additions land legitimately
    # post-B5: the per-collection ``repro_build_collection`` helper
    # (M3 multi-fragment selector workaround) and the
    # ``timeout --kill-after=30s`` wrapper around the runner phase
    # (orphan-daemon hang mitigation). Both bring the script to ~160
    # lines; the 200-line cap still catches a full revert to the
    # legacy script shape.
    check lines < 200

    # The engine call — the single biggest delegation. The CLI
    # accepts ``--tool-provisioning=path`` either before or after the
    # subcommand, so the script may interleave flags between ``build``
    # and the collection selectors. Assert each fragment is present
    # rather than requiring a specific ordering.
    check "build" in text
    check ".#apps" in text
    check ".#test-helpers" in text
    check ".#test-builds" in text
    check "--tool-provisioning=path" in text

    # The bootstrap call: the script must seed ./build/bin/repro
    # before invoking it.
    check "just bootstrap" in text

    # B5 self-documents itself in the header so future readers know
    # which milestone landed the migration.
    check "Bootstrap-And-Self-Build B5" in text

    # The legacy macOS-arm64 HCR direct ``nim c`` rebuild loop is
    # gone — its flags moved into the build edges in B4. The legacy
    # function definition / call pattern must NOT appear.
    check "compile_hcr_workaround()" notin text
    check "compile_hcr_workaround \"${test_file}\"" notin text
    # Same for the legacy ``build_test_helper`` function definition
    # (B2 moved the 3 helpers into the engine via .#test-helpers).
    # The descriptive comment header may still mention the legacy
    # function by name; match only the function-definition shape.
    check "build_test_helper() {" notin text
    check "build_test_helper \\" notin text

    # The test-execute path stays shell-shaped today (typed-tool
    # resolver gap). The script must still invoke a runner — either
    # ct-test-runner or the M3 fallback.
    check "ct-test-runner" in text or "repro_test_runner" in text

    checkpoint("B5 run_tests.sh shape: OK")

  test "structural: Justfile test recipe + t alias + bootstrap recipe":
    let repoRoot = findRepoRoot()
    let justfile = repoRoot / "Justfile"
    check fileExists(justfile)
    let text = readFile(justfile)

    # The ``test`` recipe still calls ``scripts/run_tests.sh`` — the
    # script is now the slim engine-driven version, so this is the
    # right entry point. (The original B5 spec said ``just test``
    # would invoke ``repro test`` directly; today's reality is that
    # the engine can't execute test edges yet, so the script stays.)
    check "\ntest:" in text
    check "bash ./scripts/run_tests.sh" in text

    # The ``t`` alias is unchanged.
    check "\nt: test" in text

    # The B5 bootstrap recipe declaration.
    check "\nbootstrap:" in text
    check "./build/bin/repro" in text
    checkpoint("Justfile B5 shape: OK")
