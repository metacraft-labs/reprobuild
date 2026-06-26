## Workspace-Manifest-Optional MO-1 — ``repro lock refresh`` and
## ``repro lock validate`` are no-build lock operations.
##
## Drives a built ``./build/bin/repro`` against a fixture project carrying
## a ``repro.solver`` sidecar. Asserts:
##
##   1. ``repro lock refresh`` (re)writes the committed lock WITHOUT
##      building — no build artifacts (``build/`` dir, output binaries)
##      appear in the project; only ``repro.lock`` is created/updated.
##   2. ``repro lock validate`` PASSES (exit 0) on a consistent lock.
##   3. ``repro lock validate`` FAILS (exit 2, clear diagnostic) on a
##      tampered lock (a version that no longer matches a fresh solve of
##      the inputs) and on a malformed lock (bad schema).
##   4. ``repro lock refresh`` updates the lock in place when the inputs
##      change.
##
## Falsifiability: if ``refresh`` triggered a build, assertion 1 (no build
## artifacts) would FAIL; if ``validate`` ignored the tampered version,
## assertion 3 (exit 2 on tamper) would FAIL.

import std/[os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0

package nim
versions: 2.2.0
"""

proc writeProject(dir: string) =
  createDir(dir)
  writeFile(dir / "repro.solver", solverInputs)

proc listProjectFiles(dir: string): seq[string] =
  for kind, path in walkDir(dir):
    result.add(extractFilename(path))

suite "MO-1: lock refresh and validate without building":

  test "refresh writes the lock and produces no build artifacts":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-refresh-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      let (refreshOut, refreshRc) = execCmdEx(reproBinary &
        " lock refresh " & quoteShell(projectDir))
      check refreshRc == 0
      check fileExists(projectDir / "repro.lock")
      check refreshOut.len > 0

      # No build happened: no build/ scratch dir, no output binaries — only
      # the sidecar inputs and the freshly written lock remain.
      check not dirExists(projectDir / "build")
      check not dirExists(projectDir / ".repro")
      let entries = listProjectFiles(projectDir)
      for entry in entries:
        check entry in ["repro.solver", "repro.lock"]

  test "validate passes on a consistent lock":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-valid-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      check execCmdEx(reproBinary & " lock refresh " &
        quoteShell(projectDir))[1] == 0
      let (validateOut, validateRc) = execCmdEx(reproBinary &
        " lock validate " & quoteShell(projectDir))
      check validateRc == 0
      check "OK" in validateOut

  test "validate fails on a tampered lock with a diagnostic":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-tamper-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      check execCmdEx(reproBinary & " lock refresh " &
        quoteShell(projectDir))[1] == 0
      let lockPath = projectDir / "repro.lock"
      # Tamper the pinned version to one that no longer matches a fresh
      # solve of the inputs.
      writeFile(lockPath, readFile(lockPath).replace("2.2.0", "9.9.9"))
      let (tamperOut, tamperRc) = execCmdEx(reproBinary &
        " lock validate " & quoteShell(projectDir) & " 2>&1")
      check tamperRc == 2
      check "INVALID" in tamperOut or "tampered" in tamperOut or
            "stale" in tamperOut

  test "validate fails on a malformed lock":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-malformed-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      writeFile(projectDir / "repro.lock",
        "schema = \"totally.wrong.schema\"\n")
      let (_, badRc) = execCmdEx(reproBinary &
        " lock validate " & quoteShell(projectDir) & " 2>&1")
      check badRc == 2

  test "refresh updates the lock in place when inputs change":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-update-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      check execCmdEx(reproBinary & " lock refresh " &
        quoteShell(projectDir))[1] == 0
      let before = readFile(projectDir / "repro.lock")
      check "version = \"2.2.0\"" in before

      # Change the inputs: bump nim's available/required version.
      writeFile(projectDir / "repro.solver", """
package app
versions: 0.1.0
depends: nim >=2.4.0 <3.0.0

package nim
versions: 2.4.0
""")
      check execCmdEx(reproBinary & " lock refresh " &
        quoteShell(projectDir))[1] == 0
      let after = readFile(projectDir / "repro.lock")
      check "version = \"2.4.0\"" in after
      check after != before
      # The refreshed lock now validates against the new inputs.
      check execCmdEx(reproBinary & " lock validate " &
        quoteShell(projectDir))[1] == 0
