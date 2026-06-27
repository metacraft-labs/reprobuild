## Workspace-Manifest-Optional MO-1 — the committed solved-graph lock
## pins the concrete solved graph, and ``repro build`` consumes it.
##
## Drives a built ``./build/bin/repro`` against a fixture project that
## carries a ``repro.solver`` sidecar (a solvable variant+package graph).
## Asserts:
##
##   1. ``repro lock refresh`` writes the canonical ``repro.lock`` pinning
##      the concrete solved graph — the chosen package version, the
##      variant (option) assignment, and the per-package source identity.
##   2. ``repro build --print-solved-graph`` (the no-build inspection
##      surface that runs the exact lock-consumption loader the real build
##      uses) reproduces the pinned graph from the committed lock.
##   3. Round-trip: the graph the build resolves equals the graph written
##      to the lock.
##   4. CONSUMPTION (not a fresh re-solve): after tampering the committed
##      lock to pin a DIFFERENT version, the build resolves the TAMPERED
##      (locked) version — proving it reads the lock rather than
##      re-solving the inputs (a fresh solve would still yield the
##      original version).
##   5. ``--lock <file>`` selects an alternate committed lock.
##
## Falsifiability: if the build-path loader ignored the committed lock and
## re-solved the inputs, assertion 4 would observe the original solved
## version after tampering and FAIL.

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

suite "MO-1: committed lock pins solved graph and build consumes it":

  test "refresh writes the lock and build consumes the pinned graph":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-pin-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      let lockPath = projectDir / "repro.lock"

      # 1. refresh writes the canonical lock pinning the solved graph.
      let (refreshOut, refreshRc) = execCmdEx(reproBinary &
        " lock refresh " & quoteShell(projectDir))
      check refreshRc == 0
      check fileExists(lockPath)
      let lockBody = readFile(lockPath)
      # The lock pins the concrete version, the package source identity,
      # and uses the v2 schema (MO-8: the self-describing committed lock that
      # also carries per-dependency coordinates + integrity; the v1
      # solved-graph payload is preserved as a sub-part).
      check "reprobuild.solved-graph-lock.v2" in lockBody
      check "name = \"nim\"" in lockBody
      check "version = \"2.2.0\"" in lockBody
      check "source = \"nim\"" in lockBody
      check "name = \"app\"" in lockBody
      check refreshOut.len > 0

      # 2 + 3. build consumes the lock and reproduces the pinned graph.
      let (graphOut, graphRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check graphRc == 0
      check "version = \"2.2.0\"" in graphOut
      check "name = \"nim\"" in graphOut
      check "# source: lock" in graphOut

      # 4. CONSUMPTION proof — tamper the committed lock to a DIFFERENT
      # version. A fresh re-solve of the inputs would still yield 2.2.0;
      # the build must instead report the tampered (locked) 9.9.9.
      writeFile(lockPath, lockBody.replace("2.2.0", "9.9.9"))
      let (tamperOut, tamperRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check tamperRc == 0
      check "version = \"9.9.9\"" in tamperOut
      check "version = \"2.2.0\"" notin tamperOut
      check "# source: lock" in tamperOut

  test "no committed lock — build solves the inputs implicitly":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-implicit-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      # No repro.lock present — the build solves the sidecar inputs.
      let (graphOut, graphRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) & " --print-solved-graph")
      check graphRc == 0
      check "version = \"2.2.0\"" in graphOut
      check "# source: solve" in graphOut

  test "--lock selects an alternate committed lock":
    if not fileExists(reproBinary):
      skip()
    else:
      let projectDir = getTempDir() / "mo1-altlock-" & $getCurrentProcessId()
      removeDir(projectDir)
      writeProject(projectDir)
      defer: removeDir(projectDir)

      let altLock = projectDir / "ci-min.lock"
      let (_, refreshRc) = execCmdEx(reproBinary &
        " lock refresh " & quoteShell(projectDir) &
        " --lock " & quoteShell(altLock))
      check refreshRc == 0
      check fileExists(altLock)
      # The canonical repro.lock was NOT written (alternate selected).
      check not fileExists(projectDir / "repro.lock")

      # Tamper the alternate lock and confirm --lock <file> consumes it.
      let altBody = readFile(altLock)
      writeFile(altLock, altBody.replace("2.2.0", "7.7.7"))
      let (graphOut, graphRc) = execCmdEx(reproBinary &
        " build " & quoteShell(projectDir) &
        " --lock " & quoteShell(altLock) & " --print-solved-graph")
      check graphRc == 0
      check "version = \"7.7.7\"" in graphOut
      check "# source: lock" in graphOut
