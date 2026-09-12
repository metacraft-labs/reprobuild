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
##      recipe whose body consults the idempotency guard before
##      rebuilding. This catches a regression where someone removes the
##      guard. The guard used to be the inline test
##      ``if [ ! -x ./build/bin/repro ]``; it now lives in
##      ``scripts/bootstrap_guard.sh`` (the Justfile says why: the
##      inline form named the LINUX artefact on every platform, so on
##      Windows — where ``build/`` is shared with a WSL checkout of the
##      same tree — it tested the wrong file for existence and compared
##      source freshness against the wrong file's mtime). The recipe
##      branches on the script's ``decide`` verdict, so THAT is what
##      this arm pins now. The script's own behaviour has its own gate,
##      ``t_bootstrap_guard_names_the_host_artefact.nim``.
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
    # The idempotency guard — the recipe must consult it before
    # rebuilding, and must branch on the verdict rather than always
    # taking the bootstrap arm. The guard moved out of the recipe body
    # into scripts/bootstrap_guard.sh so it could name the HOST
    # artefact (see this file's header and the Justfile's own comment);
    # asking for the old inline ``if [ ! -x ./build/bin/repro ]`` text
    # would now fail on a Justfile that is strictly more correct.
    check "bootstrap_guard.sh decide" in text
    check "bootstrap*)" in text
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
      # Establish the precondition this case depends on, rather than hoping
      # for it. The guard skips when the artefact is present, of this host's
      # machine format, AND newer than the sources it reads — so "the binary
      # exists" is not on its own a reason to expect a no-op. Any source edit
      # since the last build legitimately makes the next `just bootstrap`
      # rebuild, and asserting a no-op then tests nothing but whether someone
      # happened to build recently. That is how this case reads green on a
      # freshly built tree and red minutes later on the same commit.
      #
      # Idempotency is what the name claims, so prove it the way idempotency
      # is proven: run it once to reach the settled state, then assert that
      # running it AGAIN changes nothing. The first call is setup, and its
      # cost is the rebuild the tree needed anyway.
      let (seedOutput, seedExit) = execCmdEx("just bootstrap",
        workingDir = repoRoot)
      checkpoint("seeding invocation exit=" & $seedExit)
      if seedExit != 0:
        checkpoint(seedOutput)
      check seedExit == 0

      # Capture mtime before the invocation under test.
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
