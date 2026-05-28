## E2E test for ``repro deps refresh`` and its ``--check`` flag.
##
## The contract is documented in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"`repro deps
## refresh` CLI":
##
##   * ``repro deps refresh PATH`` writes ``repro.scanned-deps.nim``
##     under ``PATH`` and exits 0.
##   * ``repro deps refresh --check PATH`` exits 0 when the file is
##     up-to-date and 1 when it has drifted.
##   * ``--dry-run`` prints the would-be content to stdout and never
##     writes.
##
## We spawn the real ``build/bin/repro.exe`` and assert on its exit
## codes — the in-process scanner is covered by ``t_nim_dep_scanner.nim``;
## this test covers the CLI plumbing.

import std/[os, osproc, strutils, unittest]

const ReproBinaryRel = "build/bin/repro.exe"

proc findReproBinary(): string =
  ## Walk up from the current dir to find ``build/bin/repro.exe``.
  ## When run via ``run_tests.sh`` the cwd is the repo root, but for
  ## ad-hoc invocations the test may be executed from a sub-directory.
  var dir = getCurrentDir()
  while dir.len > 0:
    let candidate = dir / ReproBinaryRel
    if fileExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  ""

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-deps-refresh-check-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc writeFixture(dir: string) =
  ## Minimal two-package fixture: ``app`` imports ``lib``.
  writeFile(dir / "repro.nim", """
import repro_project_dsl

package libPkg:
  uses:
    "nim >=2.2 <3.0"
  library libpkg

package appPkg:
  uses:
    "nim >=2.2 <3.0"
  executable app:
    discard
""")
  createDir(dir / "src")
  writeFile(dir / "src" / "libpkg.nim",
    "proc hello*(): string = \"hi\"\n")
  writeFile(dir / "src" / "app.nim", """
import libpkg

echo hello()
""")

let reproBin = findReproBinary()

suite "repro deps refresh: CLI smoke":

  test "build/bin/repro.exe is on disk":
    if reproBin.len == 0:
      skip()
    else:
      check fileExists(reproBin)

  test "refresh writes the scanned-deps file and exits 0":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("refresh-writes")
      writeFixture(dir)
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "deps", "refresh", dir]))
      if exitCode != 0:
        echo "stderr/stdout from refresh:\n", output
      check exitCode == 0
      check fileExists(dir / "repro.scanned-deps.nim")
      let body = readFile(dir / "repro.scanned-deps.nim")
      check body.contains("DO NOT EDIT")
      check body.contains("depends_on appPkg: libPkg")
      removeDir(dir)

  test "--check returns 0 when the file matches":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("check-match")
      writeFixture(dir)
      discard execCmdEx(quoteShellCommand(@[
        reproBin, "deps", "refresh", dir]))
      let (_, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "deps", "refresh", "--check", dir]))
      check exitCode == 0
      removeDir(dir)

  test "--check returns 1 when the file is stale":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("check-stale")
      writeFixture(dir)
      # Pre-populate with a clearly wrong file.
      writeFile(dir / "repro.scanned-deps.nim", "# stale\n")
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "deps", "refresh", "--check", dir]))
      check exitCode == 1
      check output.contains("out of date") or output.contains("--check")
      removeDir(dir)

  test "--dry-run never writes; prints the would-be content":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("dry-run")
      writeFixture(dir)
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "deps", "refresh", "--dry-run", dir]))
      check exitCode == 0
      check not fileExists(dir / "repro.scanned-deps.nim")
      check output.contains("DRY RUN")
      check output.contains("DO NOT EDIT")
      check output.contains("depends_on appPkg: libPkg")
      removeDir(dir)
