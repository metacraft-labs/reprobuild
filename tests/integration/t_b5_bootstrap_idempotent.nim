## Bootstrap-And-Self-Build B5: ``just bootstrap`` is idempotent —
## it no-ops when ``./build/bin/repro`` already exists.
##
## Strategy
## --------
## The B5 milestone introduces a ``bootstrap`` Justfile recipe whose
## job is to materialise ``./build/bin/repro`` from ``nim c`` when the
## binary is missing on a fresh checkout. The recipe must be safe to
## call from ``scripts/run_tests.sh`` on every invocation; tests, CI,
## and developers shouldn't pay a rebuild cost when the binary is
## already present.
##
## This test verifies the idempotent path WITHOUT destroying the
## developer's pre-built ``./build/bin/repro``:
##
##   1. STRUCTURAL: assert the Justfile contains a ``bootstrap:``
##      recipe whose body has the ``if [ ! -x ./build/bin/repro ]``
##      guard. This catches a regression where someone removes the
##      idempotency guard.
##
##   2. BEHAVIOURAL: when ``./build/bin/repro`` exists, invoke ``just
##      bootstrap`` and assert the output reports the skip-path AND the
##      binary's mtime is unchanged (the recipe didn't re-compile).
##
##   3. SKIP-WITH-CLASSIFIER: when ``./build/bin/repro`` is missing
##      (fresh checkout, recent ``rm`` in the dev tree, etc.), skip
##      the behavioural assertion with a clear message; the structural
##      arm still passes.
##
## Safety note: this test deliberately does NOT delete the developer's
## ``./build/bin/repro`` to exercise the build path; that would (a)
## take ~4-5 minutes on a cold tree and (b) break every subsequent
## test in the same session that needs ``./build/bin/repro``. The
## build path is exercised in
## ``t_b5_full_suite_through_repro_test`` (guarded by
## REPRO_B5_FULL_SUITE_RUN=1).

import std/[os, osproc, strutils, times, unittest]

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

suite "Bootstrap-And-Self-Build B5: just bootstrap is idempotent":

  test "structural: Justfile declares a bootstrap recipe with an idempotency guard":
    let repoRoot = findRepoRoot()
    let justfile = repoRoot / "Justfile"
    check fileExists(justfile)
    let text = readFile(justfile)

    # The recipe header.
    check "\nbootstrap:" in text
    # The idempotency guard — the recipe must check whether the binary
    # already exists before rebuilding.
    check "if [ ! -x ./build/bin/repro ]" in text
    # Must reference the underlying build_apps.sh (the bootstrap path
    # is the same code path B1's apps collection wraps).
    check "scripts/build_apps.sh" in text
    # Self-documenting marker so future readers know which milestone
    # introduced the recipe.
    check "Bootstrap-And-Self-Build B5" in text
    checkpoint("Justfile bootstrap recipe + guard: OK")

  test "behavioural: just bootstrap no-ops when ./build/bin/repro exists":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " missing; can't verify the no-op path without rebuilding. " &
        "Run `just bootstrap` once to seed the binary, then re-run " &
        "this test.")
      skip()
    else:
      # Capture mtime before invoking bootstrap.
      let beforeMtime = getLastModificationTime(reproBin)

      # Run ``just bootstrap`` from the repo root.
      let cmd = "just bootstrap"
      checkpoint("running: " & cmd & " (from " & repoRoot & ")")
      let (output, exitCode) = execCmdEx(cmd, workingDir = repoRoot)
      checkpoint("exit=" & $exitCode)
      checkpoint(output)
      check exitCode == 0

      # The recipe must print the skip message — it's the only signal
      # that callers (CI logs, dev terminal) can use to confirm the
      # no-op path was taken.
      check "skipping bootstrap" in output

      # The binary must NOT have been re-compiled. If the mtime moved,
      # the guard misfired and we paid a multi-minute rebuild for no
      # reason.
      let afterMtime = getLastModificationTime(reproBin)
      check afterMtime == beforeMtime
      checkpoint("./build/bin/repro mtime unchanged: " & $beforeMtime)

      checkpoint("B5 bootstrap idempotency: OK")
