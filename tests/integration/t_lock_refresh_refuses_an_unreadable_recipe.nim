## Named-Lock-Files: a `repro lock refresh` that cannot read the recipe's
## solve must not write a lock.
##
## It used to warn ("could not read the tool uses of ...") and write the
## EMPTY solve anyway, exit 0: `packages = []`, the FNV-1a offset basis as
## `inputs_digest`, and the repo's own dep as the only pin. reprobuild
## 9ceb532d0 committed exactly that lock, dropping the producer pins for
## reprobuild-test-adapters, nim-stackable-hooks and nim-shm-queue; every
## `uses:` of those siblings then fell through to PATH, and
## `repro graph --tool-provisioning=path` failed on a checkout with no
## develop override.
##
## Both cases refresh the same project over the same committed lock. They
## differ in one thing: whether the recipe compiles. The control proves the
## refresh itself works here, so the refusal is about the recipe and not
## about the fixture.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const Recipe = """
import repro_project_dsl

package target:
  uses:
    "sh"
  build:
    discard
"""

const SeedInputs = "package app\nversions: 0.1.0\n" &
  "depends: nim >=2.2.0 <3.0.0\n\npackage nim\nversions: 2.2.0\n"

proc seededProject(root: string): string =
  ## A project with a committed lock that pins a package, written the way a
  ## real refresh writes one.
  result = root / "project"
  createDir(result)
  writeFile(result / "repro.nim", Recipe)
  let inputs = root / "seed-solver-inputs"
  writeFile(inputs, SeedInputs)
  let repro = requireBinary(getEnv("REPRO_BIN", reproBinaryPath(RepoRoot)),
    "reprobuild.apps.repro")
  let seeded = runShell(shellCommand(@[repro, "lock", "refresh", result,
    "--inputs", inputs], @[
    ("REPROBUILD_ACTION_CACHE_ROOT", root / "cache"),
    ("REPROBUILD_STORE_ROOT", root / "store"),
    ("REPRO_STORE_ROOT", root / "store")]), result)
  checkpoint seeded.output
  doAssert seeded.code == 0, "seeding the committed lock failed"
  doAssert readFile(result / "repro.lock").contains("version = \"2.2.0\"")

proc refresh(root, project: string): CmdResult =
  let repro = requireBinary(getEnv("REPRO_BIN", reproBinaryPath(RepoRoot)),
    "reprobuild.apps.repro")
  result = runShell(shellCommand(@[repro, "lock", "refresh", project], @[
    ("REPROBUILD_ACTION_CACHE_ROOT", root / "cache"),
    ("REPROBUILD_STORE_ROOT", root / "store"),
    ("REPRO_STORE_ROOT", root / "store"),
    ("REPRO_DAEMON", "off"),
    ("REPRO_TOOL_PROVISIONING", "path")]), project)
  checkpoint result.output
  checkpoint "exit=" & $result.code

when not defined(windows):
  suite "lock refresh refuses an unreadable recipe":
    test "control: the readable recipe refreshes":
      let root = createTempDir("lock-refresh-readable-", "")
      defer: removeDir(root)
      let project = seededProject(root)
      let response = refresh(root, project)
      check response.code == 0
      check "refusing to write" notin response.output

    test "a recipe that does not compile leaves the committed lock alone":
      let root = createTempDir("lock-refresh-unreadable-", "")
      defer: removeDir(root)
      let project = seededProject(root)
      writeFile(project / "repro.nim", Recipe & "\nthis is not nim (((\n")
      let before = readFile(project / "repro.lock")
      let response = refresh(root, project)
      check response.code != 0
      check "refusing to write" in response.output
      let after = readFile(project / "repro.lock")
      check after == before
      check "packages = []" notin after
