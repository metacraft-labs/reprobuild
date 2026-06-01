## M10 — CLI shape tests for ``repro home gc``.
##
## Exercises the user-facing surface (help, flag parsing, error
## paths) by shelling out to the built ``repro`` binary. The
## engine itself is tested under
## ``libs/repro_home_apply/tests/t_home_gc.nim``; this file focuses
## on the dispatcher seam, help-text wording, and exit codes.

import std/[os, osproc, streams, strutils, unittest]
from repro_core/paths import extendedPath

const FixtureRoot = "build/test-tmp/test-m10-home-gc-cli"

proc reproRepoMarker(p: string): bool =
  fileExists(extendedPath(p / "apps" / "entrypoints.txt")) and
    dirExists(extendedPath(p / "libs" / "repro_cli_support"))

proc repoRootFromHere(): string =
  ## Locate the reprobuild repo root by walking up from:
  ##   1. the test source file's compile-time directory
  ##      (``currentSourcePath()``) — robust to ``nim c -r``'s
  ##      CWD-vs-source mismatch and to a parent agent's
  ##      sub-directory CWD.
  ##   2. ``getCurrentDir()`` — the ``run_tests.sh``-from-repo-root
  ##      invocation case.
  ##   3. The compiled binary's directory — covers the
  ##      ``build/test-bin/...`` case when launched outside its
  ##      compile tree.
  ## Returns the empty string if no marker is found.
  let candidates = [parentDir(currentSourcePath()), getCurrentDir(),
    getAppDir()]
  for start in candidates:
    var cur = start
    for _ in 0 .. 10:
      if reproRepoMarker(cur):
        return cur
      let parent = parentDir(cur)
      if parent == cur or parent.len == 0:
        break
      cur = parent
  return ""

proc reproBinary(): string =
  ## The dev-host built binary. CI / build_apps.sh place it under
  ## ``<repo-root>/build/bin/repro[.exe]``.
  let root = repoRootFromHere()
  if root.len == 0:
    raise newException(IOError,
      "could not locate reprobuild repo root from the test runner; " &
      "run `bash scripts/build_apps.sh` from the repo root first")
  when defined(windows):
    root / "build" / "bin" / "repro.exe"
  else:
    root / "build" / "bin" / "repro"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc runRepro(args: openArray[string]; env: openArray[(string, string)] = []):
    tuple[exit: int; outStr: string] =
  ## Synchronously invoke ``repro <args...>`` via ``startProcess`` —
  ## skips the cmd /c quoting wart entirely by passing argv as an
  ## array. ``poStdErrToStdOut`` merges stderr so usage-error
  ## messages (which go to stderr) land in ``outStr``.
  for kv in env:
    putEnv(kv[0], kv[1])
  var argv: seq[string]
  for a in args: argv.add a
  let p = startProcess(reproBinary(), args = argv,
    options = {poStdErrToStdOut, poDaemon})
  # Drain stdout while the child runs; reading after exit can deadlock
  # if the pipe buffer fills mid-run. For our tiny fixtures the
  # buffer is plenty, so we just block on exit then read.
  let exitCode = p.waitForExit()
  let captured = streams.readAll(p.outputStream)
  p.close()
  for kv in env:
    delEnv(kv[0])
  result.outStr = captured
  result.exit = exitCode

suite "M10 — repro home gc CLI":

  test "test_m10_cli_help_documents_all_flags":
    let r = runRepro(@["home", "gc", "--help"])
    check r.exit == 0
    check r.outStr.contains("usage: repro home gc")
    check r.outStr.contains("--dry-run")
    check r.outStr.contains("--force")
    check r.outStr.contains("--keep-generations")
    check r.outStr.contains("--store")
    # The help MUST surface the active-generation safety guarantee
    # (the explicit defense for the spec's "always preserve at
    # least 1 (the active one)" rule).
    check r.outStr.toLowerAscii.contains("active")

  test "test_m10_cli_unknown_flag_is_a_usage_error":
    let r = runRepro(@["home", "gc", "--bogus"])
    check r.exit == 2
    check r.outStr.contains("unknown flag")

  test "test_m10_cli_unexpected_positional_is_a_usage_error":
    let r = runRepro(@["home", "gc", "extra-positional"])
    check r.exit == 2
    check r.outStr.contains("unexpected positional")

  test "test_m10_cli_keep_generations_must_be_positive":
    let r = runRepro(@["home", "gc", "--keep-generations", "0"])
    check r.exit == 2
    check r.outStr.contains("--keep-generations must be >= 1")

  test "test_m10_cli_keep_generations_must_be_integer":
    let r = runRepro(@["home", "gc", "--keep-generations", "abc"])
    check r.exit == 2
    check r.outStr.contains("expects an integer")

  test "test_m10_cli_dry_run_on_empty_store_is_clean":
    ## Empty store + empty state dir → "store is clean" + exit 0.
    let stateDir = absolutePath(FixtureRoot / "empty-state")
    let storeRoot = absolutePath(FixtureRoot / "empty-store")
    resetDir(stateDir)
    resetDir(storeRoot)
    let r = runRepro(
      @["home", "gc", "--dry-run", "--store", storeRoot],
      env = [("REPRO_HOME_STATE_DIR", stateDir)])
    check r.exit == 0
    check r.outStr.contains("store is clean") or
      r.outStr.contains("no orphaned prefixes")

  test "test_m10_cli_top_level_usage_lists_gc":
    ## ``repro home`` with no subcommand prints the usage line; the
    ## list MUST include `gc` so operators discover it.
    let r = runRepro(@["home"])
    # Empty subcommand returns 2 (usage error) by convention.
    check r.exit == 2
    check r.outStr.contains("gc")
