## Workspace-Manifest-Optional MO-11 — solved packages are FIRST-CLASS locked
## dependencies.
##
## Each solved package that carries a source provenance is lifted into a
## first-class ``LockedDep`` in the committed lock's ``deps`` set (with
## store/registry coordinates + a self-describing integrity), instead of being
## recorded ONLY in the ``[lock]``/``packages`` sub-part. The sub-part is KEPT
## as a derived view so ``lockToSolution`` / ``solutionToLock`` keep
## reconstructing the same ``Solution`` and every existing v2 lock still
## round-trips byte-for-byte.
##
## Asserts:
##
##   1. Every solved package appears as a first-class ``LockedDep`` in ``deps``
##      (coordinates + integrity), keyed by the package name.
##   2. The lock round-trips LOSSLESSLY: serialize -> parse -> serialize is
##      byte-stable AND the parsed ``deps`` carry the same coordinates +
##      integrity.
##   3. ``lockToSolution`` reconstructs the SAME ``Solution`` (the
##      package -> version map) from the lock's preserved sub-part.
##
## Falsifiability: revert the lift -> the packages are absent from ``deps`` and
## (1) FAILS; if the round-trip dropped the non-VCS coordinates, (2)'s parsed
## coordinate asserts FAIL.
##
## Hermetic: a fresh git repo in a tempdir. Skip rule: ``git`` missing or repro
## unbuilt.

import std/[os, osproc, strutils, tables, unittest]

import repro_cli_support
import repro_lock

const reproBinary = "./build/bin/repro"

# Three solved packages, all carrying a source provenance: two store-realized,
# one registry-sourced. ``app`` depends on ``nim`` so the solve has real edges.
const solverInputs = """
package app
versions: 0.1.0
depends: nim >=2.2.0 <3.0.0
source: store

package nim
versions: 2.2.0
source: store

package leftpad
versions: 1.2.0
source: registry npmjs
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string): tuple[code: int; output: string] =
  let res = execCmdEx(command)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

suite "MO-11: solved packages are first-class locked deps":

  test "t_solved_packages_are_first_class_locked_deps":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not fileExists(reproBinary):
      skip()
    else:
      let scratch = getTempDir() / "mo11-firstclass-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let origin = scratch / "origin.git"
      let repo = scratch / "work"
      check git(gitBin, "", "init --bare -b main " & q(origin)).code == 0
      check run(q(gitBin) & " clone " & q(origin) & " " & q(repo)).code == 0
      check git(gitBin, repo, "config user.email t@example.invalid").code == 0
      check git(gitBin, repo, "config user.name Tester").code == 0
      writeFile(repo / "README.md", "mo11 fixture\n")
      writeFile(repo / "repro.solver", solverInputs)
      check git(gitBin, repo, "add README.md repro.solver").code == 0
      check git(gitBin, repo, "commit -m seed").code == 0
      check git(gitBin, repo, "push origin main").code == 0

      let refresh = run(reproBinary & " lock refresh " & q(repo))
      check refresh.code == 0

      let ld = populateLockedDeps(
        LockSource(kind: lskCommittedLock, workspaceRoot: repo))

      # ---- (1) every solved package is a first-class LockedDep in deps. ----
      check ld.packages.len == 3
      for p in ld.packages:
        var found = false
        for d in ld.deps:
          if d.name == p.name and
              d.coordinates.kind in {ckStore, ckRegistry} and
              d.integrity.len > 0:
            check isWellFormedMultihash(d.integrity)
            found = true
            break
        check found     # the package was lifted (revert the lift -> fails here)

      # ---- (2) the lock round-trips LOSSLESSLY (byte-stable, coords kept). ----
      let serialized1 = serializeLockedDependencies(ld)
      let reparsed = parseLockedDependencies(serialized1)
      let serialized2 = serializeLockedDependencies(reparsed)
      check serialized1 == serialized2

      # The non-VCS coordinates survive the round-trip intact.
      var storeSeen = false
      var registrySeen = false
      for d in reparsed.deps:
        case d.coordinates.kind
        of ckStore:
          storeSeen = true
          check d.coordinates.storeHash.len > 0
          check d.integrity == "blake3:" & d.coordinates.storeHash
        of ckRegistry:
          registrySeen = true
          check d.coordinates.registryName.len > 0
          check d.coordinates.registryVersion.len > 0
          check isWellFormedMultihash(d.integrity)
        of ckVcs:
          discard
      check storeSeen
      check registrySeen

      # ---- (3) lockToSolution reconstructs the SAME Solution. ----
      let sol = lockToSolution(solvedPartOf(ld))
      check sol.packages.len == 3
      check sol.packages.getOrDefault("app") == "0.1.0"
      check sol.packages.getOrDefault("nim") == "2.2.0"
      check sol.packages.getOrDefault("leftpad") == "1.2.0"
      # And it round-trips through the re-parsed lock identically.
      let sol2 = lockToSolution(solvedPartOf(reparsed))
      check sameSolution(sol, sol2)
