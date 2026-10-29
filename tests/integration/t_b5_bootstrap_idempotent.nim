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
##   2. BEHAVIOURAL: run the REAL ``bootstrap`` recipe text and the REAL
##      guard script with ``just``, in a PRIVATE fixture checkout whose
##      ``scripts/build_apps.sh`` is a stub that records each invocation
##      and stages host-format artefacts. Run it once to reach the
##      settled state, then assert that running it again reports the
##      skip path, does not invoke the build, and leaves the artefact's
##      mtime untouched.
##
## WHY A FIXTURE AND NOT THE LIVE TREE. This case used to run
## ``just bootstrap`` in the repository root, seeding first so that the
## second call had something to be idempotent about. Whenever the guard
## judged the tree stale, that seed call ran ``scripts/build_apps.sh``
## for real and relinked every app in the live ``build/bin`` — while the
## rest of the suite was executing those very binaries. Full run 41 hit
## it: a concurrent HCR test had left a gitignored library under
## ``libs/repro_hcr_agent/build/lib/``, the guard of the day counted it
## as a newer source, and in-flight tests then failed with
## ``.../build/bin/reprobuild (deleted): No such file or directory``.
## Whether a case can do that must not depend on how the suite happens
## to be ordered, so the case no longer touches anything outside its own
## scratch directory. The guard defect itself is fixed in the guard and
## pinned by ``t_bootstrap_guard_names_the_host_artefact.nim``; the third
## call below re-checks it end to end through the recipe.
##
## Nothing is mocked except ``scripts/build_apps.sh``, and that is the one
## thing this case is about NOT running: what it asserts is the recipe's
## decision and the fact the build was skipped. The real build path is
## exercised by ``t_b5_full_suite_through_repro_test`` (guarded by
## REPRO_B5_FULL_SUITE_RUN=1).

import std/[os, strutils, times, unittest]

import repro_test_support

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

proc requiredExe(name: string): string =
  result = findExe(name)
  doAssert result.len > 0,
    name & " is required: the case drives the real `bootstrap` recipe"

proc hostImage(): string =
  ## Enough of this host's executable format for the guard's magic check;
  ## nothing ever executes it.
  when defined(windows):
    var s = newString(0x44)
    s[0] = 'M'
    s[1] = 'Z'
    s[0x3C] = '\x40'
    s[0x40] = 'P'
    s[0x41] = 'E'
    s
  elif defined(macosx): "\xCF\xFA\xED\xFE" & newString(60)
  else: "\x7FELF\x02\x01\x01\x00" & newString(56)

proc bootstrapRecipe(justfileText: string): string =
  ## The ``bootstrap`` recipe exactly as the repository's Justfile spells
  ## it, so the fixture runs the shipped text rather than a paraphrase.
  let start = justfileText.find("\nbootstrap:\n")
  doAssert start >= 0, "Justfile has no `bootstrap:` recipe"
  var stop = justfileText.find("\n\n", start + 1)
  if stop < 0: stop = justfileText.len
  justfileText[start + 1 ..< stop] & "\n"

proc setTimeAgo(path: string; secondsAgo: int) =
  setLastModificationTime(path, getTime() + initDuration(seconds = -secondsAgo))

const StubBuildApps = """#!/usr/bin/env bash
# Stub for the fixture only: records that the build ran and stages the two
# host artefacts the guard requires, in place of a multi-minute real build.
set -eu
echo build >> build-apps-invocations
mkdir -p build/bin
cp seed-image build/bin/repro$1
cp seed-image build/bin/reprobuild$1
chmod +x build/bin/repro$1 build/bin/reprobuild$1
"""

proc newBootstrapFixture(repoRoot: string): string =
  ## A private git checkout with the repository's ``bootstrap`` recipe, its
  ## real guard, a stub ``build_apps.sh``, and a few sources under the
  ## guard's roots. ``build/`` is ignored exactly as the real tree ignores it.
  result = getTempDir() / ("b5-bootstrap-" & testCaseScratchSlug())
  removeDirEventually(result)
  createDir(result / "scripts")
  let justfile = readFile(repoRoot / "Justfile")
  writeFile(result / "Justfile",
    "set shell := [\"bash\", \"-eu\", \"-o\", \"pipefail\", \"-c\"]\n\n" &
    bootstrapRecipe(justfile))
  copyFile(repoRoot / "scripts" / "bootstrap_guard.sh",
    result / "scripts" / "bootstrap_guard.sh")
  let suffix = when defined(windows): ".exe" else: ""
  writeFile(result / "scripts" / "build_apps.sh",
    StubBuildApps.replace("$1", suffix))
  writeFile(result / "seed-image", hostImage())
  writeFile(result / ".gitignore", "build/\ntest-logs/\n")
  createDir(result / "apps")
  writeFile(result / "apps" / "entrypoints.txt", "repro\n")
  writeFile(result / "repro.nim", "# fixture\n")
  createDir(result / "libs" / "some_lib" / "src")
  writeFile(result / "libs" / "some_lib" / "src" / "some_lib.nim", "# src\n")
  let git = requiredExe("git")
  for argv in [@[git, "init", "-q", result], @[git, "-C", result, "add", "-A"]]:
    let r = runShell(shellCommand(argv), result)
    doAssert r.code == 0, $argv & " exited " & $r.code & ": " & r.output
  # Sources predate whatever the first bootstrap stages, unambiguously.
  for rel in ["apps/entrypoints.txt", "repro.nim", "libs/some_lib/src/some_lib.nim",
              "scripts/build_apps.sh", "scripts/bootstrap_guard.sh"]:
    setTimeAgo(result / rel, 600)

proc buildInvocations(root: string): int =
  let marker = root / "build-apps-invocations"
  if fileExists(marker): readFile(marker).count('\n') else: 0

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
    let just = requiredExe("just")
    let root = newBootstrapFixture(repoRoot)
    defer: removeDirEventually(root)
    let reproBin = root / "build" / "bin" / addFileExt("repro", ExeExt)

    template bootstrap(label: string): string =
      let r = runShell(shellCommand(@[just, "bootstrap"]), root)
      checkpoint(label & ": exit=" & $r.code & "\n" & r.output)
      check r.code == 0
      r.output

    # Seed: no artefact yet, so the recipe must take the build arm. This is
    # also the control that shows the stub is reachable — without it, "the
    # build was not invoked" below could be true of a recipe that never
    # builds at all.
    let seed = bootstrap("seed")
    check "bootstrapping" in seed
    check buildInvocations(root) == 1
    check fileExists(reproBin)

    # Idempotency: the settled tree must no-op.
    let beforeMtime = getLastModificationTime(reproBin)
    let again = bootstrap("second invocation")
    # The skip message is the only signal callers (CI logs, a developer's
    # terminal) have that the no-op path was taken.
    check "skipping bootstrap" in again
    check buildInvocations(root) == 1
    check getLastModificationTime(reproBin) == beforeMtime

    # Build output written under a source root afterwards — the run-41
    # shape — is gitignored and must not make the tree stale.
    let output = root / "libs" / "some_lib" / "build" / "lib" / "libsome_lib.so"
    createDir(output.parentDir)
    writeFile(output, "ignored build output")
    let afterOutput = bootstrap("after ignored build output")
    check "skipping bootstrap" in afterOutput
    check buildInvocations(root) == 1
    check getLastModificationTime(reproBin) == beforeMtime
    checkpoint("B5 bootstrap idempotency: OK")
